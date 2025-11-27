import Foundation
import Combine

@MainActor
class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [FREDSeries] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Debounce search
        $query
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] searchText in
                guard let self = self, !searchText.isEmpty else {
                    self?.results = []
                    return
                }
                Task {
                    await self.performSearch(query: searchText)
                }
            }
            .store(in: &cancellables)
    }

    func performSearch(query: String) async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        isLoading = true
        errorMessage = nil

        do {
            let series = try await FREDService.shared.searchSeries(query: query)
            self.results = series
        } catch FREDError.missingAPIKey {
            self.errorMessage = "Please enter your API Key in Settings."
        } catch {
            self.errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
