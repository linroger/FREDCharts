import AppKit
import SwiftUI

/// Identifies a selectable sidebar row. Favorites and search results can list the same
/// series, so the case distinguishes them and keeps the selection highlight on the row
/// the reader actually clicked.
enum SidebarSelection: Hashable {
    case result(String)
    case favorite(String)

    var seriesID: String {
        switch self {
        case .result(let id), .favorite(let id):
            return id
        }
    }
}

struct ContentView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @StateObject private var searchViewModel = SearchViewModel()

    @State private var selection: SidebarSelection?
    @State private var selectedSeries: FREDSeries?
    @State private var isResolvingSelection = false
    @State private var selectionError: String?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        Group {
            if settings.hasValidAPIKey {
                workspace
            } else {
                WelcomeView()
            }
        }
    }

    private var workspace: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceSidebarView(
                searchViewModel: searchViewModel,
                favorites: settings.favorites,
                recentSearches: settings.recentSearches,
                selection: $selection,
                onSelectRecentSearch: { searchViewModel.query = $0 },
                onRefreshSearch: { Task { await searchViewModel.refresh() } },
                onRemoveFavorite: { settings.removeFavorite(id: $0) },
                onClearRecentSearches: settings.clearRecentSearches
            )
        } detail: {
            detailPane
        }
        // `.task(id:)` cancels the previous lookup automatically, so rapid clicking
        // through results never lets a stale series win the race.
        .task(id: selection) {
            await resolveSelection()
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selectionError {
            ContentUnavailableView {
                Label("Could Not Open Series", systemImage: "exclamationmark.triangle")
            } description: {
                Text(selectionError)
            } actions: {
                Button("Try Again") {
                    let current = selection
                    selection = nil
                    selection = current
                }
                .buttonStyle(.borderedProminent)
            }
        } else if isResolvingSelection {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Opening series…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let selectedSeries {
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

    /// Resolves a sidebar selection into full series metadata.
    ///
    /// Search results already carry metadata; favorites only store an ID, so those are
    /// fetched. Failures used to be logged and swallowed, leaving the click with no
    /// visible effect at all.
    private func resolveSelection() async {
        guard let selection else {
            selectedSeries = nil
            selectionError = nil
            isResolvingSelection = false
            return
        }

        let seriesID = selection.seriesID
        selectionError = nil

        if let match = searchViewModel.results.first(where: { $0.id == seriesID }) {
            selectedSeries = match
            isResolvingSelection = false
            return
        }

        if selectedSeries?.id == seriesID { return }

        isResolvingSelection = true
        defer { isResolvingSelection = false }

        do {
            let series = try await FREDService.shared.getSeriesInfo(seriesId: seriesID)
            guard !Task.isCancelled else { return }
            selectedSeries = series
        } catch {
            guard !Task.isCancelled else { return }
            selectedSeries = nil
            selectionError = SearchViewModel.describe(error)
            AppLogger.settings.error("Failed to open \(seriesID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Sidebar

private struct WorkspaceSidebarView: View {
    @ObservedObject var searchViewModel: SearchViewModel
    let favorites: [FavoriteSeries]
    let recentSearches: [String]
    @Binding var selection: SidebarSelection?
    let onSelectRecentSearch: (String) -> Void
    let onRefreshSearch: () -> Void
    let onRemoveFavorite: (String) -> Void
    let onClearRecentSearches: () -> Void

    var body: some View {
        List(selection: $selection) {
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
                } else if searchViewModel.results.isEmpty, searchViewModel.hasSearched {
                    InlineMessageRow(
                        systemImage: "magnifyingglass",
                        title: "No Matches",
                        message: "No FRED series matched “\(searchViewModel.trimmedQuery)”. Try a broader term or a series ID.",
                        tint: .secondary
                    )
                } else if searchViewModel.results.isEmpty {
                    SidebarPromptView(onSelectSearch: onSelectRecentSearch)
                } else {
                    ForEach(searchViewModel.results) { series in
                        SeriesRowView(series: series)
                            .tag(SidebarSelection.result(series.id))
                    }

                    if searchViewModel.resultsAreCapped {
                        Text(searchViewModel.resultLimitNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 4)
                    }
                }
            }

            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { favorite in
                        FavoriteRowView(favorite: favorite, onRemove: { onRemoveFavorite(favorite.id) })
                            .tag(SidebarSelection.favorite(favorite.id))
                    }
                }
            }

            if !recentSearches.isEmpty {
                Section("Recent Searches") {
                    FlowingTagList(items: Array(recentSearches.prefix(8))) { search in
                        Button(search) { onSelectRecentSearch(search) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 4)

                    Button("Clear Recent Searches", role: .destructive, action: onClearRecentSearches)
                        .font(.caption)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchViewModel.query, placement: .sidebar, prompt: "Search economic data")
        .navigationTitle("FRED Ultra")
        .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 460)
        .accessibilityIdentifier("sidebar.list")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onRefreshSearch) {
                    Label("Refresh Search", systemImage: "arrow.clockwise")
                }
                .disabled(!searchViewModel.canRefresh)
                .help("Run the current search again")
                .accessibilityIdentifier("sidebar.refresh")
            }

            ToolbarItem(placement: .automatic) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open FRED Ultra settings")
            }
        }
    }

    private var searchResultsTitle: String {
        searchViewModel.results.isEmpty ? "Search" : "Results (\(searchViewModel.results.count))"
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
        ScrollView {
            VStack(spacing: 28) {
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
                    Text("Enter your free FRED API key to unlock search, comparison charts, transforms, and exports.")
                        .font(.headline)

                    HStack(alignment: .top, spacing: 12) {
                        SecureField("FRED API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("welcome.apiKeyField")
                            .onSubmit(testAndSaveAPIKey)

                        Button(action: testAndSaveAPIKey) {
                            if isTestingKey {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Validate & Save")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingKey)
                        .accessibilityIdentifier("welcome.validateButton")
                    }

                    if let resultMessage {
                        Label(resultMessage, systemImage: resultIsSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(resultIsSuccess ? .green : .red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("What you can do once connected")
                            .font(.subheadline.weight(.semibold))

                        Label("Search across thousands of FRED series", systemImage: "magnifyingglass")
                        Label("Compare series with index, growth, and year-over-year views", systemImage: "chart.xyaxis.line")
                        Label("Review data tables, statistics, and correlation insights", systemImage: "chart.bar.doc.horizontal")
                        Label("Export exactly what you see as CSV or JSON", systemImage: "square.and.arrow.up")
                    }
                    .font(.callout)

                    Link("Get a free API key from FRED", destination: URL(string: "https://fred.stlouisfed.org/docs/api/api_key.html")!)
                        .font(.callout.weight(.medium))
                }
                .padding(24)
                .frame(maxWidth: 620)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 640, minHeight: 520)
    }

    private func testAndSaveAPIKey() {
        let candidate = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !isTestingKey else { return }

        isTestingKey = true
        resultMessage = nil

        Task {
            defer { isTestingKey = false }

            do {
                try await FREDService.shared.validateAPIKey(candidate)
                let storage = settings.updateAPIKey(candidate)
                resultIsSuccess = true
                resultMessage = "API key validated. \(storage.explanation)"
                AppLogger.settings.info("Validated and saved a FRED API key (\(storage.rawValue, privacy: .public))")
            } catch {
                resultIsSuccess = false
                resultMessage = SearchViewModel.describe(error)
                AppLogger.settings.error("API key validation failed: \(error.localizedDescription, privacy: .public)")
            }
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
                    Text("Search in the sidebar to open a FRED series, then compare indicators, switch between levels and growth rates, and inspect range position, volatility, and annualized drift.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                    LandingCard(title: "Favorites", value: "\(favoritesCount)", detail: "Pinned series ready to reopen", symbol: "star.fill", tint: .yellow)
                    LandingCard(title: "Recent Searches", value: "\(recentSearches.count)", detail: "Queries available for one-click reuse", symbol: "clock.arrow.circlepath", tint: .blue)
                    LandingCard(title: "Exports", value: "CSV / JSON", detail: "Export or copy exactly what the chart shows", symbol: "square.and.arrow.up", tint: .green)
                }

                if !recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Jump back in")
                            .font(.headline)

                        FlowingTagList(items: recentSearches) { search in
                            Button(search) { onUseRecentSearch(search) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }

                GroupBox("Working with the data") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Date windows are measured from each series' own latest observation, so discontinued series still chart correctly.", systemImage: "calendar")
                        Label("Transforms (Change, % Change, YoY, Index) are computed on full history, so the first visible point is never a partial calculation.", systemImage: "function")
                        Label("Series with different units are compared as indexes rather than pretending the raw values share an axis.", systemImage: "equal.square")
                        Label("Every export and clipboard copy contains the window, transform, and units it was produced with.", systemImage: "doc.text")
                    }
                    .font(.callout)
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
            ProgressView().controlSize(.small)
            Text(label).foregroundStyle(.secondary)
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
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }
}

private struct SidebarPromptView: View {
    let onSelectSearch: (String) -> Void

    private let suggestions = ["GDP", "UNRATE", "CPIAUCSL", "DGS10", "PAYEMS", "FEDFUNDS"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try a search")
                .font(.headline)
            Text("Search by series ID, indicator name, or theme.")
                .foregroundStyle(.secondary)
                .font(.callout)
            FlowingTagList(items: suggestions) { suggestion in
                Button(suggestion) { onSelectSearch(suggestion) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct FavoriteRowView: View {
    let favorite: FavoriteSeries
    let onRemove: () -> Void

    var body: some View {
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

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
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

                Spacer(minLength: 0)

                if settings.isFavorite(series.id) {
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
            Button(settings.isFavorite(series.id) ? "Remove from Favorites" : "Add to Favorites") {
                settings.toggleFavorite(series)
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
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct FlowingTagList<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}

#Preview {
    ContentView()
}
