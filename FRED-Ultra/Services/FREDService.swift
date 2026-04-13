import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Error Types

enum FREDError: LocalizedError, Equatable {
    case invalidURL
    case networkError(String)
    case decodingError(String)
    case missingAPIKey
    case apiError(String)
    case noData
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The app could not create a valid FRED request URL."
        case .networkError(let message):
            return "Network error: \(message)"
        case .decodingError(let message):
            return "The FRED response could not be parsed: \(message)"
        case .missingAPIKey:
            return "A FRED API key is required. Add one in Settings to continue."
        case .apiError(let message):
            return message
        case .noData:
            return "No observations were returned for this series."
        case .rateLimited:
            return "Rate limited by the FRED API. Please wait a moment and try again."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .missingAPIKey:
            return "Get a free API key at https://fred.stlouisfed.org/docs/api/api_key.html"
        case .rateLimited:
            return "FRED allows up to 120 requests per minute per API key."
        case .apiError:
            return "Check your API key, series ID, and network connection, then try again."
        default:
            return nil
        }
    }
}

private struct FREDAPIErrorEnvelope: Decodable {
    let errorCode: Int?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}

// MARK: - Settings Manager

@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: Keys.apiKey)
        }
    }

    @Published var favorites: [FavoriteSeries] = [] {
        didSet {
            saveFavorites()
        }
    }

    @Published var recentSearches: [String] = [] {
        didSet {
            UserDefaults.standard.set(recentSearches, forKey: Keys.recentSearches)
        }
    }

    private enum Keys {
        static let apiKey = "FRED_API_KEY"
        static let favorites = "FRED_FAVORITES"
        static let recentSearches = "FRED_RECENT_SEARCHES"
    }

    private init() {
        apiKey = UserDefaults.standard.string(forKey: Keys.apiKey) ?? ""
        recentSearches = UserDefaults.standard.stringArray(forKey: Keys.recentSearches) ?? []
        loadFavorites()
    }

    var hasValidAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func updateAPIKey(_ newValue: String) {
        apiKey = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func addFavorite(_ series: FREDSeries) {
        guard !isFavorite(series) else { return }
        favorites.insert(FavoriteSeries(from: series), at: 0)
        AppLogger.settings.info("Added favorite: \(series.id, privacy: .public)")
    }

    func removeFavorite(_ series: FREDSeries) {
        favorites.removeAll { $0.id == series.id }
        AppLogger.settings.info("Removed favorite: \(series.id, privacy: .public)")
    }

    func removeFavorite(_ favorite: FavoriteSeries) {
        favorites.removeAll { $0.id == favorite.id }
        AppLogger.settings.info("Removed favorite: \(favorite.id, privacy: .public)")
    }

    func isFavorite(_ series: FREDSeries) -> Bool {
        favorites.contains(where: { $0.id == series.id })
    }

    func addRecentSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        recentSearches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentSearches.insert(trimmed, at: 0)
        recentSearches = Array(recentSearches.prefix(12))
    }

    func clearRecentSearches() {
        recentSearches.removeAll()
        AppLogger.settings.info("Cleared recent searches")
    }

    private func loadFavorites() {
        guard let data = UserDefaults.standard.data(forKey: Keys.favorites) else { return }
        favorites = (try? JSONDecoder().decode([FavoriteSeries].self, from: data)) ?? []
    }

    private func saveFavorites() {
        guard let encoded = try? JSONEncoder().encode(favorites) else { return }
        UserDefaults.standard.set(encoded, forKey: Keys.favorites)
    }
}

// MARK: - FRED API Service

actor FREDService {
    static let shared = FREDService()

    private let baseURL = URL(string: "https://api.stlouisfed.org/fred")!

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    private let decoder = JSONDecoder()

    private var apiKey: String {
        get async {
            await MainActor.run { SettingsManager.shared.apiKey }
        }
    }

    func validateAPIKey(_ key: String) async throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw FREDError.missingAPIKey }

        _ = try await searchSeries(query: "GDP", limit: 1, apiKeyOverride: trimmedKey)
    }

    func searchSeries(query: String, limit: Int = 40, apiKeyOverride: String? = nil) async throws -> [FREDSeries] {
        let key = try await resolvedAPIKey(override: apiKeyOverride)
        let requestURL = try makeURL(
            path: "series/search",
            queryItems: [
                URLQueryItem(name: "search_text", value: query),
                URLQueryItem(name: "api_key", value: key),
                URLQueryItem(name: "file_type", value: "json"),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "order_by", value: "popularity"),
                URLQueryItem(name: "sort_order", value: "desc")
            ]
        )

        AppLogger.search.info("Searching FRED for query '\(query, privacy: .public)'")
        let response: FREDSearchResponse = try await request(requestURL)
        return response.series
    }

    func getSeriesInfo(seriesId: String) async throws -> FREDSeries {
        let key = try await resolvedAPIKey()
        let requestURL = try makeURL(
            path: "series",
            queryItems: [
                URLQueryItem(name: "series_id", value: seriesId),
                URLQueryItem(name: "api_key", value: key),
                URLQueryItem(name: "file_type", value: "json")
            ]
        )

        let response: FREDSearchResponse = try await request(requestURL)

        guard let first = response.series.first else {
            throw FREDError.noData
        }

        return first
    }

    func getObservations(seriesId: String, startDate: Date? = nil, endDate: Date? = nil) async throws -> [FREDObservation] {
        let key = try await resolvedAPIKey()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var queryItems = [
            URLQueryItem(name: "series_id", value: seriesId),
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "file_type", value: "json"),
            URLQueryItem(name: "sort_order", value: "asc")
        ]

        if let startDate {
            queryItems.append(URLQueryItem(name: "observation_start", value: formatter.string(from: startDate)))
        }

        if let endDate {
            queryItems.append(URLQueryItem(name: "observation_end", value: formatter.string(from: endDate)))
        }

        let requestURL = try makeURL(path: "series/observations", queryItems: queryItems)
        let response: FREDObservationsResponse = try await request(requestURL)
        let observations = response.observations.filter(\.isValidValue)

        if observations.isEmpty {
            throw FREDError.noData
        }

        return observations
    }

    func getMultipleSeriesObservations(
        seriesIds: [String],
        startDate: Date? = nil,
        endDate: Date? = nil
    ) async throws -> [String: [FREDObservation]] {
        try await withThrowingTaskGroup(of: (String, [FREDObservation]).self) { group in
            for seriesId in seriesIds {
                group.addTask {
                    let observations = try await self.getObservations(
                        seriesId: seriesId,
                        startDate: startDate,
                        endDate: endDate
                    )
                    return (seriesId, observations)
                }
            }

            var results: [String: [FREDObservation]] = [:]
            for try await (seriesId, observations) in group {
                results[seriesId] = observations
            }
            return results
        }
    }

    private func resolvedAPIKey(override: String? = nil) async throws -> String {
        let sourceValue: String
        if let override {
            sourceValue = override
        } else {
            sourceValue = await apiKey
        }

        let value = sourceValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw FREDError.missingAPIKey }
        return value
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw FREDError.invalidURL
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw FREDError.invalidURL
        }

        return url
    }

    private func request<T: Decodable>(_ url: URL) async throws -> T {
        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw FREDError.apiError("FRED returned an invalid response.")
            }

            switch httpResponse.statusCode {
            case 200 ... 299:
                break
            case 429:
                throw FREDError.rateLimited
            default:
                if let envelope = try? decoder.decode(FREDAPIErrorEnvelope.self, from: data),
                   let errorMessage = envelope.errorMessage {
                    throw FREDError.apiError(errorMessage)
                }

                throw FREDError.apiError("FRED returned HTTP \(httpResponse.statusCode).")
            }

            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw FREDError.decodingError(error.localizedDescription)
            }
        } catch let error as FREDError {
            throw error
        } catch {
            throw FREDError.networkError(error.localizedDescription)
        }
    }
}

// MARK: - Export Service

struct ExportService {
    static func exportToCSV(series: FREDSeries, observations: [FREDObservation]) -> String {
        var csv = [
            "# Series: \(series.title)",
            "# ID: \(series.id)",
            "# Units: \(series.units)",
            "# Frequency: \(series.frequency)",
            "# Exported: \(ISO8601DateFormatter().string(from: Date()))",
            "Date,Value"
        ].joined(separator: "\n")

        observations.forEach { observation in
            let escapedValue = observation.value.replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\n\(observation.date),\"\(escapedValue)\""
        }

        return csv
    }

    static func exportToJSON(series: FREDSeries, observations: [FREDObservation]) -> String {
        let payload: [String: Any] = [
            "series": [
                "id": series.id,
                "title": series.title,
                "units": series.units,
                "frequency": series.frequency,
                "observation_start": series.observationStart,
                "observation_end": series.observationEnd,
                "last_updated": series.lastUpdated
            ],
            "observations": observations.map {
                [
                    "date": $0.date,
                    "value": $0.value
                ]
            },
            "metadata": [
                "exported_at": ISO8601DateFormatter().string(from: Date()),
                "source": "Federal Reserve Economic Data (FRED)"
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return string
    }

    @MainActor
    static func saveFile(content: String, filename: String, format: ExportFormat) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(filename).\(format.fileExtension)"

        switch format {
        case .csv:
            panel.allowedContentTypes = [UTType.commaSeparatedText]
        case .json:
            panel.allowedContentTypes = [UTType.json]
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                AppLogger.export.info("Saved export to \(url.path(percentEncoded: false), privacy: .public)")
            } catch {
                AppLogger.export.error("Failed to save export: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
