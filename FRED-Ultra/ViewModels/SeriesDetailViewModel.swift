import Foundation
import Charts

@MainActor
class SeriesDetailViewModel: ObservableObject {
    @Published var mainSeries: FREDSeries
    @Published var seriesData: [String: [FREDObservation]] = [:] // SeriesID -> Observations
    @Published var additionalSeries: [FREDSeries] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // For "Showing similar data series", we might keep track of suggestions.
    // For now, we focus on the main series and any manually added ones.

    init(series: FREDSeries) {
        self.mainSeries = series
    }

    var allSeries: [FREDSeries] {
        [mainSeries] + additionalSeries
    }

    func loadData() async {
        isLoading = true
        errorMessage = nil

        let idsToFetch = allSeries.map { $0.id }
        // Filter out ones we already have? Or just refresh all. Let's refresh all to be safe.

        do {
            let data = try await FREDService.shared.getMultipleSeriesObservations(seriesIds: idsToFetch)
            self.seriesData = data
        } catch {
            self.errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func addSeries(_ series: FREDSeries) {
        guard !allSeries.contains(where: { $0.id == series.id }) else { return }
        additionalSeries.append(series)
        Task {
            await loadData()
        }
    }

    func removeSeries(_ series: FREDSeries) {
        if series.id == mainSeries.id { return } // Cannot remove main series
        additionalSeries.removeAll { $0.id == series.id }
        seriesData.removeValue(forKey: series.id)
    }
}
