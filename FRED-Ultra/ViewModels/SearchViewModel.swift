import Foundation
import Combine

@MainActor
class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [FREDSeries] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var hasSearched: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?

    init() {
        // Debounce search
        $query
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] searchText in
                guard let self = self else { return }
                
                // Cancel any existing search task
                self.searchTask?.cancel()
                
                if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.results = []
                    self.hasSearched = false
                    self.errorMessage = nil
                    return
                }
                
                self.searchTask = Task {
                    await self.performSearch(query: searchText)
                }
            }
            .store(in: &cancellables)
    }

    func performSearch(query: String) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        guard !trimmedQuery.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        hasSearched = true

        do {
            let series = try await FREDService.shared.searchSeries(query: trimmedQuery)
            
            // Check if task was cancelled
            if Task.isCancelled { return }
            
            self.results = series
            
            // Save to recent searches
            SettingsManager.shared.addRecentSearch(trimmedQuery)
        } catch FREDError.missingAPIKey {
            self.errorMessage = "Please enter your API Key in Settings."
            self.results = []
        } catch {
            if !Task.isCancelled {
                self.errorMessage = error.localizedDescription
                self.results = []
            }
        }

        isLoading = false
    }
    
    func clearResults() {
        query = ""
        results = []
        hasSearched = false
        errorMessage = nil
    }
    
    func refresh() async {
        guard !query.isEmpty else { return }
        await performSearch(query: query)
    }
}
