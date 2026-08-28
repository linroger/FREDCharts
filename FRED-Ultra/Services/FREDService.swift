import Foundation

// MARK: - Errors

enum FREDError: LocalizedError, Equatable {
    case invalidURL
    case networkError(String)
    case decodingError(String)
    case missingAPIKey
    case apiError(String)
    case noData
    case rateLimited
    case cancelled

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
        case .cancelled:
            return "The request was cancelled."
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
        case .networkError:
            return "Confirm you are online, then try again."
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

// MARK: - Load Result

/// Outcome of loading one series. Comparison charts must survive a single bad series,
/// so failures are reported per series rather than thrown for the whole batch.
struct SeriesLoadResult: Sendable {
    let seriesId: String
    let points: [SeriesDataPoint]
    let failureMessage: String?

    var succeeded: Bool { failureMessage == nil }
}

// MARK: - FRED API Service

actor FREDService {
    static let shared = FREDService()

    /// Full history is fetched once per series and windowed locally. FRED returns up to
    /// 100,000 observations per request, which covers every series it publishes — the
    /// longest daily series is under 17,000 rows.
    static let observationRequestLimit = 100_000

    /// NBER-based recession indicator used for chart shading, matching the bands FRED
    /// draws on its own charts. Monthly, 1 during a recession and 0 otherwise.
    static let recessionIndicatorSeriesID = "USREC"

    private let baseURL = URL(string: "https://api.stlouisfed.org/fred")!
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let cacheLifetime: TimeInterval
    private let maximumAttempts: Int

    private struct CacheEntry {
        let fetchedAt: Date
        let points: [SeriesDataPoint]
    }

    private var observationCache: [String: CacheEntry] = [:]
    private var seriesInfoCache: [String: FREDSeries] = [:]
    private var relationsCache: [String: SeriesRelations] = [:]

    init(
        session: URLSession? = nil,
        cacheLifetime: TimeInterval = 15 * 60,
        maximumAttempts: Int = 3
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }

        self.cacheLifetime = cacheLifetime
        self.maximumAttempts = Swift.max(1, maximumAttempts)
    }

    // MARK: Public API

    func validateAPIKey(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FREDError.missingAPIKey }

        _ = try await searchSeries(query: "GDP", limit: 1, apiKeyOverride: trimmed)
    }

    func searchSeries(query: String, limit: Int = 50, apiKeyOverride: String? = nil) async throws -> [FREDSeries] {
        let key = try await resolvedAPIKey(override: apiKeyOverride)
        let url = try makeURL(
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

        AppLogger.search.info("Searching FRED for '\(query, privacy: .public)'")
        let response: FREDSearchResponse = try await request(url)
        var series = SearchQuery.promotingExactMatch(in: response.series, for: query)

        // Popularity ranking can omit an exact identifier entirely — searching a niche
        // series ID returns better-known relatives instead. Look it up directly and pin
        // it to the top. A failure here is not a search failure.
        if apiKeyOverride == nil,
           SearchQuery.looksLikeSeriesID(query),
           !series.contains(where: { $0.id.caseInsensitiveCompare(query) == .orderedSame }) {
            if let exact = try? await getSeriesInfo(seriesId: query.trimmingCharacters(in: .whitespacesAndNewlines)) {
                series.insert(exact, at: 0)
            }
        }

        return series
    }

    func getSeriesInfo(seriesId: String) async throws -> FREDSeries {
        if let cached = seriesInfoCache[seriesId] {
            return cached
        }

        let key = try await resolvedAPIKey()
        let url = try makeURL(
            path: "series",
            queryItems: [
                URLQueryItem(name: "series_id", value: seriesId),
                URLQueryItem(name: "api_key", value: key),
                URLQueryItem(name: "file_type", value: "json")
            ]
        )

        let response: FREDSearchResponse = try await request(url)
        guard let series = response.series.first else { throw FREDError.noData }

        seriesInfoCache[seriesId] = series
        return series
    }

    /// Full observation history for one series, memoised for `cacheLifetime`.
    func observations(seriesId: String, forceRefresh: Bool = false) async throws -> [SeriesDataPoint] {
        if !forceRefresh,
           let cached = observationCache[seriesId],
           Date().timeIntervalSince(cached.fetchedAt) < cacheLifetime {
            return cached.points
        }

        let key = try await resolvedAPIKey()
        let url = try makeURL(
            path: "series/observations",
            queryItems: [
                URLQueryItem(name: "series_id", value: seriesId),
                URLQueryItem(name: "api_key", value: key),
                URLQueryItem(name: "file_type", value: "json"),
                URLQueryItem(name: "sort_order", value: "asc"),
                URLQueryItem(name: "limit", value: String(Self.observationRequestLimit))
            ]
        )

        let response: FREDObservationsResponse = try await request(url)
        let points = response.observations.parsedDataPoints()

        guard !points.isEmpty else { throw FREDError.noData }

        observationCache[seriesId] = CacheEntry(fetchedAt: Date(), points: points)
        AppLogger.network.info("Loaded \(points.count) observations for \(seriesId, privacy: .public)")
        return points
    }

    /// Loads several series concurrently, reporting per-series success or failure.
    func loadSeries(ids: [String], forceRefresh: Bool = false) async -> [SeriesLoadResult] {
        guard !ids.isEmpty else { return [] }

        return await withTaskGroup(of: SeriesLoadResult.self) { group in
            for seriesId in ids {
                group.addTask {
                    do {
                        let points = try await self.observations(seriesId: seriesId, forceRefresh: forceRefresh)
                        return SeriesLoadResult(seriesId: seriesId, points: points, failureMessage: nil)
                    } catch {
                        AppLogger.network.error(
                            "Failed to load \(seriesId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                        return SeriesLoadResult(seriesId: seriesId, points: [], failureMessage: error.localizedDescription)
                    }
                }
            }

            var results: [SeriesLoadResult] = []
            results.reserveCapacity(ids.count)
            for await result in group {
                results.append(result)
            }

            // Preserve caller ordering; task-group completion order is nondeterministic.
            let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.seriesId, $0) })
            return ids.compactMap { byId[$0] }
        }
    }

    /// Categories, release, tags, and sibling series for one series.
    ///
    /// Four requests, so the result is memoised for the lifetime of the process. Failures
    /// of the individual parts degrade rather than throw: a series with no category still
    /// reports its release, and a series with neither still reports its tags.
    func relations(for seriesId: String, relatedLimit: Int = 12) async throws -> SeriesRelations {
        if let cached = relationsCache[seriesId] {
            return cached
        }

        let key = try await resolvedAPIKey()

        async let categories = fetchCategories(seriesId: seriesId, key: key)
        async let release = fetchRelease(seriesId: seriesId, key: key)
        async let tags = fetchTags(seriesId: seriesId, key: key)

        let resolvedCategories = await categories
        let siblings: [FREDSeries]

        if let category = resolvedCategories.first {
            // One extra, because the series itself is almost always the most popular
            // member of its own category.
            siblings = await fetchCategorySeries(
                categoryId: category.id,
                key: key,
                limit: relatedLimit + 1
            ).filter { $0.id != seriesId }
        } else {
            siblings = []
        }

        let relations = SeriesRelations(
            seriesID: seriesId,
            categories: resolvedCategories,
            release: await release,
            tags: await tags,
            relatedSeries: Array(siblings.prefix(relatedLimit))
        )

        relationsCache[seriesId] = relations
        AppLogger.network.info(
            "Loaded relations for \(seriesId, privacy: .public): \(relations.relatedSeries.count) related series"
        )
        return relations
    }

    private func fetchCategories(seriesId: String, key: String) async -> [FREDCategory] {
        guard let url = try? makeURL(
            path: "series/categories",
            queryItems: [
                URLQueryItem(name: "series_id", value: seriesId),
                URLQueryItem(name: "api_key", value: key),
                URLQueryItem(name: "file_type", value: "json")
            ]
        ) else { return [] }

        let response: FREDCategoriesResponse? = try? await request(url)
        return response?.categories ?? []
    }

    private func fetchRelease(seriesId: String, key: String) async -> FREDRelease? {
        guard let url = try? makeURL(
            path: "series/release",
            queryItems: [
                URLQueryItem(name: "series_id", value: seriesId),
                URLQueryItem(name: "api_key", value: key),
                URLQueryItem(name: "file_type", value: "json")
            ]
        ) else { return nil }

        let response: FREDReleasesResponse? = try? await request(url)
        return response?.releases.first
    }

    private func fetchTags(seriesId: String, key: String) async -> [FREDTag] {
        guard let url = try? makeURL(
            path: "series/tags",
            queryItems: [
                URLQueryItem(name: "series_id", value: seriesId),
                URLQueryItem(name: "api_key", value: key),
                URLQueryItem(name: "file_type", value: "json")
            ]
        ) else { return [] }

        let response: FREDTagsResponse? = try? await request(url)
        return response?.tags ?? []
    }

    private func fetchCategorySeries(categoryId: Int, key: String, limit: Int) async -> [FREDSeries] {
        guard let url = try? makeURL(
            path: "category/series",
            queryItems: [
                URLQueryItem(name: "category_id", value: String(categoryId)),
                URLQueryItem(name: "api_key", value: key),
                URLQueryItem(name: "file_type", value: "json"),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "order_by", value: "popularity"),
                URLQueryItem(name: "sort_order", value: "desc")
            ]
        ) else { return [] }

        let response: FREDSearchResponse? = try? await request(url)
        return response?.series ?? []
    }

    func clearCaches() {
        observationCache.removeAll()
        seriesInfoCache.removeAll()
        relationsCache.removeAll()
        AppLogger.network.info("Cleared cached FRED responses")
    }

    var cachedSeriesCount: Int {
        observationCache.count
    }

    // MARK: Request plumbing

    private func resolvedAPIKey(override: String? = nil) async throws -> String {
        let source: String
        if let override {
            source = override
        } else {
            source = await MainActor.run { SettingsManager.shared.apiKey }
        }

        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FREDError.missingAPIKey }
        return trimmed
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw FREDError.invalidURL
        }

        components.queryItems = queryItems

        guard let url = components.url else { throw FREDError.invalidURL }
        return url
    }

    /// Performs a request with bounded retries for transient conditions.
    ///
    /// Retries cover 429 and 5xx responses plus timeouts and connection loss. Client
    /// errors (a bad API key, an unknown series) are permanent and fail immediately.
    private func request<T: Decodable>(_ url: URL) async throws -> T {
        var attempt = 1

        while true {
            try Task.checkCancellation()

            do {
                return try await performRequest(url)
            } catch let error as FREDError {
                guard attempt < maximumAttempts, Self.isRetryable(error) else { throw error }

                let delay = Self.retryDelay(forAttempt: attempt)
                AppLogger.network.info("Retrying FRED request in \(delay, format: .fixed(precision: 1))s (attempt \(attempt + 1))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            }
        }
    }

    private func performRequest<T: Decodable>(_ url: URL) async throws -> T {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(from: url)
        } catch is CancellationError {
            throw FREDError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw FREDError.cancelled
        } catch {
            throw FREDError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FREDError.apiError("FRED returned an invalid response.")
        }

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 429:
            throw FREDError.rateLimited
        default:
            if let envelope = try? decoder.decode(FREDAPIErrorEnvelope.self, from: data),
               let message = envelope.errorMessage, !message.isEmpty {
                throw FREDError.apiError(message)
            }
            throw FREDError.apiError("FRED returned HTTP \(httpResponse.statusCode).")
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw FREDError.decodingError(error.localizedDescription)
        }
    }

    private static func isRetryable(_ error: FREDError) -> Bool {
        switch error {
        case .rateLimited:
            return true
        case .networkError:
            return true
        case .apiError(let message):
            // Only server-side failures are worth repeating.
            return message.contains("HTTP 5")
        default:
            return false
        }
    }

    private static func retryDelay(forAttempt attempt: Int) -> Double {
        // 0.6s, 1.8s — well inside FRED's 120 requests-per-minute budget.
        0.6 * pow(3, Double(attempt - 1))
    }
}
