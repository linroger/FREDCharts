import Foundation

/// Owns everything shown on the series detail surface: loaded history, the visible
/// window, the active transform, and every derived chart, table, and statistic.
///
/// The pipeline is deliberately one-directional and recomputed in a single place:
///
///     full history → optional unit rescaling → transform → window → rebase → derived state
///
/// Full history is fetched once per series and windowed locally, so changing the date
/// range or the transform is instant and issues no network traffic.
@MainActor
final class SeriesDetailViewModel: ObservableObject {
    typealias ObservationsLoader = @Sendable (_ ids: [String], _ forceRefresh: Bool) async -> [SeriesLoadResult]

    // MARK: Inputs

    @Published private(set) var mainSeries: FREDSeries
    @Published private(set) var comparisonSeries: [FREDSeries]
    @Published private(set) var selectedRange: DateRangeOption
    @Published private(set) var transform: SeriesTransform = .level
    @Published private(set) var movingAverage: MovingAverageOption = .off

    // MARK: Status

    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Non-fatal problems, such as one comparison series failing while the rest load.
    @Published private(set) var warnings: [String] = []

    // MARK: Derived state

    @Published private(set) var chartPoints: [ChartDataPoint] = []
    @Published private(set) var statistics: SeriesStatistics?
    @Published private(set) var insights: [SeriesInsight] = []
    @Published private(set) var comparisonSummaries: [ComparisonSummary] = []
    @Published private(set) var unitsNotice: String?
    @Published private(set) var displayUnits: String = ""
    @Published private(set) var isChartDownsampled = false
    @Published private(set) var visibleObservationCount = 0

    // MARK: Storage

    private var fullHistory: [String: [SeriesDataPoint]] = [:]
    private var windowedSeries: [String: [SeriesDataPoint]] = [:]
    private var tableRowsCache: (token: Int, rows: [ObservationRow])?

    private var derivedToken = 0
    private var loadToken = 0
    /// Once the reader picks a transform, the app stops choosing one for them.
    private var transformChosenByUser = false

    private let loader: ObservationsLoader
    private let calendar: Calendar
    private let chartPointBudget: Int

    /// Marks per series above which Swift Charts starts dropping frames on redraw.
    nonisolated static let defaultChartPointBudget = 1_500

    nonisolated static let defaultLoader: ObservationsLoader = { ids, forceRefresh in
        await FREDService.shared.loadSeries(ids: ids, forceRefresh: forceRefresh)
    }

    init(
        series: FREDSeries,
        comparisonSeries: [FREDSeries] = [],
        initialHistory: [String: [SeriesDataPoint]] = [:],
        selectedRange: DateRangeOption = .fiveYears,
        transform: SeriesTransform = .level,
        calendar: Calendar = .current,
        chartPointBudget: Int = SeriesDetailViewModel.defaultChartPointBudget,
        loader: @escaping ObservationsLoader = SeriesDetailViewModel.defaultLoader
    ) {
        self.mainSeries = series
        self.comparisonSeries = comparisonSeries
        self.selectedRange = selectedRange
        self.transform = transform
        self.calendar = calendar
        self.chartPointBudget = chartPointBudget
        self.loader = loader
        self.fullHistory = initialHistory

        if !initialHistory.isEmpty {
            rebuildDerivedState()
        }
    }

    // MARK: Composition

    var allSeries: [FREDSeries] { [mainSeries] + comparisonSeries }

    var canCompare: Bool { !comparisonSeries.isEmpty }

    var seriesCountLabel: String {
        allSeries.count == 1 ? "1 series loaded" : "\(allSeries.count) series loaded"
    }

    /// Units of the values the chart and metric tiles render, which is not always the
    /// series' raw units — a "Billions of Dollars" series is charted in dollars.
    var displayUnitsLabel: String {
        let label = UnitDescriptor.cached(units: displayUnits).presentationUnits
        return label.isEmpty ? "Value" : label
    }

    /// Units of the values in the Data tab and exports, which are always as published.
    var publishedUnitsLabel: String {
        displayUnits.isEmpty ? "Value" : displayUnits
    }

    var chartSectionTitle: String {
        canCompare ? "Comparison Chart — \(displayUnitsLabel)" : "Series Chart — \(displayUnitsLabel)"
    }

    /// Date of the newest visible observation, without materialising the table rows.
    var latestVisibleDate: Date? {
        windowedSeries[mainSeries.id]?.last?.date
    }

    /// Number of dated rows an export would contain across every visible series.
    var exportRowCount: Int {
        var dates = Set<Date>()
        for series in allSeries {
            for point in windowedSeries[series.id] ?? [] {
                dates.insert(point.date)
            }
        }
        return dates.count
    }

    var movingAverageLabel: String {
        movingAverage.label(for: mainSeries.seriesFrequency)
    }

    /// True once the primary series has at least one observation loaded.
    var hasLoadedHistory: Bool {
        !(fullHistory[mainSeries.id]?.isEmpty ?? true)
    }

    /// History exists, but the chosen window contains none of it.
    var isWindowEmpty: Bool {
        hasLoadedHistory && (windowedSeries[mainSeries.id]?.isEmpty ?? true)
    }

    var emptyWindowMessage: String {
        let coverage = mainSeries.formattedDateRange
        return "\(mainSeries.id) has no observations in the \(selectedRange.rawValue.lowercased()) window. Published coverage is \(coverage)."
    }

    var transformExplanation: String {
        transform.explanation(frequency: mainSeries.seriesFrequency)
    }

    /// Latest observation date of the primary series; windows are measured back from
    /// here so discontinued series still show data.
    var anchorDate: Date {
        if let last = fullHistory[mainSeries.id]?.last?.date { return last }
        let latest = allSeries.compactMap { fullHistory[$0.id]?.last?.date }.max()
        return latest ?? Date()
    }

    /// Rows for the Data tab, newest first.
    ///
    /// Built on demand and memoised against the derived-state token: formatting tens of
    /// thousands of rows on every state change is wasted work when the tab is not visible.
    var tableRows: [ObservationRow] {
        if let cache = tableRowsCache, cache.token == derivedToken {
            return cache.rows
        }

        let rows = buildTableRows()
        tableRowsCache = (derivedToken, rows)
        return rows
    }

    var valueFormatter: ValueFormatter {
        ValueFormatter(units: displayUnits)
    }

    // MARK: Loading

    func loadData(forceRefresh: Bool = false) async {
        loadToken &+= 1
        let token = loadToken

        isLoading = true
        defer {
            if token == loadToken { isLoading = false }
        }

        let ids = allSeries.map(\.id)
        AppLogger.detail.info("Loading \(ids.count) series (forceRefresh: \(forceRefresh))")

        let results = await loader(ids, forceRefresh)
        guard token == loadToken else { return }

        var comparisonFailures: [String] = []
        var primaryFailure: String?

        for result in results {
            if result.succeeded {
                fullHistory[result.seriesId] = result.points
                continue
            }

            fullHistory[result.seriesId] = []
            let message = result.failureMessage ?? "Unknown error"

            if result.seriesId == mainSeries.id {
                primaryFailure = message
            } else {
                comparisonFailures.append("\(result.seriesId): \(message)")
            }
        }

        // Drop history for series that are no longer displayed.
        let liveIDs = Set(ids)
        fullHistory = fullHistory.filter { liveIDs.contains($0.key) }

        warnings = comparisonFailures
        errorMessage = primaryFailure
        rebuildDerivedState()
    }

    func refreshData() async {
        await loadData(forceRefresh: true)
    }

    // MARK: Mutations

    /// Adds a comparison series and loads it.
    ///
    /// `async` rather than fire-and-forget so callers can await the finished state; the
    /// previous detached `Task` left observers reading a half-updated view model.
    func addSeries(_ series: FREDSeries) async {
        guard !allSeries.contains(where: { $0.id == series.id }) else { return }

        comparisonSeries.append(series)

        // Series with incompatible units cannot honestly share a value axis. Unless the
        // reader has already picked a transform, switch to an index comparison.
        if !transformChosenByUser, !transform.isUnitNeutral, !Self.unitsAreComparable(allSeries) {
            transform = .indexed
            AppLogger.detail.info("Switched to indexed comparison: \(series.id, privacy: .public) uses incompatible units")
        }

        AppLogger.detail.info("Added comparison series \(series.id, privacy: .public)")
        await loadData()
    }

    func removeSeries(id seriesId: String) {
        guard seriesId != mainSeries.id else { return }
        guard comparisonSeries.contains(where: { $0.id == seriesId }) else { return }

        comparisonSeries.removeAll { $0.id == seriesId }
        fullHistory.removeValue(forKey: seriesId)
        windowedSeries.removeValue(forKey: seriesId)
        // The series is gone, so any load warning about it is stale.
        warnings.removeAll { $0.hasPrefix("\(seriesId):") }

        AppLogger.detail.info("Removed comparison series \(seriesId, privacy: .public)")
        rebuildDerivedState()
    }

    func updateRange(_ range: DateRangeOption) {
        guard selectedRange != range else { return }
        selectedRange = range
        rebuildDerivedState()
    }

    func updateTransform(_ newTransform: SeriesTransform) {
        // Recorded before the early exit: re-picking the current transform is still an
        // explicit choice, and the app must stop overriding it when a series is added.
        transformChosenByUser = true

        guard transform != newTransform else { return }
        transform = newTransform
        rebuildDerivedState()
    }

    func updateMovingAverage(_ option: MovingAverageOption) {
        guard movingAverage != option else { return }
        movingAverage = option
        rebuildDerivedState()
    }

    // MARK: Export

    func makeExportPayload() -> ExportPayload {
        let baseUnits = effectiveBaseUnits
        return ExportPayload(
            rangeLabel: selectedRange.rawValue,
            transform: transform,
            columns: allSeries.map { series in
                ExportPayload.SeriesColumn(
                    series: series,
                    units: usesSharedUnitScale ? baseUnits : series.units,
                    points: windowedSeries[series.id] ?? []
                )
            }
        )
    }

    func export(format: ExportFormat) async -> ExportOutcome {
        let payload = makeExportPayload()

        guard !payload.isEmpty else {
            return .failed("There is nothing to export in the current window.")
        }

        let name = "\(mainSeries.id)-\(selectedRange.rawValue)-\(transform.shortLabel)"
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()

        AppLogger.export.info("Exporting \(format.rawValue, privacy: .public) for \(self.mainSeries.id, privacy: .public)")
        return await ExportService.save(content: ExportService.content(for: payload, format: format), suggestedName: name, format: format)
    }

    @discardableResult
    func copyToClipboard() -> Int {
        ExportService.copyToClipboard(makeExportPayload())
    }

    // MARK: Derived state

    /// True when several series share a unit family and can be plotted on one axis after
    /// magnitude normalisation ("Billions of Dollars" and "Dollars" both become dollars).
    private var usesSharedUnitScale: Bool {
        allSeries.count > 1 && Self.unitsAreComparable(allSeries)
    }

    private var effectiveBaseUnits: String {
        usesSharedUnitScale ? mainSeries.unitDescriptor.canonicalUnits : mainSeries.units
    }

    static func unitsAreComparable(_ series: [FREDSeries]) -> Bool {
        guard let first = series.first?.unitDescriptor else { return true }
        return series.dropFirst().allSatisfy { first.isComparable(to: $0.unitDescriptor) }
    }

    private func rebuildDerivedState() {
        derivedToken &+= 1
        tableRowsCache = nil

        let series = allSeries
        let sharedScale = usesSharedUnitScale
        displayUnits = transform.resultUnits(baseUnits: effectiveBaseUnits)

        let windowStart = selectedRange.startDate(anchoredTo: anchorDate, calendar: calendar)

        var newWindowed: [String: [SeriesDataPoint]] = [:]
        newWindowed.reserveCapacity(series.count)

        for entry in series {
            let raw = fullHistory[entry.id] ?? []

            // Normalise magnitudes only when the series genuinely share units.
            let scale = sharedScale ? entry.unitDescriptor.scale : 1
            let scaled = scale == 1 ? raw : raw.map { SeriesDataPoint(date: $0.date, value: $0.value * scale) }

            // Growth transforms run on the full history so the first visible point has a
            // real predecessor rather than being silently dropped.
            let transformed = SeriesAnalytics.applyTransform(scaled, transform: transform, calendar: calendar)
            var window = SeriesAnalytics.filter(transformed, from: windowStart)

            // Indexing is relative to what the reader can see, so it happens after windowing.
            if transform == .indexed {
                window = SeriesAnalytics.rebasedToOneHundred(window)
            }

            newWindowed[entry.id] = window
        }

        windowedSeries = newWindowed
        visibleObservationCount = newWindowed[mainSeries.id]?.count ?? 0

        rebuildChartPoints(for: series)
        rebuildStatisticsAndInsights()
        rebuildComparisonSummaries()
        rebuildUnitsNotice(sharedScale: sharedScale)
    }

    private func rebuildChartPoints(for series: [FREDSeries]) {
        var points: [ChartDataPoint] = []
        var downsampled = false

        for entry in series {
            let window = windowedSeries[entry.id] ?? []
            guard !window.isEmpty else { continue }

            let display = SeriesAnalytics.downsample(window, threshold: chartPointBudget)
            if display.count < window.count { downsampled = true }

            points.reserveCapacity(points.count + display.count)
            for point in display {
                points.append(
                    ChartDataPoint(seriesId: entry.id, seriesTitle: entry.title, date: point.date, value: point.value)
                )
            }
        }

        // The overlay is averaged at full resolution, then downsampled for drawing, so
        // smoothing is not applied to already-thinned data.
        if let window = movingAverage.window(for: mainSeries.seriesFrequency),
           let mainWindow = windowedSeries[mainSeries.id], mainWindow.count >= window {
            let averaged = SeriesAnalytics.movingAverage(mainWindow, window: window)
            let display = SeriesAnalytics.downsample(averaged, threshold: chartPointBudget)

            for point in display {
                points.append(
                    ChartDataPoint(
                        seriesId: mainSeries.id,
                        seriesTitle: mainSeries.title,
                        date: point.date,
                        value: point.value,
                        role: .movingAverage
                    )
                )
            }
        }

        chartPoints = points
        isChartDownsampled = downsampled
    }

    private func rebuildStatisticsAndInsights() {
        let window = windowedSeries[mainSeries.id] ?? []
        statistics = SeriesStatistics.make(points: window, units: displayUnits)
        insights = buildInsights()
    }

    private func buildInsights() -> [SeriesInsight] {
        guard let statistics else { return [] }

        var cards: [SeriesInsight] = [
            SeriesInsight(
                id: "range-position",
                title: "Range Position",
                value: statistics.formattedRangePosition,
                detail: "Where the latest reading sits between the window low (\(statistics.formattedMin)) and high (\(statistics.formattedMax)).",
                symbol: "scope"
            ),
            SeriesInsight(
                id: "period-change",
                title: "Period Change",
                value: statistics.formattedTotalChange,
                detail: "Movement from the first to the latest observation across \(statistics.formattedSpan).",
                symbol: "arrow.left.and.right"
            ),
            SeriesInsight(
                id: "volatility",
                title: "Volatility",
                value: statistics.formattedStdDev,
                detail: "Standard deviation of the \(statistics.count) visible observations.",
                symbol: "waveform.path.ecg"
            ),
            SeriesInsight(
                id: "z-score",
                title: "Latest vs Average",
                value: statistics.formattedZScore,
                detail: "Standard deviations between the latest reading and the window mean (\(statistics.formattedMean)).",
                symbol: "chart.bar.doc.horizontal"
            )
        ]

        // Compound growth and drawdown only describe levels; on a growth-rate series they
        // would compound a rate of change, which is not a meaningful quantity.
        if transform == .level {
            if statistics.annualizedChange != nil {
                cards.insert(
                    SeriesInsight(
                        id: "annualized",
                        title: "Annualized Drift",
                        value: statistics.formattedAnnualizedChange,
                        detail: "Compound annual growth implied by the first and latest observations.",
                        symbol: "point.topleft.down.curvedto.point.bottomright.up"
                    ),
                    at: 2
                )
            }

            if statistics.maxDrawdown != nil {
                cards.append(
                    SeriesInsight(
                        id: "drawdown",
                        title: "Max Drawdown",
                        value: statistics.formattedMaxDrawdown,
                        detail: "Deepest peak-to-trough decline inside the selected window.",
                        symbol: "arrow.down.right.circle"
                    )
                )
            }
        }

        let trend: String
        switch statistics.latestPercentChange {
        case .some(let change) where change > 1:
            trend = "The latest reading is up versus the prior observation."
        case .some(let change) where change < -1:
            trend = "The latest reading is down versus the prior observation."
        case .some:
            trend = "The latest reading is broadly flat versus the prior observation."
        case .none:
            trend = "There is no prior observation in this window to compare against."
        }

        cards.append(
            SeriesInsight(
                id: "trend",
                title: "Latest Move",
                value: statistics.formattedPercentChange,
                detail: trend,
                symbol: "chart.line.uptrend.xyaxis"
            )
        )

        return cards
    }

    private func rebuildComparisonSummaries() {
        guard canCompare, let mainWindow = windowedSeries[mainSeries.id], !mainWindow.isEmpty else {
            comparisonSummaries = []
            return
        }

        comparisonSummaries = comparisonSeries.map { series in
            let other = windowedSeries[series.id] ?? []
            let pairs = SeriesAnalytics.alignedPairs(mainWindow, other)

            return ComparisonSummary(
                id: series.id,
                seriesTitle: series.title,
                overlappingObservations: pairs.count,
                correlation: SeriesAnalytics.pearsonCorrelation(pairs)
            )
        }
    }

    private func rebuildUnitsNotice(sharedScale: Bool) {
        // With one series the transform is already explained beneath the chart.
        guard allSeries.count > 1 else {
            unitsNotice = nil
            return
        }

        if !Self.unitsAreComparable(allSeries), !transform.isUnitNeutral {
            let unitList = allSeries.map { "\($0.id) (\($0.units.isEmpty ? "units n/a" : $0.units))" }.joined(separator: ", ")
            unitsNotice = "These series do not share units — \(unitList). Switch to % Change, YoY %, or Index so the comparison is meaningful."
            return
        }

        if transform.isUnitNeutral {
            unitsNotice = transformExplanation
            return
        }

        if sharedScale, allSeries.contains(where: { $0.unitDescriptor.appliesScaleConversion }) {
            unitsNotice = "Values are converted to \(effectiveBaseUnits) so differently scaled series share one axis."
            return
        }

        unitsNotice = "All visible series already share comparable units."
    }

    // MARK: Queries

    /// One point per visible series, nearest to `date`.
    ///
    /// Reads full-resolution windowed data rather than the downsampled chart points, so
    /// the hover readout reports the real observation even when the chart is thinned.
    func nearestPoints(to date: Date) -> [ChartDataPoint] {
        allSeries.compactMap { series in
            guard let window = windowedSeries[series.id],
                  let index = Self.nearestIndex(in: window, to: date) else { return nil }

            let point = window[index]
            return ChartDataPoint(
                seriesId: series.id,
                seriesTitle: series.title,
                date: point.date,
                value: point.value
            )
        }
    }

    /// Binary search for the closest observation; windows are always sorted ascending.
    /// Returns `nil` for an empty window so callers cannot index out of bounds.
    static func nearestIndex(in points: [SeriesDataPoint], to date: Date) -> Int? {
        guard !points.isEmpty else { return nil }

        var low = 0
        var high = points.count - 1

        while low < high {
            let middle = (low + high) / 2
            if points[middle].date < date {
                low = middle + 1
            } else {
                high = middle
            }
        }

        guard low > 0 else { return 0 }

        let previous = low - 1
        let distanceToLow = abs(points[low].date.timeIntervalSince(date))
        let distanceToPrevious = abs(points[previous].date.timeIntervalSince(date))
        return distanceToLow < distanceToPrevious ? low : previous
    }

    private func buildTableRows() -> [ObservationRow] {
        let window = windowedSeries[mainSeries.id] ?? []
        guard !window.isEmpty else { return [] }

        let formatter = ValueFormatter(units: displayUnits)
        var rows: [ObservationRow] = []
        rows.reserveCapacity(window.count)

        // Chronological order gives each row its predecessor; the table is reversed after.
        for (index, point) in window.enumerated() {
            let change: Double? = index > 0 ? point.value - window[index - 1].value : nil

            rows.append(
                ObservationRow(
                    date: point.date,
                    rawDate: FREDDate.string(from: point.date),
                    formattedDate: FREDDate.displayString(from: point.date),
                    value: point.value,
                    formattedValue: formatter.formatPrecise(point.value),
                    changeFromPrevious: change,
                    formattedChange: change.map { formatter.formatPreciseChange($0) } ?? "—"
                )
            )
        }

        return rows.reversed()
    }
}
