import Charts
import SwiftUI

struct SeriesDetailView: View {
    @StateObject private var viewModel: SeriesDetailViewModel
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var commandCenter = AppCommandCenter.shared

    @State private var selectedTab = DetailTab.overview
    @State private var showingAddSeriesSheet = false
    @State private var selectedDate: Date?
    @State private var exportNotice: ExportNotice?
    @State private var tableSortOrder = SeriesDetailView.defaultTableSortOrder

    /// Newest first, matching how the view model already builds its rows.
    static let defaultTableSortOrder = [KeyPathComparator(\ObservationRow.date, order: .reverse)]

    /// Identifies this view instance when registering menu-command handlers.
    private let commandToken = UUID().uuidString

    init(series: FREDSeries) {
        _viewModel = StateObject(wrappedValue: SeriesDetailViewModel(series: series))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            content
        }
        .navigationTitle(viewModel.mainSeries.title)
        .navigationSubtitle(viewModel.mainSeries.id)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingAddSeriesSheet) {
            AddSeriesView(existingSeriesIDs: Set(viewModel.allSeries.map(\.id))) { series in
                showingAddSeriesSheet = false
                Task { await viewModel.addSeries(series) }
            }
        }
        .task {
            await viewModel.setRecessionShading(settings.showsRecessionShading)
            await viewModel.loadData()
        }
        .onAppear {
            commandCenter.register(
                token: commandToken,
                handlers: AppCommandCenter.Handlers(
                    refresh: { Task { await viewModel.refreshData() } },
                    exportCSV: { export(.csv) },
                    exportJSON: { export(.json) },
                    copyToClipboard: copyToClipboard,
                    selectTab: { index in
                        let tabs = DetailTab.allCases
                        guard tabs.indices.contains(index) else { return }
                        selectedTab = tabs[index]
                    }
                )
            )
        }
        .onDisappear {
            commandCenter.unregister(token: commandToken)
        }
        .alert(item: $exportNotice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading, !viewModel.hasLoadedHistory {
            loadingView
        } else if let errorMessage = viewModel.errorMessage, !viewModel.hasLoadedHistory {
            errorView(message: errorMessage)
        } else {
            VStack(spacing: 0) {
                Picker("View", selection: $selectedTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .padding(.horizontal)
                .padding(.top, 12)
                .accessibilityIdentifier("detail.tabPicker")

                switch selectedTab {
                case .overview: overviewTab
                case .data: dataTab
                case .insights: insightsTab
                }
            }
        }
    }

    // MARK: Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(viewModel.mainSeries.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 12) {
                    HeaderBadge(symbol: "ruler", label: viewModel.mainSeries.units.isEmpty ? "Units n/a" : viewModel.mainSeries.units)
                    HeaderBadge(symbol: "calendar", label: viewModel.mainSeries.frequency)
                    HeaderBadge(symbol: "waveform", label: viewModel.mainSeries.seasonalAdjustment)
                }

                Spacer(minLength: 0)
            }

            Text(viewModel.mainSeries.title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)

            controlsView

            if hasNotices {
                noticesView
            }

            if let statistics = viewModel.statistics {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    MetricTile(
                        title: "Latest",
                        value: statistics.formattedLatestValue,
                        detail: latestObservationCaption,
                        symbol: "sparkline"
                    )
                    MetricTile(
                        title: "Latest Change",
                        value: statistics.formattedLatestChange,
                        detail: statistics.formattedPercentChange,
                        symbol: (statistics.latestChange ?? 0) >= 0 ? "arrow.up.right" : "arrow.down.right"
                    )
                    MetricTile(
                        title: "Period Change",
                        value: statistics.formattedTotalChange,
                        detail: "Across \(statistics.formattedSpan)",
                        symbol: "arrow.left.and.right"
                    )
                    MetricTile(
                        title: viewModel.transform == .level ? "Annualized Drift" : "Window Mean",
                        value: viewModel.transform == .level ? statistics.formattedAnnualizedChange : statistics.formattedMean,
                        detail: annualizedDriftCaption(statistics),
                        symbol: viewModel.transform == .level ? "gauge.with.needle" : "divide"
                    )
                }
            }
        }
        .padding(20)
        .background(.quaternary.opacity(0.28))
    }

    /// One compact row. `.menu` pickers show the selected value, which reads clearly on
    /// its own ("All Time", "% Change"), so the labels are hidden and restated as help.
    private var controlsView: some View {
        HStack(spacing: 10) {
            Picker("Date Range", selection: Binding(
                get: { viewModel.selectedRange },
                set: { viewModel.updateRange($0) }
            )) {
                ForEach(DateRangeOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Time window, measured back from this series' latest observation")
            .accessibilityLabel("Date range")
            .accessibilityIdentifier("detail.rangePicker")

            Picker("Transform", selection: Binding(
                get: { viewModel.transform },
                set: { viewModel.updateTransform($0) }
            )) {
                ForEach(SeriesTransform.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("How each series is transformed before charting")
            .accessibilityLabel("Transform")
            .accessibilityIdentifier("detail.transformPicker")

            Picker("Trend Line", selection: Binding(
                get: { viewModel.movingAverage },
                set: { viewModel.updateMovingAverage($0) }
            )) {
                ForEach(MovingAverageOption.allCases) { option in
                    Text(option == .off ? "No Trend Line" : "\(option.rawValue) Average").tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help(viewModel.movingAverage == .off
                  ? "Overlay a moving average on the primary series"
                  : viewModel.movingAverageLabel)
            .accessibilityLabel("Trend line")
            .accessibilityIdentifier("detail.trendPicker")

            Toggle("Recessions", isOn: Binding(
                get: { viewModel.showsRecessionShading },
                set: { enabled in
                    settings.setRecessionShading(enabled)
                    Task { await viewModel.setRecessionShading(enabled) }
                }
            ))
            .toggleStyle(.checkbox)
            .help("Shade U.S. recession periods as dated by the NBER")
            .accessibilityIdentifier("detail.recessionToggle")

            Spacer(minLength: 0)

            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .help("Loading observations")
            }
        }
    }

    private var hasNotices: Bool {
        viewModel.unitsNotice != nil || !viewModel.warnings.isEmpty || viewModel.isChartDownsampled
    }

    @ViewBuilder
    private var noticesView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let unitsNotice = viewModel.unitsNotice {
                NoticeLabel(text: unitsNotice, symbol: "info.circle", tint: .secondary)
            }

            ForEach(viewModel.warnings, id: \.self) { warning in
                NoticeLabel(text: "Comparison series failed to load — \(warning)", symbol: "exclamationmark.triangle", tint: .orange)
            }

            if viewModel.isChartDownsampled {
                NoticeLabel(
                    text: "The chart draws a representative sample of \(viewModel.visibleObservationCount) observations. The Data tab and exports contain every row.",
                    symbol: "chart.dots.scatter",
                    tint: .secondary
                )
            }
        }
    }

    private func annualizedDriftCaption(_ statistics: SeriesStatistics) -> String {
        guard viewModel.transform == .level else { return "Average of visible values" }
        guard statistics.annualizedChange != nil else {
            return "Needs 6+ months of positive values"
        }
        return "Compound annual growth"
    }

    private var latestObservationCaption: String {
        guard let latest = viewModel.latestVisibleDate else { return "Current reading" }
        return "As of \(FREDDate.displayString(from: latest))"
    }

    // MARK: Overview

    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SeriesChartView(viewModel: viewModel, selectedDate: $selectedDate)

                if !viewModel.comparisonSummaries.isEmpty {
                    GroupBox("Relationship to \(viewModel.mainSeries.id)") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.comparisonSummaries) { summary in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(summary.seriesTitle)
                                            .font(.headline)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("r = \(summary.formattedCorrelation)")
                                            .font(.headline.monospacedDigit())
                                    }
                                    Text(summary.interpretation)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                }

                if viewModel.canCompare {
                    visibleSeriesSection
                }
            }
            .padding(20)
        }
    }

    private var visibleSeriesSection: some View {
        GroupBox("Visible Series") {
            VStack(alignment: .leading, spacing: 10) {
                Text(viewModel.seriesCountLabel)
                    .font(.subheadline.weight(.semibold))

                ForEach(viewModel.allSeries) { series in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(series.title)
                                .font(.headline)
                                .lineLimit(2)
                            Text("\(series.id) • \(series.units.isEmpty ? "Units n/a" : series.units)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        if series.id != viewModel.mainSeries.id {
                            Button(role: .destructive) {
                                viewModel.removeSeries(id: series.id)
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove \(series.id) from this chart")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: Data

    /// Rows in the requested order.
    ///
    /// The view model already returns newest-first, so the default order costs nothing;
    /// only an explicitly changed sort pays to reorder, and a long daily series is tens
    /// of thousands of rows.
    private var sortedTableRows: [ObservationRow] {
        let rows = viewModel.tableRows
        guard tableSortOrder != Self.defaultTableSortOrder else { return rows }
        return rows.sorted(using: tableSortOrder)
    }

    @ViewBuilder
    private var dataTab: some View {
        let rows = sortedTableRows

        if rows.isEmpty {
            ContentUnavailableView(
                "No Data",
                systemImage: "tablecells",
                description: Text(viewModel.isWindowEmpty ? viewModel.emptyWindowMessage : "Load a series to inspect its observations.")
            )
        } else {
            VStack(spacing: 0) {
                Table(rows, sortOrder: $tableSortOrder) {
                    TableColumn("Date", value: \.date) { row in
                        Text(row.formattedDate)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 130, ideal: 150)

                    TableColumn(viewModel.publishedUnitsLabel, value: \.value) { row in
                        HStack {
                            Spacer()
                            Text(row.formattedValue)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("Change", value: \.sortableChange) { row in
                        HStack {
                            Spacer()
                            Text(row.formattedChange)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(changeColor(for: row.changeFromPrevious))
                        }
                    }
                    .width(min: 120, ideal: 160)
                }
                .accessibilityIdentifier("detail.table")

                Divider()

                HStack {
                    Text("\(rows.count) observations • \(viewModel.selectedRange.rawValue) • \(viewModel.transform.rawValue) • values as published in \(viewModel.publishedUnitsLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        copyToClipboard()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private func changeColor(for change: Double?) -> Color {
        guard let change, change != 0 else { return .secondary }
        return change > 0 ? .green : .red
    }

    // MARK: Insights

    private var insightsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let statistics = viewModel.statistics {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                        InsightStatCard(title: "Observations", value: "\(statistics.count)", detail: "Rows in current window", symbol: "number")
                        InsightStatCard(title: "Mean", value: statistics.formattedMean, detail: "Average visible value", symbol: "divide")
                        InsightStatCard(title: "Median", value: statistics.formattedMedian, detail: "Middle observation", symbol: "equal")
                        InsightStatCard(title: "Range", value: statistics.formattedRange, detail: "\(statistics.formattedMin) to \(statistics.formattedMax)", symbol: "arrow.up.and.down")
                        InsightStatCard(title: "Std Dev", value: statistics.formattedStdDev, detail: "Dispersion of visible values", symbol: "waveform.path.ecg")
                        InsightStatCard(title: "Window", value: statistics.formattedSpan, detail: viewModel.selectedRange.rawValue, symbol: "calendar")
                    }
                } else {
                    ContentUnavailableView(
                        "No Statistics",
                        systemImage: "chart.bar",
                        description: Text("There are no observations in the selected window.")
                    )
                }

                if !viewModel.insights.isEmpty {
                    GroupBox("Insight Cards") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(viewModel.insights.enumerated()), id: \.element.id) { index, insight in
                                if index > 0 { Divider() }

                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: insight.symbol)
                                        .foregroundStyle(.blue)
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(insight.title).font(.headline)
                                            Spacer()
                                            Text(insight.value).font(.headline.monospacedDigit())
                                        }

                                        Text(insight.detail)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.vertical, 10)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                GroupBox("Series Metadata") {
                    VStack(alignment: .leading, spacing: 10) {
                        InfoRow(label: "Series ID", value: viewModel.mainSeries.id)
                        InfoRow(label: "Source Units", value: viewModel.mainSeries.units.isEmpty ? "Not published" : viewModel.mainSeries.units)
                        InfoRow(label: "Chart Units", value: viewModel.displayUnitsLabel)
                        InfoRow(label: "Table & Export Units", value: viewModel.publishedUnitsLabel)
                        InfoRow(label: "Frequency", value: viewModel.mainSeries.frequency)
                        InfoRow(label: "Seasonal Adjustment", value: viewModel.mainSeries.seasonalAdjustment)
                        InfoRow(label: "Coverage", value: viewModel.mainSeries.formattedDateRange)
                        InfoRow(label: "Last Updated", value: viewModel.mainSeries.lastUpdated.isEmpty ? "Not published" : viewModel.mainSeries.lastUpdated)

                        if let notes = viewModel.mainSeries.notes, !notes.isEmpty {
                            Divider()
                            Text("Notes")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(notes)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding(20)
        }
    }

    // MARK: States

    private func errorView(message: String) -> some View {
        ContentUnavailableView {
            Label("Unable to Load Series", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await viewModel.refreshData() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Loading observations…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                settings.toggleFavorite(viewModel.mainSeries)
            } label: {
                Label(
                    settings.isFavorite(viewModel.mainSeries.id) ? "Remove Favorite" : "Add Favorite",
                    systemImage: settings.isFavorite(viewModel.mainSeries.id) ? "star.fill" : "star"
                )
            }
            .help(settings.isFavorite(viewModel.mainSeries.id) ? "Remove this series from favorites" : "Save this series to favorites")
            .accessibilityIdentifier("detail.favorite")

            Button {
                showingAddSeriesSheet = true
            } label: {
                Label("Compare Series", systemImage: "plus.circle")
            }
            .help("Add another FRED series to this chart")
            .accessibilityIdentifier("detail.compare")

            Menu {
                Button("Export CSV…") { export(.csv) }
                Button("Export JSON…") { export(.json) }
                Divider()
                Button("Copy to Clipboard") { copyToClipboard() }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(viewModel.visibleObservationCount == 0)
            .help("Export or copy the visible observations")
            .accessibilityIdentifier("detail.share")

            Button {
                Task { await viewModel.refreshData() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isLoading)
            .help("Re-download this series from FRED")
            .accessibilityIdentifier("detail.refresh")
        }
    }

    // MARK: Actions

    private func export(_ format: ExportFormat) {
        Task {
            switch await viewModel.export(format: format) {
            case .saved(let url):
                exportNotice = ExportNotice(
                    title: "Export Saved",
                    message: "Saved \(viewModel.exportRowCount) rows to \(url.lastPathComponent)."
                )
            case .cancelled:
                break
            case .failed(let message):
                exportNotice = ExportNotice(title: "Export Failed", message: message)
            }
        }
    }

    private func copyToClipboard() {
        let rows = viewModel.copyToClipboard()
        exportNotice = ExportNotice(
            title: "Copied",
            message: "\(rows) rows copied to the clipboard as tab-separated text."
        )
    }
}

// MARK: - Supporting Types

private enum DetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case data = "Data"
    case insights = "Insights"

    var id: String { rawValue }
}

#Preview {
    let sampleSeries = FREDSeries(
        id: "GDP",
        title: "Gross Domestic Product",
        observationStart: "1947-01-01",
        observationEnd: "2026-04-01",
        frequency: "Quarterly",
        frequencyShort: "Q",
        units: "Billions of Dollars",
        unitsShort: "Bil. of $",
        seasonalAdjustment: "Seasonally Adjusted Annual Rate",
        seasonalAdjustmentShort: "SAAR",
        lastUpdated: "2026-08-26 07:49:01-05",
        popularity: 92,
        notes: nil
    )

    return NavigationStack {
        SeriesDetailView(series: sampleSeries)
    }
}
