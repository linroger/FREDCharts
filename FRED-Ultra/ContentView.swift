//
//  ContentView.swift
//  FRED-Ultra
//
//  Created by Roger Lin on 12/11/24.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var searchVM = SearchViewModel()
    @State private var selectedSeries: FREDSeries?
    @State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn

    var body: some View {
        Group {
            if !settings.hasValidAPIKey {
                WelcomeView()
            } else {
                mainContentView
            }
        }
    }
    
    private var mainContentView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarView
        } detail: {
            detailView
        }
    }
    
    private var sidebarView: some View {
        VStack(spacing: 0) {
            // Search results
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
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(error)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .font(.callout)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else if searchVM.results.isEmpty && searchVM.hasSearched {
                    ContentUnavailableView.search(text: searchVM.query)
                } else if searchVM.results.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Search Economic Data")
                            .font(.headline)
                        Text("Enter a search term above to find FRED data series.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Try searching for:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(["GDP", "Unemployment Rate", "Inflation", "Interest Rates"], id: \.self) { term in
                                Button(action: { searchVM.query = term }) {
                                    HStack {
                                        Image(systemName: "magnifyingglass")
                                            .font(.caption)
                                        Text(term)
                                    }
                                    .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else {
                    Section("Results (\(searchVM.results.count))") {
                        ForEach(searchVM.results) { series in
                            SeriesRowView(series: series)
                                .tag(series)
                        }
                    }
                }
                
                // Favorites section
                if !settings.favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(settings.favorites) { favorite in
                            Button(action: {
                                Task {
                                    await loadFavorite(favorite)
                                }
                            }) {
                                HStack {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(.yellow)
                                    VStack(alignment: .leading) {
                                        Text(favorite.title)
                                            .lineLimit(1)
                                        Text(favorite.id)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
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
            }
            .searchable(text: $searchVM.query, prompt: "Search FRED data...")
        }
        .navigationTitle("FRED Ultra")
        .frame(minWidth: 300)
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
    }
    
    private var detailView: some View {
        Group {
            if let series = selectedSeries {
                SeriesDetailView(series: series)
            } else {
                ContentUnavailableView(
                    "Select a Data Series",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Search for economic data and select a series to view charts and statistics.")
                )
            }
        }
    }
    
    private func loadFavorite(_ favorite: FavoriteSeries) async {
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

// MARK: - Welcome View (API Key Setup)

struct WelcomeView: View {
    @StateObject private var settings = SettingsManager.shared
    @State private var apiKeyInput = ""
    @State private var isTestingKey = false
    @State private var testResult: (success: Bool, message: String)?
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
            
            Text("Welcome to FRED Ultra")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Explore economic data from the Federal Reserve")
                .font(.title3)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 16) {
                Text("To get started, enter your FRED API key:")
                    .font(.headline)
                
                HStack {
                    SecureField("Enter your API key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 400)
                    
                    Button(action: testAPIKey) {
                        if isTestingKey {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Text("Test & Save")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKeyInput.isEmpty || isTestingKey)
                }
                
                if let result = testResult {
                    HStack {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        Text(result.message)
                    }
                    .foregroundStyle(result.success ? .green : .red)
                    .font(.callout)
                }
                
                Divider()
                    .padding(.vertical, 8)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Don't have an API key?")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text("Get a free API key from the FRED website:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Link(destination: URL(string: "https://fred.stlouisfed.org/docs/api/api_key.html")!) {
                        HStack {
                            Image(systemName: "link")
                            Text("Get Free API Key")
                        }
                    }
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 500)
            
            Spacer()
        }
        .padding()
        .frame(minWidth: 600, minHeight: 500)
    }
    
    private func testAPIKey() {
        isTestingKey = true
        testResult = nil
        
        // Temporarily set the API key
        let originalKey = settings.apiKey
        settings.apiKey = apiKeyInput
        
        Task {
            do {
                // Test with a simple search
                _ = try await FREDService.shared.searchSeries(query: "GDP", limit: 1)
                await MainActor.run {
                    testResult = (true, "API key is valid! Starting app...")
                    isTestingKey = false
                    // Key is already saved, app will transition
                }
            } catch {
                await MainActor.run {
                    settings.apiKey = originalKey // Restore original
                    testResult = (false, error.localizedDescription)
                    isTestingKey = false
                }
            }
        }
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
                
                Spacer()
                
                if settings.isFavorite(series) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
            }
            
            HStack {
                Text(series.id)
                    .font(.caption)
                    .fontWeight(.medium)
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
            
            Text(series.units)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
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
