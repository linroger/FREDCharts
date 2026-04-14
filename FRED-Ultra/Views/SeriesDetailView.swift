import Charts
import SwiftUI

struct SeriesDetailView: View {
    @StateObject private var viewModel: SeriesDetailViewModel
    @ObservedObject private var settings = SettingsManager.shared
    @State private var showingAddSeriesSheet = false
    @State private var selectedTab = DetailTab.overview

    init(series: FREDSeries) {
        _viewModel = StateObject(wrappedValue: SeriesDetailViewModel(series: series))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if viewModel.isLoading && viewModel.displayDataPoints.isEmpty {
                loadingView
            } else if let errorMessage = viewModel.errorMessage, viewModel.displayDataPoints.isEmpty {
                errorView(message: errorMessage)
            } else {
                Picker("", selection: $selectedTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 12)
                .frame(maxWidth: 360)

                Group {
                    switch selectedTab {
                    case .overview:
                        overviewTab
                    case .data:
                        dataTab
                    case .insights:
                        insightsTab
                    }
                }
            }
        }
        .navigationTitle(viewModel.mainSeries.title)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingAddSeriesSheet) {
            AddSeriesView(selectedSeriesIDs: Set(viewModel.allSeries.map(\.id))) { series in
                viewModel.addSeries(series)
                showingAddSeriesSheet = false
            }
        }
        .task {
            await viewModel.loadData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshData)) { _ in
            Task { await viewModel.refreshData() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportCSV)) { _ in
            viewModel.exportData(format: .csv)
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportJSON)) { _ in
            viewModel.exportData(format: .json)
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil && !viewModel.displayDataPoints.isEmpty },
            set: { _ in viewModel.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.mainSeries.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Text(viewModel.mainSeries.title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))

                    HStack(spacing: 12) {
                        HeaderBadge(symbol: "ruler", label: viewModel.mainSeries.units)
                        HeaderBadge(symbol: "calendar", label: viewModel.mainSeries.frequency)
                        HeaderBadge(symbol: "waveform", label: viewModel.mainSeries.seasonalAdjustment)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 10) {
                    Picker("Date Range", selection: Binding(
                        get: { viewModel.selectedDateRange },
                        set: { viewModel.updateDateRange($0) }
                    )) {
                        ForEach(DateRangeOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.menu)

                    if viewModel.canNormalize {
                        Toggle("Comparison Mode", isOn: Binding(
                            get: { viewModel.isNormalized },
                            set: { viewModel.setNormalization($0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
            }

            if let unitsInfo = viewModel.unitsInfo {
                Label(unitsInfo, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let statistics = viewModel.statistics {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    MetricTile(title: "Latest", value: statistics.formattedLatestValue, detail: "Current reading", symbol: "sparkline")
                    MetricTile(title: "Latest Change", value: statistics.formattedLatestChange, detail: statistics.formattedPercentChange, symbol: statistics.latestChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                    MetricTile(title: "Period Change", value: statistics.formattedTotalChange, detail: "Across selected range", symbol: "arrow.left.and.right")
                    MetricTile(title: "Annualized Drift", value: statistics.formattedAnnualizedChange, detail: "Compound annualized change", symbol: "gauge.with.needle")
                }
            }
        }
        .padding(20)
        .background(.quaternary.opacity(0.28))
    }

    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                chartSection

                GroupBox("Visible Series") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(viewModel.seriesCountLabel)
                            .font(.subheadline.weight(.semibold))
                        ForEach(viewModel.allSeries) { series in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(series.title)
                                        .font(.headline)
                                    Text("\(series.id) • \(series.units)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if series.id != viewModel.mainSeries.id {
                                    Button(role: .destructive) {
                                        viewModel.removeSeries(series)
                                    } label: {
                                        Label("Remove", systemImage: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding(20)
        }
    }

    private var chartSection: some View {
        GroupBox(viewModel.chartSectionTitle) {
            VStack(alignment: .leading, spacing: 14) {
                if viewModel.displayDataPoints.isEmpty {
                    ContentUnavailableView("No Data", systemImage: "chart.xyaxis.line", description: Text("There are no observations in the selected range."))
                } else {
                    Chart {
                        ForEach(viewModel.displayDataPoints) { point in
                            LineMark(
                                x: .value("Date", point.date),
                                y: .value("Value", point.value)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(by: .value("Series", point.seriesTitle))

                            if viewModel.allSeries.count == 1 {
                                AreaMark(
                                    x: .value("Date", point.date),
                                    y: .value("Value", point.value)
                                )
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(.blue.opacity(0.12))
                            }
                        }

                        if let selectedObservation = viewModel.selectedObservation {
                            RuleMark(x: .value("Selected Date", selectedObservation.date))
                                .foregroundStyle(.secondary.opacity(0.45))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                            PointMark(
                                x: .value("Selected Date", selectedObservation.date),
                                y: .value("Selected Value", selectedObservation.value)
                            )
                            .symbolSize(120)
                            .foregroundStyle(.primary)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.year().month(.abbreviated))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let value = value.as(Double.self) {
                                    Text(viewModel.valueFormatter.formatAxisValue(value))
                                }
                            }
                        }
                    }
                    .chartLegend(position: .bottom, spacing: 16)
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { dragValue in
                                            guard let plotFrame = proxy.plotFrame else { return }
                                            let origin = geometry[plotFrame].origin
                                            let currentX = dragValue.location.x - origin.x

                                            guard let date: Date = proxy.value(atX: currentX) else { return }

                                            viewModel.selectedObservation = viewModel.displayDataPoints.min(
                                                by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                                            )
                                        }
                                        .onEnded { _ in
                                            viewModel.selectedObservation = nil
                                        }
                                )
                        }
                    }
                    .frame(minHeight: 360)

                    if let selectedObservation = viewModel.selectedObservation {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedObservation.seriesTitle)
                                    .font(.headline)
                                Text(selectedObservation.date, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(viewModel.valueFormatter.formatValue(selectedObservation.value, compact: false))
                                .font(.title3.weight(.semibold))
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var dataTab: some View {
        Group {
            if viewModel.tableRows.isEmpty {
                ContentUnavailableView("No Data", systemImage: "tablecells", description: Text("Load a series to inspect raw observations."))
            } else {
                Table(viewModel.tableRows) {
                    TableColumn("Date") { row in
                        Text(row.formattedDate)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 120, ideal: 140)

                    TableColumn("Value") { row in
                        HStack {
                            Spacer()
                            Text(row.formattedValue)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .width(min: 180, ideal: 220)
                }
                .padding()
            }
        }
    }

    private var insightsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let statistics = viewModel.statistics {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                        InsightStatCard(title: "Observations", value: "\(statistics.count)", detail: "Rows in current range", symbol: "number")
                        InsightStatCard(title: "Mean", value: statistics.formattedMean, detail: "Average visible value", symbol: "divide")
                        InsightStatCard(title: "Median", value: statistics.formattedMedian, detail: "Middle observation", symbol: "equal")
                        InsightStatCard(title: "Range", value: statistics.formattedRange, detail: "\(statistics.formattedMin) to \(statistics.formattedMax)", symbol: "arrow.up.and.down")
                        InsightStatCard(title: "Std Dev", value: statistics.formattedStdDev, detail: "Observation volatility", symbol: "waveform.path.ecg")
                    }
                }

                GroupBox("Insight Cards") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(viewModel.insights) { insight in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: insight.symbol)
                                    .foregroundStyle(.blue)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(insight.title)
                                            .font(.headline)
                                        Spacer()
                                        Text(insight.value)
                                            .font(.headline)
                                    }

                                    Text(insight.detail)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)

                            if insight.id != viewModel.insights.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Series Metadata") {
                    VStack(alignment: .leading, spacing: 10) {
                        InfoRow(label: "Series ID", value: viewModel.mainSeries.id)
                        InfoRow(label: "Units", value: viewModel.mainSeries.units)
                        InfoRow(label: "Frequency", value: viewModel.mainSeries.frequency)
                        InfoRow(label: "Seasonal Adjustment", value: viewModel.mainSeries.seasonalAdjustment)
                        InfoRow(label: "Coverage", value: viewModel.mainSeries.formattedDateRange)
                        InfoRow(label: "Last Updated", value: viewModel.mainSeries.lastUpdated)

                        if let notes = viewModel.mainSeries.notes, !notes.isEmpty {
                            Divider()
                            Text("Notes")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(notes)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding(20)
        }
    }

    private func errorView(message: String) -> some View {
        ContentUnavailableView {
            Label("Unable to Load Series", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await viewModel.loadData() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Loading observations…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: toggleFavorite) {
                Label(
                    settings.isFavorite(viewModel.mainSeries) ? "Remove Favorite" : "Add Favorite",
                    systemImage: settings.isFavorite(viewModel.mainSeries) ? "star.fill" : "star"
                )
            }

            Button {
                showingAddSeriesSheet = true
            } label: {
                Label("Compare Series", systemImage: "plus.circle")
            }

            Menu {
                Button("Export CSV") {
                    viewModel.exportData(format: .csv)
                }
                Button("Export JSON") {
                    viewModel.exportData(format: .json)
                }
                Divider()
                Button("Copy to Clipboard") {
                    viewModel.copyToClipboard()
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Button {
                Task { await viewModel.refreshData() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isLoading)
        }
    }

    private func toggleFavorite() {
        if settings.isFavorite(viewModel.mainSeries) {
            settings.removeFavorite(viewModel.mainSeries)
        } else {
            settings.addFavorite(viewModel.mainSeries)
        }
    }
}

// MARK: - Supporting Views

private enum DetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case data = "Data"
    case insights = "Insights"

    var id: String { rawValue }
}

private struct HeaderBadge: View {
    let symbol: String
    let label: String

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.title3.weight(.bold))

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct InsightStatCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct AddSeriesView: View {
    @StateObject private var searchViewModel = SearchViewModel()
    @Environment(\.dismiss) private var dismiss
    let selectedSeriesIDs: Set<String>
    let onSelect: (FREDSeries) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if searchViewModel.isLoading {
                    VStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let errorMessage = searchViewModel.errorMessage {
                    ContentUnavailableView {
                        Label("Search Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    }
                } else if searchViewModel.results.isEmpty, searchViewModel.hasSearched {
                    ContentUnavailableView.search(text: searchViewModel.query)
                } else if searchViewModel.results.isEmpty {
                    ContentUnavailableView("Search for a Series", systemImage: "magnifyingglass", description: Text("Find another FRED series to compare in the chart."))
                } else {
                    List(searchViewModel.results) { series in
                        Button {
                            onSelect(series)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(series.title)
                                        .font(.headline)
                                        .lineLimit(2)

                                    Spacer()

                                    if selectedSeriesIDs.contains(series.id) {
                                        Text("Added")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Text("\(series.id) • \(series.units)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedSeriesIDs.contains(series.id))
                    }
                }
            }
            .searchable(text: $searchViewModel.query, prompt: "Search economic data")
            .navigationTitle("Compare Series")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 540)
    }
}

#Preview {
    let sampleSeries = FREDSeries(
        id: "GDP",
        title: "Gross Domestic Product",
        observationStart: "1947-01-01",
        observationEnd: "2024-01-01",
        frequency: "Quarterly",
        frequencyShort: "Q",
        units: "Billions of Dollars",
        unitsShort: "Bil. of $",
        seasonalAdjustment: "Seasonally Adjusted Annual Rate",
        seasonalAdjustmentShort: "SAAR",
        lastUpdated: "2024-01-01 07:00:00-06",
        popularity: 100,
        notes: nil
    )

    NavigationStack {
        SeriesDetailView(series: sampleSeries)
    }
}
