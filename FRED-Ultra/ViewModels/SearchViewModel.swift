import Combine
import Foundation

/// Drives the sidebar search field: debounce, cancellation, and result state.
@MainActor
final class SearchViewModel: ObservableObject {
    typealias Searcher = @Sendable (_ query: String, _ limit: Int) async throws -> [FREDSeries]

    @Published var query = ""
    @Published private(set) var results: [FREDSeries] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasSearched = false

    nonisolated static let defaultResultLimit = 50
    nonisolated static let defaultDebounce: Duration = .milliseconds(350)

    private let searcher: Searcher
    private let resultLimit: Int
    private let debounce: Duration
    private let recordRecentSearch: @MainActor (String) -> Void

    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?

    /// Monotonic token identifying the newest search. A superseded task must never write
    /// state — previously a cancelled task could leave `isLoading` stuck at `true`,
    /// which left the sidebar spinning forever after the query was cleared.
    private var currentSearchToken = 0

    init(
        resultLimit: Int = SearchViewModel.defaultResultLimit,
        debounce: Duration = SearchViewModel.defaultDebounce,
        searcher: @escaping Searcher = { query, limit in
            try await FREDService.shared.searchSeries(query: query, limit: limit)
        },
        recordRecentSearch: @escaping @MainActor (String) -> Void = { SettingsManager.shared.addRecentSearch($0) }
    ) {
        self.resultLimit = resultLimit
        self.debounce = debounce
        self.searcher = searcher
        self.recordRecentSearch = recordRecentSearch

        $query
            .removeDuplicates()
            .sink { [weak self] text in
                self?.queryDidChange(text)
            }
            .store(in: &cancellables)
    }

    deinit {
        searchTask?.cancel()
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canRefresh: Bool {
        !trimmedQuery.isEmpty && !isLoading
    }

    /// True when the result list is exactly the requested page, so more matches may exist.
    var resultsAreCapped: Bool {
        results.count >= resultLimit
    }

    var resultLimitNotice: String {
        "Showing the \(resultLimit) most popular matches. Narrow the search or enter a series ID for more specific results."
    }

    /// Runs a search immediately, bypassing the debounce (used by Refresh and ⌘-Return).
    func refresh() async {
        await performSearch(query: trimmedQuery)
    }

    func clearResults() {
        searchTask?.cancel()
        searchTask = nil
        currentSearchToken &+= 1

        results = []
        errorMessage = nil
        hasSearched = false
        isLoading = false
    }

    func performSearch(query rawQuery: String) async {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearResults()
            return
        }

        currentSearchToken &+= 1
        let token = currentSearchToken

        isLoading = true
        errorMessage = nil
        hasSearched = true

        defer {
            // Only the newest search owns the loading indicator.
            if token == currentSearchToken {
                isLoading = false
            }
        }

        do {
            let series = try await searcher(trimmed, resultLimit)
            guard token == currentSearchToken, !Task.isCancelled else { return }

            results = series
            recordRecentSearch(trimmed)
            AppLogger.search.info("Loaded \(series.count) results for '\(trimmed, privacy: .public)'")
        } catch is CancellationError {
            AppLogger.search.debug("Cancelled search for '\(trimmed, privacy: .public)'")
        } catch {
            guard token == currentSearchToken, !Task.isCancelled else { return }
            if case FREDError.cancelled = error { return }

            results = []
            errorMessage = Self.describe(error)
            AppLogger.search.error("Search failed for '\(trimmed, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Private

    private func queryDidChange(_ text: String) {
        searchTask?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearResults()
            return
        }

        let delay = debounce
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.performSearch(query: trimmed)
        }
    }

    /// Includes FRED's recovery hint so the sidebar message is actionable on its own.
    nonisolated static func describe(_ error: Error) -> String {
        guard let fredError = error as? FREDError else { return error.localizedDescription }

        if let suggestion = fredError.recoverySuggestion {
            return "\(fredError.localizedDescription)\n\(suggestion)"
        }
        return fredError.localizedDescription
    }
}
