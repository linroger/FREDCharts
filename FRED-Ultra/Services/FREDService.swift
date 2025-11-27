import Foundation

enum FREDError: Error {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case missingAPIKey
    case apiError(String)
}

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: "FRED_API_KEY")
        }
    }

    init() {
        self.apiKey = UserDefaults.standard.string(forKey: "FRED_API_KEY") ?? ""
    }
}

class FREDService {
    static let shared = FREDService()
    private let baseURL = "https://api.stlouisfed.org/fred"

    private var apiKey: String {
        SettingsManager.shared.apiKey
    }

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    func searchSeries(query: String) async throws -> [FREDSeries] {
        guard !apiKey.isEmpty else { throw FREDError.missingAPIKey }

        // Construct URL
        // Example: https://api.stlouisfed.org/fred/series/search?search_text=gdp&api_key=abcdef&file_type=json

        guard var components = URLComponents(string: "\(baseURL)/series/search") else {
            throw FREDError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "search_text", value: query),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "file_type", value: "json")
        ]

        guard let url = components.url else {
            throw FREDError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, 200...299 ~= httpResponse.statusCode else {
            throw FREDError.apiError("Server returned error")
        }

        do {
            let result = try jsonDecoder.decode(FREDSearchResponse.self, from: data)
            return result.series
        } catch {
            print("Decoding error: \(error)")
            throw FREDError.decodingError(error)
        }
    }

    func getObservations(seriesId: String) async throws -> [FREDObservation] {
        guard !apiKey.isEmpty else { throw FREDError.missingAPIKey }

        guard var components = URLComponents(string: "\(baseURL)/series/observations") else {
            throw FREDError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "series_id", value: seriesId),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "file_type", value: "json")
        ]

        guard let url = components.url else {
            throw FREDError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, 200...299 ~= httpResponse.statusCode else {
            throw FREDError.apiError("Server returned error")
        }

        do {
            let result = try jsonDecoder.decode(FREDObservationsResponse.self, from: data)
            return result.observations
        } catch {
             print("Decoding error: \(error)")
            throw FREDError.decodingError(error)
        }
    }

    // Fetch multiple series observations concurrently
    func getMultipleSeriesObservations(seriesIds: [String]) async throws -> [String: [FREDObservation]] {
        return try await withThrowingTaskGroup(of: (String, [FREDObservation]).self) { group in
            for id in seriesIds {
                group.addTask {
                    let obs = try await self.getObservations(seriesId: id)
                    return (id, obs)
                }
            }

            var results: [String: [FREDObservation]] = [:]
            for try await (id, obs) in group {
                results[id] = obs
            }
            return results
        }
    }
}
