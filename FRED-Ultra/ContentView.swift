import SwiftUI

struct ContentView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @StateObject private var searchViewModel = SearchViewModel()
    @State private var selectedSeries: FREDSeries?
    @State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn

    var body: some View {
        Group {
            if settings.hasValidAPIKey {
                workspaceView
            } else {
                WelcomeView()
            }
        }
    }

    private var workspaceView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceSidebarView(
                searchViewModel: searchViewModel,
                favorites: settings.favorites,
                recentSearches: settings.recentSearches,
                onSelectSeries: { selectedSeries = $0 },
                onSelectRecentSearch: { searchViewModel.query = $0 },
                onSelectFavorite: { favorite in
                    Task { await loadFavorite(favorite) }
                },
                onRefreshSearch: {
                    Task { await searchViewModel.refresh() }
                },
                onRemoveFavorite: settings.removeFavorite,
                onClearRecentSearches: settings.clearRecentSearches
            )
        } detail: {
            Group {
                if let selectedSeries {
                    SeriesDetailView(series: selectedSeries)
                        .id(selectedSeries.id)
                } else {
                    WorkspaceLandingView(
                        favoritesCount: settings.favorites.count,
                        recentSearches: settings.recentSearches,
                        onUseRecentSearch: { searchViewModel.query = $0 }
                    )
                }
            }
        }
    }

    private func loadFavorite(_ favorite: FavoriteSeries) async {
        do {
            selectedSeries = try await FREDService.shared.getSeriesInfo(seriesId: favorite.id)
        } catch {
            AppLogger.settings.error("Failed to load favorite \(favorite.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Sidebar

private struct WorkspaceSidebarView: View {
    @ObservedObject var searchViewModel: SearchViewModel
    let favorites: [FavoriteSeries]
    let recentSearches: [String]
    let onSelectSeries: (FREDSeries) -> Void
    let onSelectRecentSearch: (String) -> Void
    let onSelectFavorite: (FavoriteSeries) -> Void
    let onRefreshSearch: () -> Void
    let onRemoveFavorite: (FavoriteSeries) -> Void
    let onClearRecentSearches: () -> Void

    var body: some View {
        List {
            if !recentSearches.isEmpty {
                Section("Recent Searches") {
                    RecentSearchStrip(searches: recentSearches, onSelectSearch: onSelectRecentSearch)

                    Button("Clear Recent Searches", role: .destructive, action: onClearRecentSearches)
                        .font(.caption)
                }
            }

            Section(searchResultsTitle) {
                if searchViewModel.isLoading {
                    ProgressRow(label: "Searching FRED…")
                } else if let errorMessage = searchViewModel.errorMessage {
                    InlineMessageRow(
                        systemImage: "exclamationmark.triangle.fill",
                        title: "Search Error",
                        message: errorMessage,
                        tint: .orange
                    )
                } else if searchViewModel.results.isEmpty && searchViewModel.hasSearched {
                    ContentUnavailableView.search(text: searchViewModel.query)
                } else if searchViewModel.results.isEmpty {
                    SidebarPromptView(onSelectSearch: onSelectRecentSearch)
                } else {
                    ForEach(searchViewModel.results) { series in
                        Button {
                            onSelectSeries(series)
                        } label: {
                            SeriesRowView(series: series)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { favorite in
                        FavoriteRowView(
                            favorite: favorite,
                            onOpen: { onSelectFavorite(favorite) },
                            onRemove: { onRemoveFavorite(favorite) }
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchViewModel.query, prompt: "Search economic data")
        .navigationTitle("FRED Ultra")
        .frame(minWidth: 320)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onRefreshSearch) {
                    Label("Refresh Search", systemImage: "arrow.clockwise")
                }
                .disabled(searchViewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchViewModel.isLoading)
            }

            ToolbarItem(placement: .automatic) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
    }

    private var searchResultsTitle: String {
        if searchViewModel.results.isEmpty {
            return "Search"
        }

        return "Results (\(searchViewModel.results.count))"
    }
}

// MARK: - Welcome

private struct WelcomeView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @State private var apiKeyInput = ""
    @State private var isTestingKey = false
    @State private var resultMessage: String?
    @State private var resultIsSuccess = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 14) {
                Image(systemName: "building.columns.circle.fill")
                    .font(.system(size: 68))
                    .foregroundStyle(.blue)

                Text("FRED Ultra")
                    .font(.system(size: 34, weight: .bold, design: .rounded))

                Text("A macOS research desk for exploring Federal Reserve time-series data.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 18) {
                Text("Enter your free FRED API key to unlock search, comparison charts, exports, and economic analysis.")
                    .font(.headline)

                HStack(alignment: .top, spacing: 12) {
                    SecureField("FRED API Key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)

                    Button(action: testAndSaveAPIKey) {
                        if isTestingKey {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Validate & Save")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingKey)
                }

                if let resultMessage {
                    Label(resultMessage, systemImage: resultIsSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(resultIsSuccess ? .green : .red)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("What you can do once connected")
                        .font(.subheadline.weight(.semibold))

                    Label("Search across thousands of FRED series", systemImage: "magnifyingglass")
                    Label("Compare multiple series with rebased chart mode", systemImage: "chart.xyaxis.line")
                    Label("Review data tables, key statistics, and insight cards", systemImage: "chart.bar.doc.horizontal")
                    Label("Export observations as CSV or JSON", systemImage: "square.and.arrow.up")
                }
                .font(.callout)

                Link("Get a free API key from FRED", destination: URL(string: "https://fred.stlouisfed.org/docs/api/api_key.html")!)
                    .font(.callout.weight(.medium))
            }
            .padding(24)
            .frame(maxWidth: 620)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Spacer()
        }
        .padding(32)
        .frame(minWidth: 760, minHeight: 560)
    }

    private func testAndSaveAPIKey() {
        isTestingKey = true
        resultMessage = nil

        Task {
            do {
                try await FREDService.shared.validateAPIKey(apiKeyInput)
                settings.updateAPIKey(apiKeyInput)
                resultIsSuccess = true
                resultMessage = "API key validated. Opening your workspace…"
                AppLogger.settings.info("Validated and saved a FRED API key")
            } catch {
                resultIsSuccess = false
                resultMessage = error.localizedDescription
                AppLogger.settings.error("API key validation failed: \(error.localizedDescription, privacy: .public)")
            }

            isTestingKey = false
        }
    }
}

// MARK: - Landing

private struct WorkspaceLandingView: View {
    let favoritesCount: Int
    let recentSearches: [String]
    let onUseRecentSearch: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Economic Research Desk")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Search the sidebar to load a FRED series, compare indicators, and inspect the latest changes, range position, and annualized drift.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    LandingCard(title: "Favorites", value: "\(favoritesCount)", detail: "Pinned series ready to reopen", symbol: "star.fill", tint: .yellow)
                    LandingCard(title: "Recent Searches", value: "\(recentSearches.count)", detail: "Queries available for one-click reuse", symbol: "clock.arrow.circlepath", tint: .blue)
                    LandingCard(title: "Exports", value: "CSV / JSON", detail: "Export current observations or copy them directly", symbol: "square.and.arrow.up", tint: .green)
                }

                if !recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Jump back in")
                            .font(.headline)

                        FlowingTagList(items: recentSearches) { search in
                            Button(search) {
                                onUseRecentSearch(search)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                GroupBox("Shipped in this overhaul") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Stable sidebar-to-detail macOS workflow", systemImage: "sidebar.leading")
                        Label("Honest multi-series comparison using rebased charts", systemImage: "chart.line.uptrend.xyaxis")
                        Label("Richer insight cards including period change and annualized drift", systemImage: "waveform.path.ecg.rectangle")
                        Label("Unified logging around search, settings, detail loading, and export actions", systemImage: "text.append")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Research Desk")
    }
}

// MARK: - Supporting Views

private struct ProgressRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private struct InlineMessageRow: View {
    let systemImage: String
    let title: String
    let message: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .padding(.vertical, 8)
    }
}

private struct SidebarPromptView: View {
    let onSelectSearch: (String) -> Void

    private let suggestions = ["GDP", "UNRATE", "CPI", "DGS10", "PAYEMS"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try a search")
                .font(.headline)
            Text("Search by series ID, indicator name, or theme.")
                .foregroundStyle(.secondary)
            FlowingTagList(items: suggestions) { suggestion in
                Button(suggestion) {
                    onSelectSearch(suggestion)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct RecentSearchStrip: View {
    let searches: [String]
    let onSelectSearch: (String) -> Void

    var body: some View {
        FlowingTagList(items: Array(searches.prefix(6))) { search in
            Button(search) {
                onSelectSearch(search)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

private struct FavoriteRowView: View {
    let favorite: FavoriteSeries
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(favorite.title)
                        .lineLimit(2)
                    Text("\(favorite.id) • \(favorite.frequency)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove Favorite", role: .destructive, action: onRemove)
        }
    }
}

struct SeriesRowView: View {
    let series: FREDSeries
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(series.title)
                        .font(.headline)
                        .lineLimit(2)

                    Text(series.subtitleLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if settings.isFavorite(series) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
            }

            HStack {
                Text(series.id)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.12), in: Capsule())

                if let popularity = series.popularity {
                    Text("Popularity \(popularity)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let shortNotes = series.shortNotes {
                Text(shortNotes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button(settings.isFavorite(series) ? "Remove from Favorites" : "Add to Favorites") {
                if settings.isFavorite(series) {
                    settings.removeFavorite(series)
                } else {
                    settings.addFavorite(series)
                }
            }

            Button("Copy Series ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(series.id, forType: .string)
            }
        }
    }
}

private struct LandingCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.title3)

            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Text(title)
                .font(.headline)

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct FlowingTagList<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}

#Preview {
    ContentView()
}
