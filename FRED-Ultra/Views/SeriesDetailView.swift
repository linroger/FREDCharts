import SwiftUI
import Charts

struct SeriesDetailView: View {
    @StateObject var viewModel: SeriesDetailViewModel
    @State private var showingAddSeriesSheet = false
    @State private var selectedTab = 0

    init(series: FREDSeries) {
        _viewModel = StateObject(wrappedValue: SeriesDetailViewModel(series: series))
    }

    var body: some View {
        VStack {
            if viewModel.isLoading && viewModel.seriesData.isEmpty {
                ProgressView()
            } else {
                Picker("View", selection: $selectedTab) {
                    Text("Chart").tag(0)
                    Text("Table").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedTab == 0 {
                    chartView
                } else {
                    tableView
                }
            }
        }
        .navigationTitle(viewModel.mainSeries.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showingAddSeriesSheet = true }) {
                    Label("Add Series", systemImage: "plus")
                }
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
            get: { viewModel.errorMessage != nil },
            set: { _ in viewModel.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    @ViewBuilder
    var chartView: some View {
        VStack(alignment: .leading) {
            if !viewModel.seriesData.isEmpty {
                Chart {
                    ForEach(viewModel.allSeries) { series in
                        if let obs = viewModel.seriesData[series.id] {
                            ForEach(obs) { item in
                                if let date = item.dateObject, let value = item.doubleValue {
                                    LineMark(
                                        x: .value("Date", date),
                                        y: .value("Value", value)
                                    )
                                    .foregroundStyle(by: .value("Series", series.title))
                                }
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .chartLegend(position: .bottom)
                .padding()
            } else {
                ContentUnavailableView("No Data", systemImage: "chart.xyaxis.line", description: Text("No data available for this series."))
            }

            List {
                Section(header: Text("Series Info")) {
                    ForEach(viewModel.allSeries) { series in
                        VStack(alignment: .leading) {
                            Text(series.title).font(.headline)
                            HStack {
                                Text("ID: \(series.id)")
                                Spacer()
                                Text(series.units)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            if series.id != viewModel.mainSeries.id {
                                Button("Remove", role: .destructive) {
                                    viewModel.removeSeries(series)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    var tableView: some View {
        // Swift Table for the main series (or we could combine them, but simpler to show main series first or allow selection)
        // For now, let's show a list of observations for the main series, or a multi-column table if on iPad/Mac.
        // Since we want "Swift tables", we can use the `Table` view available in iOS 16+.

        if let obs = viewModel.seriesData[viewModel.mainSeries.id] {
            Table(obs) {
                TableColumn("Date", value: \.date)
                TableColumn("Value", value: \.value)
            }
        } else {
            ContentUnavailableView("No Data", systemImage: "table", description: Text("No data available."))
        }
    }
}

// Helper view to search for additional series to add to the chart
struct AddSeriesView: View {
    @StateObject private var searchVM = SearchViewModel()
    var onSelect: (FREDSeries) -> Void

    var body: some View {
        NavigationStack {
            List(searchVM.results) { series in
                Button(action: {
                    onSelect(series)
                }) {
                    VStack(alignment: .leading) {
                        Text(series.title)
                            .font(.headline)
                        Text(series.id)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .searchable(text: $searchVM.query, prompt: "Search to compare...")
            .navigationTitle("Add Series")
        }
    }
}
