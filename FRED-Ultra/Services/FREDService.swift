import Foundation
import SwiftUI

// MARK: - Error Types
enum FREDError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case missingAPIKey
    case apiError(String)
    case noData
    case rateLimited
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL configuration"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to parse response: \(error.localizedDescription)"
        case .missingAPIKey:
            return "API key is missing. Please add your FRED API key in Settings."
        case .apiError(let message):
            return "API error: \(message)"
        case .noData:
            return "No data available for this series"
        case .rateLimited:
            return "Rate limited. Please wait a moment and try again."
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .missingAPIKey:
            return "Get a free API key at https://fred.stlouisfed.org/docs/api/api_key.html"
        case .rateLimited:
            return "FRED API allows 120 requests per minute"
        default:
            return nil
        }
    }
}

// MARK: - Settings Manager
@MainActor
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: "FRED_API_KEY")
        }
    }
    
    @Published var favorites: [FavoriteSeries] = [] {
        didSet {
            saveFavorites()
        }
    }
    
    @Published var recentSearches: [String] = [] {
        didSet {
            UserDefaults.standard.set(recentSearches, forKey: "FRED_RECENT_SEARCHES")
        }
    }

    private init() {
        self.apiKey = UserDefaults.standard.string(forKey: "FRED_API_KEY") ?? ""
        self.recentSearches = UserDefaults.standard.stringArray(forKey: "FRED_RECENT_SEARCHES") ?? []
        loadFavorites()
    }
    
    private func loadFavorites() {
        if let data = UserDefaults.standard.data(forKey: "FRED_FAVORITES"),
           let decoded = try? JSONDecoder().decode([FavoriteSeries].self, from: data) {
            self.favorites = decoded
        }
    }
    
    private func saveFavorites() {
        if let encoded = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(encoded, forKey: "FRED_FAVORITES")
        }
    }
    
    func addFavorite(_ series: FREDSeries) {
        guard !isFavorite(series) else { return }
        favorites.append(FavoriteSeries(from: series))
    }
    
    func removeFavorite(_ series: FREDSeries) {
        favorites.removeAll { $0.id == series.id }
    }
    
    func removeFavorite(_ favorite: FavoriteSeries) {
        favorites.removeAll { $0.id == favorite.id }
    }
    
    func isFavorite(_ series: FREDSeries) -> Bool {
        favorites.contains { $0.id == series.id }
    }
    
    func addRecentSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        recentSearches.removeAll { $0.lowercased() == trimmed.lowercased() }
        recentSearches.insert(trimmed, at: 0)
        if recentSearches.count > 10 {
            recentSearches = Array(recentSearches.prefix(10))
        }
    }
    
    func clearRecentSearches() {
        recentSearches.removeAll()
    }
    
    var hasValidAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - FRED API Service
actor FREDService {
    static let shared = FREDService()
    private let baseURL = "https://api.stlouisfed.org/fred"
    
    private var apiKey: String {
        get async {
            await MainActor.run { SettingsManager.shared.apiKey }
        }
    }

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
    
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    func searchSeries(query: String, limit: Int = 100) async throws -> [FREDSeries] {
        let key = await apiKey
        guard !key.isEmpty else { throw FREDError.missingAPIKey }

        guard var components = URLComponents(string: "\(baseURL)/series/search") else {
            throw FREDError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "search_text", value: query),
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "file_type", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "order_by", value: "popularity"),
            URLQueryItem(name: "sort_order", value: "desc")
        ]

        guard let url = components.url else {
            throw FREDError.invalidURL
        }

        do {
            let (data, response) = try await session.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw FREDError.apiError("Invalid response")
            }
            
            switch httpResponse.statusCode {
            case 200...299:
                break
            case 429:
                throw FREDError.rateLimited
            case 400...499:
                throw FREDError.apiError("Client error: \(httpResponse.statusCode)")
            case 500...599:
                throw FREDError.apiError("Server error: \(httpResponse.statusCode)")
            default:
                throw FREDError.apiError("Unexpected status: \(httpResponse.statusCode)")
            }

            let result = try jsonDecoder.decode(FREDSearchResponse.self, from: data)
            return result.series
        } catch let error as FREDError {
            throw error
        } catch let error as DecodingError {
            throw FREDError.decodingError(error)
        } catch {
            throw FREDError.networkError(error)
        }
    }

    func getObservations(seriesId: String, startDate: Date? = nil, endDate: Date? = nil) async throws -> [FREDObservation] {
        let key = await apiKey
        guard !key.isEmpty else { throw FREDError.missingAPIKey }

        guard var components = URLComponents(string: "\(baseURL)/series/observations") else {
            throw FREDError.invalidURL
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var queryItems = [
            URLQueryItem(name: "series_id", value: seriesId),
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "file_type", value: "json"),
            URLQueryItem(name: "sort_order", value: "asc")
        ]
        
        if let start = startDate {
            queryItems.append(URLQueryItem(name: "observation_start", value: dateFormatter.string(from: start)))
        }
        
        if let end = endDate {
            queryItems.append(URLQueryItem(name: "observation_end", value: dateFormatter.string(from: end)))
        }
        
        components.queryItems = queryItems

        guard let url = components.url else {
            throw FREDError.invalidURL
        }

        do {
            let (data, response) = try await session.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw FREDError.apiError("Invalid response")
            }
            
            switch httpResponse.statusCode {
            case 200...299:
                break
            case 429:
                throw FREDError.rateLimited
            case 400...499:
                throw FREDError.apiError("Client error: \(httpResponse.statusCode)")
            case 500...599:
                throw FREDError.apiError("Server error: \(httpResponse.statusCode)")
            default:
                throw FREDError.apiError("Unexpected status: \(httpResponse.statusCode)")
            }

            let result = try jsonDecoder.decode(FREDObservationsResponse.self, from: data)
            return result.observations.filter { $0.isValidValue }
        } catch let error as FREDError {
            throw error
        } catch let error as DecodingError {
            throw FREDError.decodingError(error)
        } catch {
            throw FREDError.networkError(error)
        }
    }

    func getMultipleSeriesObservations(seriesIds: [String], startDate: Date? = nil) async throws -> [String: [FREDObservation]] {
        try await withThrowingTaskGroup(of: (String, [FREDObservation]).self) { group in
            for id in seriesIds {
                group.addTask {
                    let obs = try await self.getObservations(seriesId: id, startDate: startDate)
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
    
    func getSeriesInfo(seriesId: String) async throws -> FREDSeries {
        let key = await apiKey
        guard !key.isEmpty else { throw FREDError.missingAPIKey }

        guard var components = URLComponents(string: "\(baseURL)/series") else {
            throw FREDError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "series_id", value: seriesId),
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "file_type", value: "json")
        ]

        guard let url = components.url else {
            throw FREDError.invalidURL
        }

        do {
            let (data, response) = try await session.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse, 200...299 ~= httpResponse.statusCode else {
                throw FREDError.apiError("Server returned error")
            }

            let result = try jsonDecoder.decode(FREDSearchResponse.self, from: data)
            guard let series = result.series.first else {
                throw FREDError.noData
            }
            return series
        } catch let error as FREDError {
            throw error
        } catch let error as DecodingError {
            throw FREDError.decodingError(error)
        } catch {
            throw FREDError.networkError(error)
        }
    }
}

// MARK: - Export Service
struct ExportService {
    static func exportToCSV(series: FREDSeries, observations: [FREDObservation]) -> String {
        var csv = "Date,Value\n"
        csv += "# Series: \(series.title)\n"
        csv += "# ID: \(series.id)\n"
        csv += "# Units: \(series.units)\n"
        csv += "# Frequency: \(series.frequency)\n"
        csv += "# Source: Federal Reserve Economic Data (FRED)\n"
        csv += "\n"
        
        for obs in observations {
            let escapedValue = obs.value.replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\(obs.date),\"\(escapedValue)\"\n"
        }
        
        return csv
    }
    
    static func exportToJSON(series: FREDSeries, observations: [FREDObservation]) -> String {
        let export: [String: Any] = [
            "series": [
                "id": series.id,
                "title": series.title,
                "units": series.units,
                "frequency": series.frequency,
                "observation_start": series.observationStart,
                "observation_end": series.observationEnd,
                "last_updated": series.lastUpdated
            ],
            "observations": observations.map { ["date": $0.date, "value": $0.value] },
            "metadata": [
                "exported_at": ISO8601DateFormatter().string(from: Date()),
                "source": "Federal Reserve Economic Data (FRED)"
            ]
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: export, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{}"
    }
    
    @MainActor
    static func saveFile(content: String, filename: String, format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .csv ? [.commaSeparatedText] : [.json]
        panel.nameFieldStringValue = "\(filename).\(format.fileExtension)"
        panel.canCreateDirectories = true
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    print("Export error: \(error)")
                }
            }
        }
    }
}
