//
//  ContentView.swift
//  FRED-Ultra
//
//  Created by Roger Lin on 12/11/24.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedSeries: FREDSeries?
    @State private var selectedFavorite: FavoriteSeries?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var sidebarSelection: SidebarItem? = .search
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Primary sidebar with sections
            List(selection: $sidebarSelection) {
                Section {
                    Label("Search", systemImage: "magnifyingglass")
                        .tag(SidebarItem.search)
                }
                
                Section("Favorites") {
                    if settings.favorites.isEmpty {
                        Text("No favorites yet")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(settings.favorites) { favorite in
                            Label(favorite.title, systemImage: "star.fill")
                                .tag(SidebarItem.favorite(favorite))
                                .lineLimit(1)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        settings.removeFavorite(favorite)
                                    } label: {
                                        Label("Remove from Favorites", systemImage: "star.slash")
                                    }
                                }
                        }
                    }
                }
                
                if !settings.recentSearches.isEmpty {
                    Section("Recent Searches") {
                        ForEach(settings.recentSearches, id: \.self) { search in
                            Label(search, systemImage: "clock")
                                .tag(SidebarItem.recentSearch(search))
                                .lineLimit(1)
                        }
                        
                        Button(action: { settings.clearRecentSearches() }) {
                            Label("Clear Recent", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("FRED Ultra")
            .frame(minWidth: 200)
        } content: {
            // Content column - search results or favorite details
            switch sidebarSelection {
            case .search, .recentSearch:
                SearchContentView(
                    selectedSeries: $selectedSeries,
                    initialQuery: sidebarSelection?.searchQuery
                )
            case .favorite(let favorite):
                FavoriteContentView(
                    favorite: favorite,
                    selectedSeries: $selectedSeries
                )
            case nil:
                ContentUnavailableView(
                    "Select an Item",
                    systemImage: "sidebar.left",
                    description: Text("Choose an item from the sidebar.")
                )
            }
        } detail: {
            // Detail column - series visualization
            if let series = selectedSeries {
                SeriesDetailView(series: series)
            } else {
                ContentUnavailableView(
                    "Select a Series",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Search and select a data series to visualize.")
                )
            }
        }
        .onChange(of: sidebarSelection) { _, newValue in
            // Clear selection when switching sidebar items
            if case .favorite(let fav) = newValue {
                // Load the favorite series
                Task {
                    await loadFavoriteSeries(fav)
                }
            }
        }
    }
    
    private func loadFavoriteSeries(_ favorite: FavoriteSeries) async {
        do {
            let series = try await FREDService.shared.getSeriesInfo(seriesId: favorite.id)
            await MainActor.run {
                selectedSeries = series
            }
        } catch {
            print("Failed to load favorite: \(error)")
        }
    }
}

// MARK: - Sidebar Item

enum SidebarItem: Hashable {
    case search
    case favorite(FavoriteSeries)
    case recentSearch(String)
    
    var searchQuery: String? {
        switch self {
        case .recentSearch(let query):
            return query
        default:
            return nil
        }
    }
}

// MARK: - Search Content View

struct SearchContentView: View {
    @Binding var selectedSeries: FREDSeries?
    let initialQuery: String?
    @StateObject private var searchVM = SearchViewModel()
    
    var body: some View {
        List(selection: $selectedSeries) {
            if searchVM.isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Searching...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else if let error = searchVM.errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else if searchVM.results.isEmpty && searchVM.hasSearched {
                ContentUnavailableView.search(text: searchVM.query)
            } else if searchVM.results.isEmpty {
                ContentUnavailableView(
                    "Search Economic Data",
                    systemImage: "magnifyingglass",
                    description: Text("Enter a search term to find FRED data series.\n\nExamples: GDP, unemployment, inflation, interest rates")
                )
            } else {
                Section("Results (\(searchVM.results.count))") {
                    ForEach(searchVM.results) { series in
                        SeriesRowView(series: series)
                            .tag(series)
                    }
                }
            }
        }
        .searchable(text: $searchVM.query, prompt: "Search economic data...")
        .navigationTitle("Search")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    Task { await searchVM.refresh() }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(searchVM.query.isEmpty || searchVM.isLoading)
            }
        }
        .onAppear {
            if let query = initialQuery, searchVM.query.isEmpty {
                searchVM.query = query
            }
        }
    }
}

// MARK: - Favorite Content View

struct FavoriteContentView: View {
    let favorite: FavoriteSeries
    @Binding var selectedSeries: FREDSeries?
    @State private var isLoading = true
    @State private var error: String?
    @State private var series: FREDSeries?
    
    var body: some View {
        Group {
            if isLoading {
                VStack {
                    ProgressView()
                    Text("Loading \(favorite.title)...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        Task { await loadSeries() }
                    }
                }
            } else if let series = series {
                List(selection: $selectedSeries) {
                    SeriesRowView(series: series)
                        .tag(series)
                }
            }
        }
        .navigationTitle(favorite.title)
        .task {
            await loadSeries()
        }
    }
    
    private func loadSeries() async {
        isLoading = true
        error = nil
        
        do {
            let loadedSeries = try await FREDService.shared.getSeriesInfo(seriesId: favorite.id)
            series = loadedSeries
            selectedSeries = loadedSeries
        } catch {
            self.error = error.localizedDescription
        }
        
        isLoading = false
    }
}

// MARK: - Series Row View

struct SeriesRowView: View {
    let series: FREDSeries
    @ObservedObject private var settings = SettingsManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(series.title)
                    .font(.headline)
                    .lineLimit(2)
                
                if settings.isFavorite(series) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
            }
            
            HStack {
                Text(series.id)
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                
                Spacer()
                
                Text(series.frequency)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            HStack {
                Text(series.units)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                Spacer()
                
                Text(series.formattedDateRange)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                if settings.isFavorite(series) {
                    settings.removeFavorite(series)
                } else {
                    settings.addFavorite(series)
                }
            } label: {
                Label(
                    settings.isFavorite(series) ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: settings.isFavorite(series) ? "star.slash" : "star"
                )
            }
            
            Divider()
            
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(series.id, forType: .string)
            } label: {
                Label("Copy Series ID", systemImage: "doc.on.clipboard")
            }
        }
    }
}

#Preview {
    ContentView()
}
