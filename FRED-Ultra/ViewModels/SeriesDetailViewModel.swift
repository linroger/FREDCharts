import Foundation
import SwiftUI

@MainActor
class SeriesDetailViewModel: ObservableObject {
    @Published var mainSeries: FREDSeries
    @Published var seriesData: [String: [FREDObservation]] = [:]
    @Published var additionalSeries: [FREDSeries] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var selectedDateRange: DateRangeOption = .fiveYears
    @Published var selectedObservation: ChartDataPoint?
    @Published var chartDataPoints: [ChartDataPoint] = []
    @Published var unitsWarning: String?
    
    // Statistics
    @Published var statistics: SeriesStatistics?

    init(series: FREDSeries) {
        self.mainSeries = series
    }

    var allSeries: [FREDSeries] {
        [mainSeries] + additionalSeries
    }
    
    var mainSeriesObservations: [FREDObservation] {
        seriesData[mainSeries.id] ?? []
    }
    
    var filteredObservations: [FREDObservation] {
        filterObservations(mainSeriesObservations, by: selectedDateRange)
    }
    
    var tableRows: [ObservationRow] {
        filteredObservations.reversed().map { ObservationRow(observation: $0, units: mainSeries.units) }
    }
    
    // Unit-aware value formatter for the main series
    var valueFormatter: ValueFormatter {
        ValueFormatter(units: mainSeries.units)
    }

    func loadData() async {
        isLoading = true
        errorMessage = nil

        let idsToFetch = allSeries.map { $0.id }

        do {
            let data = try await FREDService.shared.getMultipleSeriesObservations(
                seriesIds: idsToFetch,
                startDate: selectedDateRange.startDate
            )
            self.seriesData = data
            updateChartDataPoints()
            calculateStatistics()
            checkUnitsCompatibility()
        } catch {
            self.errorMessage = error.localizedDescription
        }

        isLoading = false
    }
    
    func refreshData() async {
        await loadData()
    }
    
    private func checkUnitsCompatibility() {
        guard additionalSeries.count > 0 else {
            unitsWarning = nil
            return
        }
        
        let mainUnits = mainSeries.units.lowercased()
        let incompatible = additionalSeries.filter { 
            $0.units.lowercased() != mainUnits 
        }
        
        if !incompatible.isEmpty {
            unitsWarning = "Warning: Series have different units and may not be directly comparable."
        } else {
            unitsWarning = nil
        }
    }
    
    private func updateChartDataPoints() {
        var points: [ChartDataPoint] = []
        
        for series in allSeries {
            if let observations = seriesData[series.id] {
                let filtered = filterObservations(observations, by: selectedDateRange)
                for obs in filtered {
                    if let point = ChartDataPoint(observation: obs, seriesId: series.id, seriesTitle: series.title) {
                        points.append(point)
                    }
                }
            }
        }
        
        chartDataPoints = points
    }
    
    private func filterObservations(_ observations: [FREDObservation], by range: DateRangeOption) -> [FREDObservation] {
        guard let startDate = range.startDate else {
            return observations
        }
        
        return observations.filter { obs in
            guard let date = obs.dateObject else { return false }
            return date >= startDate
        }
    }
    
    private func calculateStatistics() {
        let observations = filteredObservations
        guard !observations.isEmpty else {
            statistics = nil
            return
        }
        
        let values = observations.compactMap { $0.doubleValue }
        guard !values.isEmpty else {
            statistics = nil
            return
        }
        
        let sortedValues = values.sorted()
        let sum = values.reduce(0, +)
        let mean = sum / Double(values.count)
        
        let squaredDiffs = values.map { pow($0 - mean, 2) }
        let variance = squaredDiffs.reduce(0, +) / Double(values.count)
        let stdDev = sqrt(variance)
        
        let latestValue = values.last ?? 0
        let previousValue = values.count > 1 ? values[values.count - 2] : latestValue
        let change = latestValue - previousValue
        let percentChange = previousValue != 0 ? (change / abs(previousValue)) * 100 : 0
        
        statistics = SeriesStatistics(
            count: values.count,
            min: sortedValues.first ?? 0,
            max: sortedValues.last ?? 0,
            mean: mean,
            median: sortedValues[sortedValues.count / 2],
            standardDeviation: stdDev,
            latestValue: latestValue,
            latestChange: change,
            latestPercentChange: percentChange,
            units: mainSeries.units
        )
    }

    func addSeries(_ series: FREDSeries) {
        guard !allSeries.contains(where: { $0.id == series.id }) else { return }
        additionalSeries.append(series)
        Task {
            await loadData()
        }
    }

    func removeSeries(_ series: FREDSeries) {
        if series.id == mainSeries.id { return }
        additionalSeries.removeAll { $0.id == series.id }
        seriesData.removeValue(forKey: series.id)
        updateChartDataPoints()
        checkUnitsCompatibility()
    }
    
    func updateDateRange(_ range: DateRangeOption) {
        selectedDateRange = range
        Task {
            await loadData()
        }
    }
    
    // MARK: - Export Functions
    
    func exportData(format: ExportFormat) {
        let observations = filteredObservations
        
        let content: String
        switch format {
        case .csv:
            content = ExportService.exportToCSV(series: mainSeries, observations: observations)
        case .json:
            content = ExportService.exportToJSON(series: mainSeries, observations: observations)
        }
        
        let filename = "\(mainSeries.id)_\(selectedDateRange.rawValue.replacingOccurrences(of: " ", with: "_"))"
        ExportService.saveFile(content: content, filename: filename, format: format)
    }
    
    func copyToClipboard() {
        let observations = filteredObservations
        var text = "Date\tValue\n"
        for obs in observations {
            text += "\(obs.date)\t\(obs.value)\n"
        }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Value Formatter (Unit-Aware)

struct ValueFormatter {
    let units: String
    
    private var isBillions: Bool {
        units.lowercased().contains("billion")
    }
    
    private var isMillions: Bool {
        units.lowercased().contains("million")
    }
    
    private var isPercent: Bool {
        units.lowercased().contains("percent")
    }
    
    private var isDollars: Bool {
        units.lowercased().contains("dollar")
    }
    
    private var isIndex: Bool {
        units.lowercased().contains("index")
    }
    
    /// Format a raw value from the API with full context
    func formatValue(_ value: Double, compact: Bool = false) -> String {
        if isPercent {
            return String(format: "%.2f%%", value)
        }
        
        if isBillions {
            // Value is already in billions, convert to human-readable
            return formatCurrency(value * 1_000_000_000, compact: compact)
        }
        
        if isMillions {
            // Value is already in millions
            return formatCurrency(value * 1_000_000, compact: compact)
        }
        
        if isDollars {
            return formatCurrency(value, compact: compact)
        }
        
        if isIndex {
            return String(format: "%.1f", value)
        }
        
        // Default formatting
        return formatDecimal(value)
    }
    
    /// Format for chart Y-axis labels
    func formatAxisValue(_ value: Double) -> String {
        if isPercent {
            return String(format: "%.1f%%", value)
        }
        
        if isBillions {
            // Value on axis is already multiplied, so divide back
            let actualValue = value
            if actualValue >= 1_000 {
                return "$\(formatCompact(actualValue / 1_000))T"
            } else {
                return "$\(formatCompact(actualValue))B"
            }
        }
        
        if isMillions {
            let actualValue = value
            if actualValue >= 1_000 {
                return "$\(formatCompact(actualValue / 1_000))B"
            } else {
                return "$\(formatCompact(actualValue))M"
            }
        }
        
        if isDollars {
            return formatCurrency(value, compact: true)
        }
        
        return formatCompact(value)
    }
    
    private func formatCurrency(_ value: Double, compact: Bool) -> String {
        if compact {
            if abs(value) >= 1_000_000_000_000 {
                return String(format: "$%.1fT", value / 1_000_000_000_000)
            } else if abs(value) >= 1_000_000_000 {
                return String(format: "$%.1fB", value / 1_000_000_000)
            } else if abs(value) >= 1_000_000 {
                return String(format: "$%.1fM", value / 1_000_000)
            } else if abs(value) >= 1_000 {
                return String(format: "$%.1fK", value / 1_000)
            }
        }
        
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "$\(value)"
    }
    
    private func formatDecimal(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
    
    private func formatCompact(_ value: Double) -> String {
        if abs(value) >= 1_000_000_000_000 {
            return String(format: "%.1fT", value / 1_000_000_000_000)
        } else if abs(value) >= 1_000_000_000 {
            return String(format: "%.1fB", value / 1_000_000_000)
        } else if abs(value) >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        } else if abs(value) >= 1_000 {
            return String(format: "%.1fK", value / 1_000)
        } else {
            return String(format: "%.1f", value)
        }
    }
}

// MARK: - Statistics Model
struct SeriesStatistics {
    let count: Int
    let min: Double
    let max: Double
    let mean: Double
    let median: Double
    let standardDeviation: Double
    let latestValue: Double
    let latestChange: Double
    let latestPercentChange: Double
    let units: String
    
    private var formatter: ValueFormatter {
        ValueFormatter(units: units)
    }
    
    var formattedMin: String { formatter.formatValue(min, compact: true) }
    var formattedMax: String { formatter.formatValue(max, compact: true) }
    var formattedMean: String { formatter.formatValue(mean, compact: true) }
    var formattedMedian: String { formatter.formatValue(median, compact: true) }
    var formattedStdDev: String { formatNumber(standardDeviation) }
    var formattedLatestValue: String { formatter.formatValue(latestValue, compact: true) }
    var formattedLatestChange: String {
        let sign = latestChange >= 0 ? "+" : ""
        return "\(sign)\(formatter.formatValue(latestChange, compact: true))"
    }
    var formattedPercentChange: String {
        let sign = latestPercentChange >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", latestPercentChange))%"
    }
    
    private func formatNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}
