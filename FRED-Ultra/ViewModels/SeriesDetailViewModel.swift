import AppKit
import Foundation

@MainActor
final class SeriesDetailViewModel: ObservableObject {
    typealias ObservationsLoader = ([String], Date?) async throws -> [String: [FREDObservation]]

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
    private let observationsLoader: ObservationsLoader

    init(
        series: FREDSeries,
        comparisonSeries: [FREDSeries] = [],
        initialSeriesData: [String: [FREDObservation]] = [:],
        observationsLoader: @escaping ObservationsLoader = { seriesIds, startDate in
            try await FREDService.shared.getMultipleSeriesObservations(
                seriesIds: seriesIds,
                startDate: startDate
            )
        }
    ) {
        mainSeries = series
        additionalSeries = comparisonSeries
        self.observationsLoader = observationsLoader

        if !initialSeriesData.isEmpty {
            seriesData = initialSeriesData
            rebuildDerivedState()
        }
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
        ValueFormatter(units: currentChartUnits)
    }

    var seriesCountLabel: String {
        allSeries.count == 1 ? "1 series loaded" : "\(allSeries.count) series loaded"
    }

    var chartSectionTitle: String {
        if isNormalized {
            return "Comparison Chart (Indexed to 100)"
        }

        if canNormalize, let absoluteComparisonUnits {
            return "Comparison Chart (\(absoluteComparisonUnits))"
        }

        return "Series Chart"
    }

    func loadData() async {
        isLoading = true
        errorMessage = nil
        AppLogger.detail.info("Loading data for \(self.allSeries.count) series")

        do {
            let data = try await observationsLoader(allSeries.map(\.id), selectedDateRange.startDate)
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
        selectedObservation = nil
        rebuildDerivedState()
        Task { await loadData() }
    }

    func setNormalization(_ enabled: Bool) {
        guard canNormalize else {
            isNormalized = false
            return
        }

        if !enabled, !supportsAbsoluteComparison {
            isNormalized = true
        } else {
            isNormalized = enabled
        }

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

        if !supportsAbsoluteComparison {
            isNormalized = true
        }
    }

    private func makeChartDataPoints(rebased: Bool) -> [ChartDataPoint] {
        var points: [ChartDataPoint] = []
        let descriptors = unitDescriptorsBySeriesID()
        let shouldConvertForAbsoluteComparison = supportsAbsoluteComparison && canNormalize

        for series in allSeries {
            let observations = filterObservations(seriesData[series.id] ?? [], by: selectedDateRange)
            let descriptor = descriptors[series.id] ?? UnitDescriptor(units: series.units)

            let comparableObservations = observations.compactMap { observation -> (Date, Double)? in
                guard let date = observation.dateObject,
                      let rawValue = observation.doubleValue else {
                    return nil
                }

                let absoluteValue = shouldConvertForAbsoluteComparison
                    ? descriptor.convertedValue(rawValue)
                    : rawValue
                return (date, absoluteValue)
            }

            let baseValue = comparableObservations.first?.1

            for (date, absoluteValue) in comparableObservations {
                let value: Double
                if rebased, let baseValue, baseValue != 0 {
                    value = (absoluteValue / baseValue) * 100
                } else {
                    value = absoluteValue
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

        if isNormalized {
            if let absoluteComparisonUnits, usesAutoConvertedAbsoluteValues {
                unitsInfo = "Absolute comparison automatically converts compatible series into \(absoluteComparisonUnits). Comparison mode rebases each series to 100 at the start of the selected range."
            } else {
                unitsInfo = "Comparison mode rebases each series to 100 at the start of the selected range."
            }
        } else if let absoluteComparisonUnits {
            if usesAutoConvertedAbsoluteValues {
                unitsInfo = "Absolute comparison automatically converts compatible series into \(absoluteComparisonUnits) so differently scaled values can be compared directly."
            } else {
                unitsInfo = "All visible series already share comparable units. You can still rebase them to compare relative performance."
            }
        } else {
            unitsInfo = "These series use incompatible units or price bases. Comparison mode stays enabled so you compare relative movement instead of mismatched raw values."
        }
    }

    private var currentChartUnits: String {
        if isNormalized {
            return "Index"
        }

        return absoluteComparisonUnits ?? mainSeries.units
    }

    private var absoluteComparisonUnits: String? {
        guard supportsAbsoluteComparison else { return nil }
        return unitDescriptorsBySeriesID()[mainSeries.id]?.canonicalUnits ?? UnitDescriptor(units: mainSeries.units).canonicalUnits
    }

    private var supportsAbsoluteComparison: Bool {
        guard canNormalize else { return false }

        let descriptors = allSeries.map { UnitDescriptor(units: $0.units) }
        guard let first = descriptors.first else { return false }

        return descriptors.dropFirst().allSatisfy { first.isComparable(to: $0) }
    }

    private var usesAutoConvertedAbsoluteValues: Bool {
        guard canNormalize, supportsAbsoluteComparison else { return false }

        let descriptors = unitDescriptorsBySeriesID()
        return allSeries.contains { series in
            guard let descriptor = descriptors[series.id] else { return false }
            return descriptor.appliesScaleConversion || descriptor.rawUnits.caseInsensitiveCompare(descriptor.canonicalUnits) != .orderedSame
        }
    }

    private func unitDescriptorsBySeriesID() -> [String: UnitDescriptor] {
        Dictionary(uniqueKeysWithValues: allSeries.map { series in
            (series.id, UnitDescriptor(units: series.units))
        })
    }
}
