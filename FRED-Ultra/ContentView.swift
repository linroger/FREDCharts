//
//  ContentView.swift
//  FRED-Ultra
//
//  Created by Roger Lin on 12/11/24.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedSeries: FREDSeries?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedSeries: $selectedSeries)
        } detail: {
            if let series = selectedSeries {
                SeriesDetailView(series: series)
            } else {
                ContentUnavailableView("Select a Series", systemImage: "chart.xyaxis.line", description: Text("Search and select a data series from the sidebar."))
            }
        }
        .navigationTitle("FRED Ultra")
    }
}

struct SidebarView: View {
    @Binding var selectedSeries: FREDSeries?
    @StateObject private var searchVM = SearchViewModel()

    var body: some View {
        List(selection: $selectedSeries) {
            Section("Search") {
                // In macOS list, we can just show the results directly.
                // Or we can have a search field at the top.
                // .searchable in NavigationSplitView works well.

                if searchVM.isLoading {
                    ProgressView()
                        .id(UUID()) // Force redraw if needed
                } else if let error = searchVM.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                ForEach(searchVM.results) { series in
                    NavigationLink(value: series) {
                        VStack(alignment: .leading) {
                            Text(series.title)
                                .font(.headline)
                                .lineLimit(2)
                            Text(series.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .searchable(text: $searchVM.query, prompt: "Search Economic Data")
        .navigationTitle("Library")
        // .listStyle(.sidebar) is default in sidebar column
    }
}

#Preview {
    ContentView()
}
