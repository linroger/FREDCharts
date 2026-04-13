import Combine
import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [FREDSeries] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var hasSearched = false

    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?

    init() {
        $query
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] searchText in
                guard let self else { return }
                self.handleSearchTextChange(searchText)
            }
            .store(in: &cancellables)
    }

    func performSearch(query: String) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            clearResults()
            return
        }

        isLoading = true
        errorMessage = nil
        hasSearched = true

        do {
            let series = try await FREDService.shared.searchSeries(query: trimmedQuery)
            guard !Task.isCancelled else { return }

            results = series
            SettingsManager.shared.addRecentSearch(trimmedQuery)
            AppLogger.search.info("Loaded \(series.count) search results for '\(trimmedQuery, privacy: .public)'")
        } catch is CancellationError {
            AppLogger.search.debug("Cancelled search for '\(trimmedQuery, privacy: .public)'")
        } catch {
            guard !Task.isCancelled else { return }

            results = []
            errorMessage = error.localizedDescription
            AppLogger.search.error("Search failed for '\(trimmedQuery, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }

        isLoading = false
    }

    func refresh() async {
        await performSearch(query: query)
    }

    func clearResults() {
        results = []
        errorMessage = nil
        hasSearched = false
    }

    private func handleSearchTextChange(_ searchText: String) {
        searchTask?.cancel()

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearResults()
            return
        }

        searchTask = Task { [weak self] in
            await self?.performSearch(query: trimmed)
        }
    }
}
