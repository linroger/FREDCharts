import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export Payload

/// Exactly what the user is currently looking at: the visible window, the active
/// transform, and every visible series. Exporting the on-screen view (rather than the
/// primary series' raw history) is what makes an export reproducible.
struct ExportPayload: Sendable {
    struct SeriesColumn: Sendable {
        let id: String
        let title: String
        let units: String
        let frequency: String
        let seasonalAdjustment: String
        let points: [SeriesDataPoint]

        /// `units` is passed explicitly because comparison charts may rescale a series
        /// into shared base units ("Billions of Dollars" → "U.S. Dollars"), and the
        /// export has to describe the numbers it actually contains.
        init(
            id: String,
            title: String,
            units: String,
            frequency: String,
            seasonalAdjustment: String,
            points: [SeriesDataPoint]
        ) {
            self.id = id
            self.title = title
            self.units = units
            self.frequency = frequency
            self.seasonalAdjustment = seasonalAdjustment
            self.points = points
        }

        init(series: FREDSeries, units: String? = nil, points: [SeriesDataPoint]) {
            self.init(
                id: series.id,
                title: series.title,
                units: units ?? series.units,
                frequency: series.frequency,
                seasonalAdjustment: series.seasonalAdjustment,
                points: points
            )
        }
    }

    let generatedAt: Date
    let rangeLabel: String
    let transform: SeriesTransform
    let columns: [SeriesColumn]

    init(
        generatedAt: Date = Date(),
        rangeLabel: String,
        transform: SeriesTransform,
        columns: [SeriesColumn]
    ) {
        self.generatedAt = generatedAt
        self.rangeLabel = rangeLabel
        self.transform = transform
        self.columns = columns
    }

    var isEmpty: Bool {
        columns.allSatisfy { $0.points.isEmpty }
    }

    /// Sorted union of every observation date across the visible series.
    var alignedDates: [Date] {
        var seen = Set<Date>()
        for column in columns {
            for point in column.points {
                seen.insert(point.date)
            }
        }
        return seen.sorted()
    }
}

// MARK: - Outcome

enum ExportOutcome: Equatable {
    case saved(URL)
    case cancelled
    case failed(String)
}

// MARK: - Export Service

enum ExportService {

    // MARK: Serialisation

    /// RFC 4180 CSV with a commented metadata preamble, one column per visible series.
    static func makeCSV(_ payload: ExportPayload) -> String {
        var lines: [String] = [
            "# FRED Ultra export",
            "# Generated: \(ISO8601DateFormatter().string(from: payload.generatedAt))",
            "# Window: \(payload.rangeLabel)",
            "# Transform: \(payload.transform.rawValue)",
            "# Source: Federal Reserve Economic Data (FRED), Federal Reserve Bank of St. Louis"
        ]

        for column in payload.columns {
            let resultUnits = payload.transform.resultUnits(baseUnits: column.units)
            lines.append("# Series: \(column.id) — \(column.title) [\(resultUnits); \(column.frequency); \(column.seasonalAdjustment)]")
        }

        lines.append((["Date"] + payload.columns.map { csvField($0.id) }).joined(separator: ","))

        // Index each column by date so the wide join is O(rows), not O(rows × columns × points).
        let indexed = payload.columns.map { column in
            Dictionary(column.points.map { ($0.date, $0.value) }, uniquingKeysWith: { _, last in last })
        }

        for date in payload.alignedDates {
            var row = [FREDDate.string(from: date)]
            for lookup in indexed {
                row.append(lookup[date].map(numberString) ?? "")
            }
            lines.append(row.joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func makeJSON(_ payload: ExportPayload) -> String {
        let seriesObjects: [[String: Any]] = payload.columns.map { column in
            [
                "id": column.id,
                "title": column.title,
                "source_units": column.units,
                "value_units": payload.transform.resultUnits(baseUnits: column.units),
                "frequency": column.frequency,
                "seasonal_adjustment": column.seasonalAdjustment,
                "observations": column.points.map { point in
                    [
                        "date": FREDDate.string(from: point.date),
                        "value": point.value
                    ] as [String: Any]
                }
            ]
        }

        let root: [String: Any] = [
            "metadata": [
                "generated_at": ISO8601DateFormatter().string(from: payload.generatedAt),
                "window": payload.rangeLabel,
                "transform": payload.transform.rawValue,
                "source": "Federal Reserve Economic Data (FRED), Federal Reserve Bank of St. Louis"
            ],
            "series": seriesObjects
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            AppLogger.export.error("Failed to serialise the JSON export payload")
            return "{}"
        }

        return string + "\n"
    }

    /// Tab-separated text for pasting straight into a spreadsheet.
    static func makeClipboardText(_ payload: ExportPayload) -> String {
        var lines: [String] = [(["Date"] + payload.columns.map(\.id)).joined(separator: "\t")]

        let indexed = payload.columns.map { column in
            Dictionary(column.points.map { ($0.date, $0.value) }, uniquingKeysWith: { _, last in last })
        }

        for date in payload.alignedDates {
            var row = [FREDDate.string(from: date)]
            for lookup in indexed {
                row.append(lookup[date].map(numberString) ?? "")
            }
            lines.append(row.joined(separator: "\t"))
        }

        return lines.joined(separator: "\n")
    }

    static func content(for payload: ExportPayload, format: ExportFormat) -> String {
        switch format {
        case .csv: return makeCSV(payload)
        case .json: return makeJSON(payload)
        }
    }

    // MARK: Clipboard

    @MainActor
    @discardableResult
    static func copyToClipboard(_ payload: ExportPayload) -> Int {
        let text = makeClipboardText(payload)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let rowCount = payload.alignedDates.count
        AppLogger.export.info("Copied \(rowCount) rows to the clipboard")
        return rowCount
    }

    // MARK: Saving

    /// Presents a save panel and writes the file, reporting the outcome to the caller.
    ///
    /// Presented as a sheet on the key window when one exists; the previous
    /// `panel.begin { … }` call could put the panel behind the app and silently
    /// swallowed write failures.
    @MainActor
    static func save(content: String, suggestedName: String, format: ExportFormat) async -> ExportOutcome {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(sanitizedFilename(suggestedName)).\(format.fileExtension)"
        panel.title = "Export \(format.rawValue)"

        switch format {
        case .csv:
            panel.allowedContentTypes = [.commaSeparatedText]
        case .json:
            panel.allowedContentTypes = [.json]
        }

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }

        guard response == .OK, let url = panel.url else {
            AppLogger.export.info("Export cancelled by the user")
            return .cancelled
        }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            AppLogger.export.info("Saved export to \(url.lastPathComponent, privacy: .public)")
            return .saved(url)
        } catch {
            AppLogger.export.error("Failed to save export: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Image rendering

    /// Renders a view to PNG bytes at `scale`, defaulting to 2x so the result stays crisp
    /// on a Retina display and when scaled into a document.
    @MainActor
    static func pngData<Content: View>(from view: Content, scale: CGFloat = 2) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale

        guard let cgImage = renderer.cgImage else {
            AppLogger.export.error("Chart image renderer produced no bitmap")
            return nil
        }

        let representation = NSBitmapImageRep(cgImage: cgImage)
        return representation.representation(using: .png, properties: [:])
    }

    /// Renders a view to a single-page PDF. Vector output stays sharp at any zoom, which
    /// is what a chart pasted into a paper or a deck needs.
    @MainActor
    static func pdfData<Content: View>(from view: Content, size: CGSize) -> Data? {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)

        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            AppLogger.export.error("Could not create a PDF context for the chart")
            return nil
        }

        let renderer = ImageRenderer(content: view)
        var rendered = false

        renderer.render { _, draw in
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            rendered = true
        }

        context.closePDF()

        guard rendered, data.length > 0 else {
            AppLogger.export.error("Chart PDF render produced no pages")
            return nil
        }

        return data as Data
    }

    /// Copies an image of `view` to the clipboard, ready to paste into notes or a deck.
    @MainActor
    static func copyImageToClipboard<Content: View>(_ view: Content, scale: CGFloat = 2) -> Bool {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale

        guard let image = renderer.nsImage else {
            AppLogger.export.error("Chart image renderer produced no image for the clipboard")
            return false
        }

        NSPasteboard.general.clearContents()
        let wrote = NSPasteboard.general.writeObjects([image])
        AppLogger.export.info("Copied the chart image to the clipboard")
        return wrote
    }

    // MARK: Saving binary output

    /// Save panel for non-text output, sharing the presentation rules of the text variant.
    @MainActor
    static func save(data: Data, suggestedName: String, format: ChartImageFormat) async -> ExportOutcome {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(sanitizedFilename(suggestedName)).\(format.fileExtension)"
        panel.title = "Save Chart as \(format.rawValue)"
        panel.allowedContentTypes = [format == .png ? .png : .pdf]

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }

        guard response == .OK, let url = panel.url else {
            AppLogger.export.info("Chart image export cancelled by the user")
            return .cancelled
        }

        do {
            try data.write(to: url, options: .atomic)
            AppLogger.export.info("Saved chart image to \(url.lastPathComponent, privacy: .public)")
            return .saved(url)
        } catch {
            AppLogger.export.error("Failed to save chart image: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Helpers

    /// Shortest faithful decimal rendering. `String(describing:)` switches to scientific
    /// notation for large magnitudes, which spreadsheets import poorly.
    static func numberString(_ value: Double) -> String {
        guard value.isFinite else { return "" }

        var text = String(format: "%.6f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text.isEmpty ? "0" : text
    }

    static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "fred-export" : cleaned
    }
}
