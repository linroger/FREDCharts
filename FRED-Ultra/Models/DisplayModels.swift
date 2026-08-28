import Foundation

// MARK: - Date Range Filter

/// Time window applied to a loaded series.
///
/// Windows are anchored to the *series' own latest observation* rather than to "now".
/// FRED hosts thousands of discontinued series; anchoring to the wall clock made
/// "1 Year" return an empty chart for every one of them.
enum DateRangeOption: String, CaseIterable, Identifiable, Sendable {
    case all = "All Time"
    case oneMonth = "1 Month"
    case threeMonths = "3 Months"
    case sixMonths = "6 Months"
    case oneYear = "1 Year"
    case twoYears = "2 Years"
    case fiveYears = "5 Years"
    case tenYears = "10 Years"
    case twentyYears = "20 Years"

    var id: String { rawValue }

    private var offset: (component: Calendar.Component, value: Int)? {
        switch self {
        case .all: return nil
        case .oneMonth: return (.month, -1)
        case .threeMonths: return (.month, -3)
        case .sixMonths: return (.month, -6)
        case .oneYear: return (.year, -1)
        case .twoYears: return (.year, -2)
        case .fiveYears: return (.year, -5)
        case .tenYears: return (.year, -10)
        case .twentyYears: return (.year, -20)
        }
    }

    /// Inclusive lower bound of the window, or `nil` for the full history.
    func startDate(anchoredTo anchor: Date, calendar: Calendar = .current) -> Date? {
        guard let offset else { return nil }
        return calendar.date(byAdding: offset.component, value: offset.value, to: anchor)
    }

    /// Convenience anchored to the current date, used where no series is loaded yet.
    var startDate: Date? {
        startDate(anchoredTo: Date())
    }
}

// MARK: - Transforms

/// Analytical transform applied to every visible series before charting.
///
/// Mirrors the transformations FRED offers on its own website so a reader can move
/// between levels, growth rates, and rebased comparisons without leaving the app.
enum SeriesTransform: String, CaseIterable, Identifiable, Sendable {
    case level = "Level"
    case periodChange = "Change"
    case periodPercentChange = "% Change"
    case yearOverYear = "YoY %"
    case indexed = "Index (Start = 100)"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .level: return "Level"
        case .periodChange: return "Chg"
        case .periodPercentChange: return "% Chg"
        case .yearOverYear: return "YoY %"
        case .indexed: return "Index"
        }
    }

    /// True when the transform erases the original units, which is what makes
    /// otherwise incomparable series safe to plot on one axis.
    var isUnitNeutral: Bool {
        switch self {
        case .level, .periodChange: return false
        case .periodPercentChange, .yearOverYear, .indexed: return true
        }
    }

    /// Units of the transformed output, given the source series' units.
    func resultUnits(baseUnits: String) -> String {
        switch self {
        case .level, .periodChange: return baseUnits
        case .periodPercentChange, .yearOverYear: return "Percent"
        case .indexed: return "Index"
        }
    }

    func explanation(frequency: SeriesFrequency) -> String {
        switch self {
        case .level:
            return "Raw published values in the series' own units."
        case .periodChange:
            return "Absolute change versus the previous \(frequency.periodNoun)."
        case .periodPercentChange:
            return "Percent change versus the previous \(frequency.periodNoun)."
        case .yearOverYear:
            return "Percent change versus the observation closest to one year earlier."
        case .indexed:
            return "Each series rebased to 100 at the first observation in the selected window."
        }
    }
}

// MARK: - Chart Mode

/// How the visible series are combined into plotted lines.
enum ChartMode: String, CaseIterable, Identifiable, Sendable {
    /// Every series drawn on a shared axis.
    case overlay = "Overlay"
    /// The primary series minus each comparison series.
    case spread = "Spread (A − B)"

    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .overlay:
            return "Each series is drawn on a shared value axis."
        case .spread:
            return "Plots the primary series minus each comparison series — a yield curve, a real rate, or a gap."
        }
    }
}

// MARK: - Moving Average

/// Optional trend overlay drawn on top of the primary series.
enum MovingAverageOption: String, CaseIterable, Identifiable, Sendable {
    case off = "None"
    case short = "Short"
    case medium = "Medium"
    case long = "Long"

    var id: String { rawValue }

    /// Window length in observations, scaled to the series' cadence so "Medium"
    /// means roughly a quarter for monthly data and roughly a month for daily data.
    func window(for frequency: SeriesFrequency) -> Int? {
        guard self != .off else { return nil }

        let periodsPerYear = frequency.periodsPerYear ?? 12
        let fraction: Double
        switch self {
        case .off: return nil
        case .short: fraction = 1.0 / 12.0
        case .medium: fraction = 0.25
        case .long: fraction = 1.0
        }

        return Swift.max(2, Int((Double(periodsPerYear) * fraction).rounded()))
    }

    func label(for frequency: SeriesFrequency) -> String {
        guard let window = window(for: frequency) else { return "No moving average" }
        return "\(window)-period moving average"
    }
}

// MARK: - Chart Data

/// One plotted point. `ID` avoids building an interpolated `String` per point, which
/// dominated chart rebuild cost on daily series with tens of thousands of rows.
struct ChartDataPoint: Identifiable, Hashable, Sendable {
    struct ID: Hashable, Sendable {
        let seriesId: String
        let time: Double
        let role: Role
    }

    enum Role: Hashable, Sendable {
        case observed
        case movingAverage
    }

    let seriesId: String
    let seriesTitle: String
    let date: Date
    let value: Double
    let role: Role

    var id: ID {
        ID(seriesId: seriesId, time: date.timeIntervalSinceReferenceDate, role: role)
    }

    init(seriesId: String, seriesTitle: String, date: Date, value: Double, role: Role = .observed) {
        self.seriesId = seriesId
        self.seriesTitle = seriesTitle
        self.date = date
        self.value = value
        self.role = role
    }

    init?(observation: FREDObservation, seriesId: String, seriesTitle: String) {
        guard let point = observation.dataPoint else { return nil }
        self.init(seriesId: seriesId, seriesTitle: seriesTitle, date: point.date, value: point.value)
    }

    /// Legend/label key. The moving-average overlay is a separate plot series so the
    /// chart legend explains what the extra line is.
    var plotKey: String {
        role == .movingAverage ? "\(seriesTitle) (avg)" : seriesTitle
    }
}

// MARK: - Table Row

/// A single row of the Data tab, fully pre-formatted so table rendering does no work.
struct ObservationRow: Identifiable, Hashable, Sendable {
    let id: Date
    let date: Date
    let rawDate: String
    let formattedDate: String
    let value: Double
    let formattedValue: String
    let changeFromPrevious: Double?
    let formattedChange: String

    /// Sortable stand-in for `changeFromPrevious`. The oldest visible row has no prior
    /// observation, and `Table` needs a total order over a non-optional key path.
    var sortableChange: Double {
        changeFromPrevious ?? 0
    }

    init(
        date: Date,
        rawDate: String,
        formattedDate: String,
        value: Double,
        formattedValue: String,
        changeFromPrevious: Double?,
        formattedChange: String
    ) {
        self.id = date
        self.date = date
        self.rawDate = rawDate
        self.formattedDate = formattedDate
        self.value = value
        self.formattedValue = formattedValue
        self.changeFromPrevious = changeFromPrevious
        self.formattedChange = formattedChange
    }
}

// MARK: - Export Format

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv = "CSV"
    case json = "JSON"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .json: return "json"
        }
    }

    var contentType: String {
        switch self {
        case .csv: return "text/csv"
        case .json: return "application/json"
        }
    }
}

// MARK: - Regression

/// Ordinary least squares fit between two aligned series.
struct RegressionResult: Equatable, Sendable {
    let slope: Double
    let intercept: Double
    /// Share of the dependent series' variance the fit explains, 0–1.
    let rSquared: Double
    let standardErrorOfSlope: Double?
    let sampleCount: Int

    init(slope: Double, intercept: Double, rSquared: Double, standardErrorOfSlope: Double?, sampleCount: Int) {
        self.slope = slope
        self.intercept = intercept
        self.rSquared = rSquared
        self.standardErrorOfSlope = standardErrorOfSlope
        self.sampleCount = sampleCount
    }

    /// Slope divided by its standard error. Roughly, |t| above 2 is the conventional
    /// threshold for "distinguishable from no relationship at all".
    var tStatistic: Double? {
        guard let standardErrorOfSlope, standardErrorOfSlope > 0 else { return nil }
        let value = slope / standardErrorOfSlope
        return value.isFinite ? value : nil
    }

    /// True when the slope is at least twice its standard error.
    var isSlopeDistinguishableFromZero: Bool {
        guard let tStatistic else { return false }
        return abs(tStatistic) >= 2
    }

    var formattedRSquared: String {
        String(format: "%.3f", rSquared)
    }

    var formattedTStatistic: String {
        guard let tStatistic else { return "n/a" }
        return String(format: "%+.2f", tStatistic)
    }

    /// Plain-language reading of the fit, stated as a magnitude rather than a coefficient.
    func interpretation(xUnits: String, yUnits: String) -> String {
        let strength: String
        switch rSquared {
        case 0.7...: strength = "explains most of"
        case 0.4..<0.7: strength = "explains much of"
        case 0.15..<0.4: strength = "explains some of"
        default: strength = "explains little of"
        }

        let direction = slope >= 0 ? "rise" : "fall"
        let magnitude = String(format: "%.3g", abs(slope))
        let caveat = isSlopeDistinguishableFromZero
            ? ""
            : " The slope is small relative to its own uncertainty, so treat it as suggestive at best."

        return "A one-\(xUnits.lowercased()) increase goes with a \(magnitude) \(yUnits.lowercased()) \(direction), "
            + "and the fit \(strength) the variation across \(sampleCount) aligned observations.\(caveat)"
    }
}

/// One plotted point of a scatter, carrying its date so the chart can shade by time.
struct ScatterPoint: Identifiable, Hashable, Sendable {
    var id: Date { date }

    let date: Date
    let x: Double
    let y: Double
}

// MARK: - Insights

struct SeriesInsight: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let symbol: String

    init(id: String, title: String, value: String, detail: String, symbol: String) {
        self.id = id
        self.title = title
        self.value = value
        self.detail = detail
        self.symbol = symbol
    }
}

/// Relationship between the primary series and one comparison series.
struct ComparisonSummary: Identifiable, Hashable, Sendable {
    let id: String
    let seriesTitle: String
    let overlappingObservations: Int
    let correlation: Double?

    var formattedCorrelation: String {
        guard let correlation, correlation.isFinite else { return "n/a" }
        return String(format: "%.2f", correlation)
    }

    var interpretation: String {
        guard let correlation, correlation.isFinite, overlappingObservations >= 3 else {
            return "Not enough overlapping observations in this window to measure a relationship."
        }

        let strength: String
        switch abs(correlation) {
        case 0.85...: strength = "very strong"
        case 0.6..<0.85: strength = "strong"
        case 0.35..<0.6: strength = "moderate"
        case 0.15..<0.35: strength = "weak"
        default: strength = "negligible"
        }

        let direction = correlation >= 0 ? "positive" : "negative"
        let sentenceCasedStrength = strength.prefix(1).uppercased() + strength.dropFirst()
        return "\(sentenceCasedStrength) \(direction) co-movement across \(overlappingObservations) aligned observations."
    }
}

// MARK: - Search Query

/// Helpers for interpreting what the reader typed into the search field.
enum SearchQuery {
    /// True when the query looks like a FRED series identifier rather than prose.
    ///
    /// FRED IDs are short, unspaced, and upper-case alphanumeric with occasional
    /// separators ("GDPC1", "DGS10", "MKTGDPCNA646NWDB").
    static func looksLikeSeriesID(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...40).contains(trimmed.count) else { return false }
        guard trimmed == trimmed.uppercased() else { return false }
        guard trimmed.contains(where: \.isLetter) else { return false }

        return trimmed.allSatisfy { character in
            character.isLetter || character.isNumber || character == "_" || character == "-"
        }
    }

    /// Moves an exact identifier match to the front of the result list.
    ///
    /// Searching "GDPC1" ranks by popularity, which can bury the series the reader
    /// actually named several rows down.
    static func promotingExactMatch(in results: [FREDSeries], for query: String) -> [FREDSeries] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = results.firstIndex(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }),
              index != 0 else {
            return results
        }

        var reordered = results
        let match = reordered.remove(at: index)
        reordered.insert(match, at: 0)
        return reordered
    }
}
