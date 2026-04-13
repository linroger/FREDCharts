import SwiftUI
import Charts

struct SeriesDetailView: View {
    @StateObject var viewModel: SeriesDetailViewModel
    @State private var showingAddSeriesSheet = false
    @State private var selectedTab = 0
    @ObservedObject private var settings = SettingsManager.shared

    init(series: FREDSeries) {
        _viewModel = StateObject(wrappedValue: SeriesDetailViewModel(series: series))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with series info and controls
            headerView
            
            Divider()
            
            if viewModel.isLoading && viewModel.seriesData.isEmpty {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else {
                // Tab picker
                Picker("", selection: $selectedTab) {
                    Text("Chart").tag(0)
                    Text("Data").tag(1)
                    Text("Statistics").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxWidth: 300)

                // Content based on selected tab
                Group {
                    switch selectedTab {
                    case 0:
                        chartView
                    case 1:
                        tableView
                    case 2:
                        statisticsView
                    default:
                        chartView
                    }
                }
            }
        }
        .navigationTitle(viewModel.mainSeries.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Favorite button
                Button(action: toggleFavorite) {
                    Label(
                        settings.isFavorite(viewModel.mainSeries) ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: settings.isFavorite(viewModel.mainSeries) ? "star.fill" : "star"
                    )
                }
                .help(settings.isFavorite(viewModel.mainSeries) ? "Remove from Favorites" : "Add to Favorites")
                
                // Add series button
                Button(action: { showingAddSeriesSheet = true }) {
                    Label("Compare Series", systemImage: "plus.circle")
                }
                .help("Add another series to compare")
                
                // Export menu
                Menu {
                    Button(action: { viewModel.exportData(format: .csv) }) {
                        Label("Export as CSV", systemImage: "doc.text")
                    }
                    Button(action: { viewModel.exportData(format: .json) }) {
                        Label("Export as JSON", systemImage: "doc.badge.gearshape")
                    }
                    Divider()
                    Button(action: { viewModel.copyToClipboard() }) {
                        Label("Copy to Clipboard", systemImage: "doc.on.clipboard")
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export data")
                
                // Refresh button
                Button(action: {
                    Task { await viewModel.refreshData() }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh data")
                .disabled(viewModel.isLoading)
            }
        }
        .sheet(isPresented: $showingAddSeriesSheet) {
            AddSeriesView { series in
                viewModel.addSeries(series)
                showingAddSeriesSheet = false
            }
        }
        .task {
            await viewModel.loadData()
        }
        .alert("Error", isPresented: Binding<Bool>(
            get: { viewModel.errorMessage != nil && !viewModel.seriesData.isEmpty },
            set: { _ in viewModel.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
    
    // MARK: - Header View
    
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.mainSeries.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    
                    HStack(spacing: 16) {
                        Label(viewModel.mainSeries.units, systemImage: "ruler")
                        Label(viewModel.mainSeries.frequency, systemImage: "calendar")
                        Label(viewModel.mainSeries.seasonalAdjustment, systemImage: "waveform")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // Date range picker
                Picker("Date Range", selection: $viewModel.selectedDateRange) {
                    ForEach(DateRangeOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: viewModel.selectedDateRange) { _, newValue in
                    viewModel.updateDateRange(newValue)
                }
            }
            
            // Units warning for multi-series
            if let warning = viewModel.unitsWarning {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(.vertical, 4)
            }
            
            // Latest value indicator
            if let stats = viewModel.statistics {
                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("Latest")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(stats.formattedLatestValue)
                            .font(.title2)
                            .fontWeight(.semibold)
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Change")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: stats.latestChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                            Text(stats.formattedLatestChange)
                            Text("(\(stats.formattedPercentChange))")
                        }
                        .font(.subheadline)
                        .foregroundStyle(stats.latestChange >= 0 ? .green : .red)
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading data...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Error View
    
    private func errorView(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Error Loading Data", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button("Try Again") {
                Task { await viewModel.loadData() }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Chart View
    
    @ViewBuilder
    var chartView: some View {
        VStack(spacing: 0) {
            if !viewModel.chartDataPoints.isEmpty {
                Chart {
                    ForEach(viewModel.chartDataPoints) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(by: .value("Series", point.seriesTitle))
                        .interpolationMethod(.catmullRom)
                    }
                    
                    // Area fill for single series
                    if viewModel.allSeries.count == 1 {
                        ForEach(viewModel.chartDataPoints) { point in
                            AreaMark(
                                x: .value("Date", point.date),
                                y: .value("Value", point.value)
                            )
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [.blue.opacity(0.3), .blue.opacity(0.05)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    
                    // Selection indicator
                    if let selected = viewModel.selectedObservation {
                        RuleMark(x: .value("Selected", selected.date))
                            .foregroundStyle(.gray.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                        
                        PointMark(
                            x: .value("Date", selected.date),
                            y: .value("Value", selected.value)
                        )
                        .foregroundStyle(.primary)
                        .symbolSize(100)
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
                            if let doubleValue = value.as(Double.self) {
                                Text(viewModel.valueFormatter.formatAxisValue(doubleValue))
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
                                    .onChanged { value in
                                        let x = value.location.x - geometry[proxy.plotFrame!].origin.x
                                        if let date: Date = proxy.value(atX: x) {
                                            // Find closest data point
                                            let closest = viewModel.chartDataPoints
                                                .filter { $0.seriesId == viewModel.mainSeries.id }
                                                .min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
                                            viewModel.selectedObservation = closest
                                        }
                                    }
                                    .onEnded { _ in
                                        viewModel.selectedObservation = nil
                                    }
                            )
                    }
                }
                .padding()
                .frame(minHeight: 300)
                
                // Selected value tooltip
                if let selected = viewModel.selectedObservation {
                    HStack {
                        Text(selected.date, style: .date)
                            .fontWeight(.medium)
                        Spacer()
                        Text(viewModel.valueFormatter.formatValue(selected.value, compact: false))
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                }
                
                Divider()
                
                // Series list
                seriesListView
            } else {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "chart.xyaxis.line",
                    description: Text("No data available for this series in the selected date range.")
                )
            }
        }
    }
    
    // MARK: - Series List
    
    private var seriesListView: some View {
        List {
            Section(header: Text("Series (\(viewModel.allSeries.count))")) {
                ForEach(viewModel.allSeries) { series in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(series.title)
                                .font(.headline)
                                .lineLimit(2)
                            HStack {
                                Text(series.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(series.units)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        if series.id != viewModel.mainSeries.id {
                            Button(action: { viewModel.removeSeries(series) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.inset)
        .frame(maxHeight: 200)
    }

    // MARK: - Table View
    
    @ViewBuilder
    var tableView: some View {
        if !viewModel.tableRows.isEmpty {
            Table(viewModel.tableRows) {
                TableColumn("Date") { row in
                    Text(row.formattedDate)
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 100, ideal: 150)
                
                TableColumn("Value (\(viewModel.mainSeries.units))") { row in
                    HStack {
                        Spacer()
                        Text(row.formattedValue)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .width(min: 120, ideal: 180)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        } else {
            ContentUnavailableView(
                "No Data",
                systemImage: "tablecells",
                description: Text("No data available for this series.")
            )
        }
    }
    
    // MARK: - Statistics View
    
    @ViewBuilder
    var statisticsView: some View {
        if let stats = viewModel.statistics {
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    StatCard(title: "Count", value: "\(stats.count)", icon: "number")
                    StatCard(title: "Minimum", value: stats.formattedMin, icon: "arrow.down")
                    StatCard(title: "Maximum", value: stats.formattedMax, icon: "arrow.up")
                    StatCard(title: "Mean", value: stats.formattedMean, icon: "divide")
                    StatCard(title: "Median", value: stats.formattedMedian, icon: "equal")
                    StatCard(title: "Std Dev", value: stats.formattedStdDev, icon: "plusminus")
                }
                .padding()
                
                GroupBox("Series Information") {
                    VStack(alignment: .leading, spacing: 12) {
                        InfoRow(label: "Series ID", value: viewModel.mainSeries.id)
                        InfoRow(label: "Title", value: viewModel.mainSeries.title)
                        InfoRow(label: "Units", value: viewModel.mainSeries.units)
                        InfoRow(label: "Frequency", value: viewModel.mainSeries.frequency)
                        InfoRow(label: "Seasonal Adjustment", value: viewModel.mainSeries.seasonalAdjustment)
                        InfoRow(label: "Date Range", value: viewModel.mainSeries.formattedDateRange)
                        InfoRow(label: "Last Updated", value: viewModel.mainSeries.lastUpdated)
                        if let notes = viewModel.mainSeries.notes, !notes.isEmpty {
                            Divider()
                            Text("Notes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .padding()
            }
        } else {
            ContentUnavailableView(
                "No Statistics",
                systemImage: "chart.bar",
                description: Text("Load data to see statistics.")
            )
        }
    }
    
    // MARK: - Actions
    
    private func toggleFavorite() {
        if settings.isFavorite(viewModel.mainSeries) {
            settings.removeFavorite(viewModel.mainSeries)
        } else {
            settings.addFavorite(viewModel.mainSeries)
        }
    }
}

// MARK: - Supporting Views

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                .frame(width: 140, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
            Spacer()
        }
    }
}

// MARK: - Add Series View

struct AddSeriesView: View {
    @StateObject private var searchVM = SearchViewModel()
    @Environment(\.dismiss) private var dismiss
    var onSelect: (FREDSeries) -> Void

    var body: some View {
        NavigationStack {
            VStack {
                if searchVM.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = searchVM.errorMessage {
                    ContentUnavailableView {
                        Label("Search Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                } else if searchVM.results.isEmpty && searchVM.hasSearched {
                    ContentUnavailableView.search(text: searchVM.query)
                } else if searchVM.results.isEmpty {
                    ContentUnavailableView(
                        "Search for Series",
                        systemImage: "magnifyingglass",
                        description: Text("Search for economic data series to compare.")
                    )
                } else {
                    List(searchVM.results) { series in
                        Button(action: {
                            onSelect(series)
                        }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(series.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                HStack {
                                    Text(series.id)
                                    Spacer()
                                    Text(series.units)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $searchVM.query, prompt: "Search economic data...")
            .navigationTitle("Add Series to Compare")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 500)
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
    
    return NavigationStack {
        SeriesDetailView(series: sampleSeries)
    }
}
