import AppKit
import Foundation

@MainActor
final class SeriesDetailViewModel: ObservableObject {
    @Published var mainSeries: FREDSeries
    @Published private(set) var seriesData: [String: [FREDObservation]] = [:]
    @Published private(set) var additionalSeries: [FREDSeries] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedDateRange: DateRangeOption = .fiveYears
    @Published var selectedObservation: ChartDataPoint?
    @Published private(set) var chartDataPoints: [ChartDataPoint] = []
    @Published private(set) var rebasedChartDataPoints: [ChartDataPoint] = []
    @Published private(set) var unitsInfo: String?
    @Published var isNormalized = false
    @Published private(set) var statistics: SeriesStatistics?
    @Published private(set) var insights: [SeriesInsight] = []

    init(series: FREDSeries) {
        mainSeries = series
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

    var canNormalize: Bool {
        allSeries.count > 1
    }

    var displayDataPoints: [ChartDataPoint] {
        isNormalized ? rebasedChartDataPoints : chartDataPoints
    }

    var valueFormatter: ValueFormatter {
        ValueFormatter(units: isNormalized ? "Index" : mainSeries.units)
    }

    var seriesCountLabel: String {
        allSeries.count == 1 ? "1 series loaded" : "\(allSeries.count) series loaded"
    }

    func loadData() async {
        isLoading = true
        errorMessage = nil
        AppLogger.detail.info("Loading data for \(self.allSeries.count) series")

        do {
            let data = try await FREDService.shared.getMultipleSeriesObservations(
                seriesIds: allSeries.map(\.id),
                startDate: selectedDateRange.startDate
            )
            seriesData = data
            rebuildDerivedState()
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.detail.error("Failed to load series detail: \(error.localizedDescription, privacy: .public)")
        }

        isLoading = false
    }

    func refreshData() async {
        await loadData()
    }

    func addSeries(_ series: FREDSeries) {
        guard !allSeries.contains(where: { $0.id == series.id }) else { return }
        additionalSeries.append(series)
        AppLogger.detail.info("Added comparison series \(series.id, privacy: .public)")
        Task { await loadData() }
    }

    func removeSeries(_ series: FREDSeries) {
        guard series.id != mainSeries.id else { return }
        additionalSeries.removeAll { $0.id == series.id }
        seriesData.removeValue(forKey: series.id)
        AppLogger.detail.info("Removed comparison series \(series.id, privacy: .public)")
        rebuildDerivedState()
    }

    func updateDateRange(_ range: DateRangeOption) {
        guard selectedDateRange != range else { return }
        selectedDateRange = range
        Task { await loadData() }
    }

    func setNormalization(_ enabled: Bool) {
        guard canNormalize else {
            isNormalized = false
            return
        }

        isNormalized = enabled
        updateUnitsInfo()
    }

    func exportData(format: ExportFormat) {
        let content: String

        switch format {
        case .csv:
            content = ExportService.exportToCSV(series: mainSeries, observations: filteredObservations)
        case .json:
            content = ExportService.exportToJSON(series: mainSeries, observations: filteredObservations)
        }

        let filename = "\(mainSeries.id)-\(selectedDateRange.rawValue.replacingOccurrences(of: " ", with: "-").lowercased())"
        ExportService.saveFile(content: content, filename: filename, format: format)
        AppLogger.export.info("Requested \(format.rawValue, privacy: .public) export for \(self.mainSeries.id, privacy: .public)")
    }

    func copyToClipboard() {
        let lines = filteredObservations.map { "\($0.date)\t\($0.value)" }
        let text = (["Date\tValue"] + lines).joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        AppLogger.export.info("Copied \(self.filteredObservations.count) rows to the clipboard")
    }

    private func rebuildDerivedState() {
        chartDataPoints = makeChartDataPoints(rebased: false)
        rebasedChartDataPoints = makeChartDataPoints(rebased: true)
        reconcileNormalizationMode()
        calculateStatistics()
        buildInsights()
        updateUnitsInfo()
    }

    private func reconcileNormalizationMode() {
        if !canNormalize {
            isNormalized = false
            return
        }

        let uniqueUnits = Set(allSeries.map { $0.units.lowercased() })
        if uniqueUnits.count > 1 {
            isNormalized = true
        }
    }

    private func makeChartDataPoints(rebased: Bool) -> [ChartDataPoint] {
        var points: [ChartDataPoint] = []

        for series in allSeries {
            let observations = filterObservations(seriesData[series.id] ?? [], by: selectedDateRange)
            let baseValue = observations.compactMap(\.doubleValue).first

            for observation in observations {
                guard let date = observation.dateObject,
                      let rawValue = observation.doubleValue else {
                    continue
                }

                let value: Double
                if rebased, let baseValue, baseValue != 0 {
                    value = (rawValue / baseValue) * 100
                } else {
                    value = rawValue
                }

                points.append(
                    ChartDataPoint(
                        seriesId: series.id,
                        seriesTitle: series.title,
                        date: date,
                        value: value
                    )
                )
            }
        }

        return points
    }

    private func filterObservations(_ observations: [FREDObservation], by range: DateRangeOption) -> [FREDObservation] {
        guard let startDate = range.startDate else { return observations }

        return observations.filter { observation in
            guard let date = observation.dateObject else { return false }
            return date >= startDate
        }
    }

    private func calculateStatistics() {
        let typedObservations = filteredObservations.compactMap { observation -> (Date, Double)? in
            guard let date = observation.dateObject,
                  let value = observation.doubleValue else {
                return nil
            }
            return (date, value)
        }

        guard !typedObservations.isEmpty else {
            statistics = nil
            return
        }

        let values = typedObservations.map(\.1)
        let sortedValues = values.sorted()
        let sum = values.reduce(0, +)
        let mean = sum / Double(values.count)
        let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count)
        let latestValue = values.last ?? 0
        let previousValue = values.dropLast().last ?? latestValue
        let latestChange = latestValue - previousValue
        let latestPercentChange = previousValue == 0 ? 0 : (latestChange / abs(previousValue)) * 100
        let firstValue = values.first ?? latestValue
        let totalChange = latestValue - firstValue
        let years = max((typedObservations.last?.0.timeIntervalSince(typedObservations.first?.0 ?? Date()) ?? 0) / (60 * 60 * 24 * 365.25), 0)

        let annualizedChange: Double
        if years > 0 {
            if firstValue > 0, latestValue > 0 {
                annualizedChange = (pow(latestValue / firstValue, 1 / years) - 1) * 100
            } else if firstValue != 0 {
                annualizedChange = ((totalChange / abs(firstValue)) / years) * 100
            } else {
                annualizedChange = 0
            }
        } else {
            annualizedChange = 0
        }

        let median: Double
        if sortedValues.count.isMultiple(of: 2), sortedValues.count >= 2 {
            let upperIndex = sortedValues.count / 2
            median = (sortedValues[upperIndex - 1] + sortedValues[upperIndex]) / 2
        } else {
            median = sortedValues[sortedValues.count / 2]
        }

        statistics = SeriesStatistics(
            count: values.count,
            min: sortedValues.first ?? 0,
            max: sortedValues.last ?? 0,
            mean: mean,
            median: median,
            standardDeviation: sqrt(variance),
            latestValue: latestValue,
            latestChange: latestChange,
            latestPercentChange: latestPercentChange,
            firstValue: firstValue,
            totalChange: totalChange,
            annualizedChange: annualizedChange,
            range: (sortedValues.last ?? 0) - (sortedValues.first ?? 0),
            units: mainSeries.units
        )
    }

    private func buildInsights() {
        guard let statistics else {
            insights = []
            return
        }

        let percentile: Double
        if statistics.range == 0 {
            percentile = 100
        } else {
            percentile = ((statistics.latestValue - statistics.min) / statistics.range) * 100
        }

        let trendDescriptor: String
        switch statistics.latestPercentChange {
        case let change where change > 1:
            trendDescriptor = "Momentum is trending upward versus the prior observation."
        case let change where change < -1:
            trendDescriptor = "Momentum is trending downward versus the prior observation."
        default:
            trendDescriptor = "The latest reading is broadly flat versus the prior observation."
        }

        insights = [
            SeriesInsight(
                title: "Range Position",
                value: String(format: "%.0f%%", percentile),
                detail: "Latest value sits \(String(format: "%.0f", percentile))% of the way between the selected range's low and high.",
                symbol: "scope"
            ),
            SeriesInsight(
                title: "Period Change",
                value: statistics.formattedTotalChange,
                detail: "Change from the first to the latest observation in the current time window.",
                symbol: "arrow.left.and.right"
            ),
            SeriesInsight(
                title: "Annualized Drift",
                value: statistics.formattedAnnualizedChange,
                detail: "Compound annualized change across the selected date range.",
                symbol: "point.topleft.down.curvedto.point.bottomright.up"
            ),
            SeriesInsight(
                title: "Volatility",
                value: statistics.formattedStdDev,
                detail: "Standard deviation of the visible observations.",
                symbol: "waveform.path.ecg"
            ),
            SeriesInsight(
                title: "Trend Read",
                value: statistics.formattedPercentChange,
                detail: trendDescriptor,
                symbol: "chart.line.uptrend.xyaxis"
            )
        ]
    }

    private func updateUnitsInfo() {
        guard canNormalize else {
            unitsInfo = nil
            return
        }

        let uniqueUnits = Set(allSeries.map(\.units))
        if isNormalized {
            unitsInfo = "Comparison mode rebases each series to 100 at the start of the selected range."
        } else if uniqueUnits.count > 1 {
            unitsInfo = "These series use different units. Enable comparison mode to compare relative movement instead of raw values."
        } else {
            unitsInfo = "All visible series share the same units. You can still rebase them to compare relative performance."
        }
    }
}
