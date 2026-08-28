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
    /// Supplies the NBER recession indicator. Returns an empty array on failure —
    /// missing shading is a cosmetic loss and must never fail a series load.
    typealias RecessionLoader = @Sendable () async -> [SeriesDataPoint]
    /// Supplies category, release, tag, and sibling-series context for one series.
    typealias RelationsLoader = @Sendable (_ seriesId: String) async -> SeriesRelations

    // MARK: Inputs

    @Published private(set) var mainSeries: FREDSeries
    @Published private(set) var comparisonSeries: [FREDSeries]
    @Published private(set) var window: DateWindow
    @Published private(set) var transform: SeriesTransform = .level
    @Published private(set) var movingAverage: MovingAverageOption = .off
    @Published private(set) var chartMode: ChartMode = .overlay

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
    @Published private(set) var showsRecessionShading: Bool
    /// Recession bands already clipped to the visible window.
    @Published private(set) var recessionIntervals: [DateInterval] = []
    @Published private(set) var relations: SeriesRelations?
    /// Which comparison series the relationship surface is fitted against.
    @Published private(set) var regressionPartnerID: String?
    @Published private(set) var scatterPoints: [ScatterPoint] = []
    @Published private(set) var regression: RegressionResult?
    @Published private(set) var isLoadingRelations = false

    // MARK: Storage

    private var fullHistory: [String: [SeriesDataPoint]] = [:]
    private var recessionSource: [SeriesDataPoint] = []
    private var windowedSeries: [String: [SeriesDataPoint]] = [:]
    /// The lines actually drawn: the source series in overlay mode, or the computed
    /// spreads in spread mode. Everything downstream — chart, statistics, table, export —
    /// reads from here, so the numbers can never disagree with the chart.
    private var displayedSeries: [DisplayedSeries] = []
    private var tableRowsCache: (token: Int, rows: [ObservationRow])?

    private var derivedToken = 0
    private var loadToken = 0
    /// Once the reader picks a transform, the app stops choosing one for them.
    private var transformChosenByUser = false

    /// One plotted line, whether it came straight from FRED or was computed.
    struct DisplayedSeries: Identifiable, Sendable {
        let id: String
        let title: String
        let points: [SeriesDataPoint]
    }

    private let loader: ObservationsLoader
    private let recessionLoader: RecessionLoader
    private let relationsLoader: RelationsLoader
    private let calendar: Calendar
    private let chartPointBudget: Int

    /// Marks per series above which Swift Charts starts dropping frames on redraw.
    nonisolated static let defaultChartPointBudget = 1_500

    nonisolated static let defaultLoader: ObservationsLoader = { ids, forceRefresh in
        await FREDService.shared.loadSeries(ids: ids, forceRefresh: forceRefresh)
    }

    nonisolated static let defaultRecessionLoader: RecessionLoader = {
        (try? await FREDService.shared.observations(seriesId: FREDService.recessionIndicatorSeriesID)) ?? []
    }

    nonisolated static let defaultRelationsLoader: RelationsLoader = { seriesId in
        (try? await FREDService.shared.relations(for: seriesId)) ?? SeriesRelations(seriesID: seriesId)
    }

    init(
        series: FREDSeries,
        comparisonSeries: [FREDSeries] = [],
        initialHistory: [String: [SeriesDataPoint]] = [:],
        selectedRange: DateRangeOption = .fiveYears,
        transform: SeriesTransform = .level,
        calendar: Calendar = .current,
        chartPointBudget: Int = SeriesDetailViewModel.defaultChartPointBudget,
        showsRecessionShading: Bool = true,
        loader: @escaping ObservationsLoader = SeriesDetailViewModel.defaultLoader,
        recessionLoader: @escaping RecessionLoader = SeriesDetailViewModel.defaultRecessionLoader,
        relationsLoader: @escaping RelationsLoader = SeriesDetailViewModel.defaultRelationsLoader
    ) {
        self.mainSeries = series
        self.comparisonSeries = comparisonSeries
        self.window = .preset(selectedRange)
        self.transform = transform
        self.calendar = calendar
        self.chartPointBudget = chartPointBudget
        self.showsRecessionShading = showsRecessionShading
        self.loader = loader
        self.recessionLoader = recessionLoader
        self.relationsLoader = relationsLoader
        self.fullHistory = initialHistory

        if !initialHistory.isEmpty {
            rebuildDerivedState()
        }
    }

    // MARK: Composition

    var allSeries: [FREDSeries] { [mainSeries] + comparisonSeries }

    var canCompare: Bool { !comparisonSeries.isEmpty }

    /// The active preset, or `nil` while a custom interval is in force.
    var selectedRange: DateRangeOption? { window.preset }

    /// Human label for the active window, used by the UI, exports, and filenames.
    var rangeLabel: String { window.label }

    /// Span the loaded data actually covers, which bounds the custom-range pickers so a
    /// reader cannot choose a window with nothing in it.
    var availableDateRange: ClosedRange<Date>? {
        let starts = allSeries.compactMap { fullHistory[$0.id]?.first?.date }
        let ends = allSeries.compactMap { fullHistory[$0.id]?.last?.date }

        guard let lower = starts.min(), let upper = ends.max(), lower <= upper else { return nil }
        return lower...upper
    }

    var seriesCountLabel: String {
        allSeries.count == 1 ? "1 series loaded" : "\(allSeries.count) series loaded"
    }

    /// Units of the values the chart and metric tiles render, which is not always the
    /// series' raw units — a "Billions of Dollars" series is charted in dollars.
    var displayUnitsLabel: String {
        let label = valueFormatter.presentationUnits
        return label.isEmpty ? "Value" : label
    }

    /// Units of the values in the Data tab and exports, which are always as published.
    var publishedUnitsLabel: String {
        displayUnits.isEmpty ? "Value" : displayUnits
    }

    var chartSectionTitle: String {
        switch chartMode {
        case .spread:
            return "Spread Chart — \(displayUnitsLabel)"
        case .overlay:
            return canCompare ? "Comparison Chart — \(displayUnitsLabel)" : "Series Chart — \(displayUnitsLabel)"
        }
    }

    /// Spreads are only meaningful between series measured in the same thing.
    var canUseSpreadMode: Bool {
        canCompare && Self.unitsAreComparable(allSeries)
    }

    var spreadUnavailableReason: String? {
        if !canCompare {
            return "Add a comparison series to chart a spread."
        }
        if !Self.unitsAreComparable(allSeries) {
            return "A spread needs series measured in the same units."
        }
        return nil
    }

    /// The line the statistics, data table, and metric tiles describe.
    private var primaryDisplayPoints: [SeriesDataPoint] {
        displayedSeries.first?.points ?? []
    }

    /// Date of the newest visible observation, without materialising the table rows.
    var latestVisibleDate: Date? {
        primaryDisplayPoints.last?.date
    }

    /// Number of dated rows an export would contain across every visible series.
    var exportRowCount: Int {
        var dates = Set<Date>()
        for line in displayedSeries {
            for point in line.points {
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
        hasLoadedHistory && primaryDisplayPoints.isEmpty
    }

    var emptyWindowMessage: String {
        let coverage = mainSeries.formattedDateRange
        return "\(mainSeries.id) has no observations in the \(rangeLabel) window. Published coverage is \(coverage)."
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
        ValueFormatter(units: displayUnits, representsDifference: chartMode == .spread)
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

        await loadRecessionsIfNeeded()
        guard token == loadToken else { return }

        rebuildDerivedState()
    }

    /// Fetches the recession indicator once, only while shading is switched on.
    private func loadRecessionsIfNeeded() async {
        guard showsRecessionShading, recessionSource.isEmpty else { return }

        recessionSource = await recessionLoader()
        if recessionSource.isEmpty {
            AppLogger.detail.info("Recession indicator unavailable; chart shading is omitted")
        }
    }

    /// Loads the series' category, release, tag, and sibling context.
    ///
    /// Deliberately lazy — it costs four requests, which is not worth spending for a
    /// reader who never opens the Insights tab.
    func loadRelationsIfNeeded() async {
        guard relations == nil, !isLoadingRelations else { return }

        isLoadingRelations = true
        defer { isLoadingRelations = false }

        let seriesId = mainSeries.id
        let loaded = await relationsLoader(seriesId)

        // The primary series can change only by opening a different detail view, but
        // guard anyway rather than attaching another series' context.
        guard seriesId == mainSeries.id else { return }
        relations = loaded
    }

    /// Related series that are not already on the chart, most chartable first.
    var suggestedRelatedSeries: [FREDSeries] {
        guard let relations else { return [] }

        let present = Set(allSeries.map(\.id))
        return relations
            .relatedSeriesRanked(comparableWith: mainSeries)
            .filter { !present.contains($0.id) }
    }

    func setRecessionShading(_ enabled: Bool) async {
        guard showsRecessionShading != enabled else { return }
        showsRecessionShading = enabled

        await loadRecessionsIfNeeded()
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
        updateWindow(.preset(range))
    }

    func updateWindow(_ newWindow: DateWindow) {
        guard window != newWindow else { return }
        window = newWindow
        rebuildDerivedState()
    }

    /// Applies an explicit interval, ordered and clamped to the loaded coverage.
    func applyCustomWindow(start: Date, end: Date) {
        updateWindow(.custom(start: start, end: end, clampedTo: availableDateRange))
    }

    func updateTransform(_ newTransform: SeriesTransform) {
        // Recorded before the early exit: re-picking the current transform is still an
        // explicit choice, and the app must stop overriding it when a series is added.
        transformChosenByUser = true

        guard transform != newTransform else { return }
        transform = newTransform
        rebuildDerivedState()
    }

    /// Chooses which comparison series the scatter is fitted against.
    func selectRegressionPartner(id seriesId: String) {
        guard comparisonSeries.contains(where: { $0.id == seriesId }) else { return }
        guard regressionPartnerID != seriesId else { return }

        regressionPartnerID = seriesId
        rebuildRelationship()
    }

    /// The comparison series currently on the scatter's x-axis.
    var regressionPartner: FREDSeries? {
        guard let regressionPartnerID else { return comparisonSeries.first }
        return comparisonSeries.first { $0.id == regressionPartnerID } ?? comparisonSeries.first
    }

    /// Units label for each scatter axis. Each series keeps its own units, because the
    /// interesting scatters are exactly the ones whose series are not unit-comparable.
    var scatterYUnitsLabel: String {
        Self.axisUnitsLabel(for: mainSeries, transform: transform)
    }

    var scatterXUnitsLabel: String {
        guard let partner = regressionPartner else { return "Value" }
        return Self.axisUnitsLabel(for: partner, transform: transform)
    }

    private static func axisUnitsLabel(for series: FREDSeries, transform: SeriesTransform) -> String {
        let units = transform.resultUnits(baseUnits: series.units)
        let label = UnitDescriptor.cached(units: units).presentationUnits
        return label.isEmpty ? "Value" : label
    }

    func updateChartMode(_ mode: ChartMode) {
        guard chartMode != mode else { return }
        guard mode == .overlay || canUseSpreadMode else { return }

        chartMode = mode
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

        // Exports mirror the chart, so spread mode exports the spreads rather than the
        // series they were derived from.
        guard chartMode == .overlay else {
            return ExportPayload(
                rangeLabel: rangeLabel,
                transform: transform,
                columns: displayedSeries.map { line in
                    ExportPayload.SeriesColumn(
                        id: line.id,
                        title: line.title,
                        units: displayUnitsLabel,
                        frequency: mainSeries.frequency,
                        seasonalAdjustment: mainSeries.seasonalAdjustment,
                        points: line.points
                    )
                }
            )
        }

        return ExportPayload(
            rangeLabel: rangeLabel,
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

        let name = "\(mainSeries.id)-\(rangeLabel)-\(transform.shortLabel)"
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

        let bounds = window.bounds(anchoredTo: anchorDate, calendar: calendar)

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
            var window = SeriesAnalytics.filter(transformed, from: bounds.start, through: bounds.end)

            // Indexing is relative to what the reader can see, so it happens after windowing.
            if transform == .indexed {
                window = SeriesAnalytics.rebasedToOneHundred(window)
            }

            newWindowed[entry.id] = window
        }

        windowedSeries = newWindowed
        rebuildDisplayedSeries()
        visibleObservationCount = primaryDisplayPoints.count

        rebuildChartPoints()
        rebuildStatisticsAndInsights()
        rebuildComparisonSummaries()
        rebuildUnitsNotice(sharedScale: sharedScale)
        rebuildRecessionIntervals()
        rebuildRelationship()
    }

    /// Builds the scatter and its fit for the primary series against the selected
    /// comparison series.
    ///
    /// Uses the windowed source series rather than the displayed lines: in spread mode the
    /// displayed line is already a difference, and regressing a series on a difference of
    /// itself would be circular.
    private func rebuildRelationship() {
        if let regressionPartnerID, !comparisonSeries.contains(where: { $0.id == regressionPartnerID }) {
            self.regressionPartnerID = nil
        }

        guard let partner = regressionPartner,
              let base = windowedSeries[mainSeries.id], !base.isEmpty,
              let other = windowedSeries[partner.id], !other.isEmpty else {
            scatterPoints = []
            regression = nil
            return
        }

        let aligned = SeriesAnalytics.alignedObservations(base, other)
        scatterPoints = aligned.map { ScatterPoint(date: $0.date, x: $0.rhs, y: $0.lhs) }
        regression = SeriesAnalytics.linearRegression(aligned)
    }

    /// Clips the recession bands to the plotted date span so Swift Charts is never asked
    /// to draw a rectangle that would stretch the x-axis beyond the data.
    private func rebuildRecessionIntervals() {
        guard showsRecessionShading, !recessionSource.isEmpty else {
            recessionIntervals = []
            return
        }

        let dates = displayedSeries.flatMap { [$0.points.first?.date, $0.points.last?.date] }.compactMap { $0 }
        guard let earliest = dates.min(), let latest = dates.max(), latest > earliest else {
            recessionIntervals = []
            return
        }

        recessionIntervals = SeriesAnalytics.clip(
            SeriesAnalytics.recessionIntervals(from: recessionSource),
            to: DateInterval(start: earliest, end: latest)
        )
    }

    /// Resolves the windowed source series into the lines that are actually drawn.
    ///
    /// Spread mode falls back to overlay if it stops being available — for instance when
    /// the comparison series it was differencing against is removed.
    private func rebuildDisplayedSeries() {
        if chartMode == .spread, !canUseSpreadMode {
            chartMode = .overlay
        }

        switch chartMode {
        case .overlay:
            displayedSeries = allSeries.map { series in
                DisplayedSeries(id: series.id, title: series.title, points: windowedSeries[series.id] ?? [])
            }

        case .spread:
            let base = windowedSeries[mainSeries.id] ?? []
            displayedSeries = comparisonSeries.map { other in
                DisplayedSeries(
                    id: "\(mainSeries.id)-\(other.id)",
                    title: "\(mainSeries.id) − \(other.id)",
                    points: SeriesAnalytics.spread(base, minus: windowedSeries[other.id] ?? [])
                )
            }
        }
    }

    private func rebuildChartPoints() {
        var points: [ChartDataPoint] = []
        var downsampled = false

        for line in displayedSeries {
            guard !line.points.isEmpty else { continue }

            let display = SeriesAnalytics.downsample(line.points, threshold: chartPointBudget)
            if display.count < line.points.count { downsampled = true }

            points.reserveCapacity(points.count + display.count)
            for point in display {
                points.append(
                    ChartDataPoint(seriesId: line.id, seriesTitle: line.title, date: point.date, value: point.value)
                )
            }
        }

        // Averaged at full resolution, then downsampled for drawing, so smoothing is
        // never applied to already-thinned data.
        if let window = movingAverage.window(for: mainSeries.seriesFrequency),
           let primary = displayedSeries.first, primary.points.count >= window {
            let averaged = SeriesAnalytics.movingAverage(primary.points, window: window)
            let display = SeriesAnalytics.downsample(averaged, threshold: chartPointBudget)

            for point in display {
                points.append(
                    ChartDataPoint(
                        seriesId: primary.id,
                        seriesTitle: primary.title,
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
        statistics = SeriesStatistics.make(points: primaryDisplayPoints, units: displayUnits)
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
        if transform == .level, chartMode == .overlay {
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
        guard chartMode == .overlay, canCompare,
              let mainWindow = windowedSeries[mainSeries.id], !mainWindow.isEmpty else {
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
        displayedSeries.compactMap { line in
            guard let index = Self.nearestIndex(in: line.points, to: date) else { return nil }

            let point = line.points[index]
            return ChartDataPoint(
                seriesId: line.id,
                seriesTitle: line.title,
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
        let window = primaryDisplayPoints
        guard !window.isEmpty else { return [] }

        let formatter = valueFormatter
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
