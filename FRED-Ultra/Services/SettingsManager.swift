import Foundation

/// Where the API key actually ended up. Surfaced in Settings so the user is never
/// misled about how their credential is stored.
enum APIKeyStorage: String, Sendable {
    case keychain = "Keychain"
    case userDefaults = "Preferences file"
    case none = "Not stored"

    var explanation: String {
        switch self {
        case .keychain:
            return "Stored in the macOS Keychain for this app."
        case .userDefaults:
            return "The Keychain was unavailable, so the key is stored in this app's preferences. Anything running as your user account can read it."
        case .none:
            return "No API key is saved yet."
        }
    }
}

/// Persisted user state: credential, favorites, and recent searches.
@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published private(set) var apiKey: String
    @Published private(set) var apiKeyStorage: APIKeyStorage
    @Published private(set) var favorites: [FavoriteSeries]
    @Published private(set) var recentSearches: [String]

    private let defaults: UserDefaults
    private let keychainAccount: String

    static let maximumRecentSearches = 12

    private enum Keys {
        static let apiKey = "FRED_API_KEY"
        static let favorites = "FRED_FAVORITES"
        static let recentSearches = "FRED_RECENT_SEARCHES"
    }

    /// `keychainAccount` is injectable so tests can run against an isolated credential
    /// entry instead of the user's real one.
    init(defaults: UserDefaults = .standard, keychainAccount: String = "FRED_API_KEY") {
        self.defaults = defaults
        self.keychainAccount = keychainAccount

        let legacyKey = defaults.string(forKey: Keys.apiKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedKey = ""
        var resolvedStorage = APIKeyStorage.none

        do {
            if let stored = try KeychainStore.string(account: keychainAccount), !stored.isEmpty {
                resolvedKey = stored
                resolvedStorage = .keychain
            }
        } catch {
            AppLogger.settings.error("Keychain read failed: \(error.localizedDescription, privacy: .public)")
        }

        if resolvedKey.isEmpty, let legacyKey, !legacyKey.isEmpty {
            resolvedKey = legacyKey
            resolvedStorage = .userDefaults
        }

        apiKey = resolvedKey
        apiKeyStorage = resolvedStorage
        recentSearches = defaults.stringArray(forKey: Keys.recentSearches) ?? []

        if let data = defaults.data(forKey: Keys.favorites),
           let decoded = try? JSONDecoder().decode([FavoriteSeries].self, from: data) {
            favorites = decoded
        } else {
            favorites = []
        }

        // One-time migration: move a preferences-stored key into the Keychain and drop
        // the plaintext copy. If the Keychain is unavailable the key keeps working from
        // preferences, and `apiKeyStorage` says so.
        if resolvedStorage == .userDefaults {
            migrateLegacyKeyToKeychain(resolvedKey)
        }
    }

    var hasValidAPIKey: Bool {
        !apiKey.isEmpty
    }

    // MARK: API key

    @discardableResult
    func updateAPIKey(_ newValue: String) -> APIKeyStorage {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = trimmed

        guard !trimmed.isEmpty else {
            clearStoredKey()
            return apiKeyStorage
        }

        do {
            try KeychainStore.set(trimmed, account: keychainAccount)
            defaults.removeObject(forKey: Keys.apiKey)
            apiKeyStorage = .keychain
        } catch {
            AppLogger.settings.error("Keychain write failed, falling back to preferences: \(error.localizedDescription, privacy: .public)")
            defaults.set(trimmed, forKey: Keys.apiKey)
            apiKeyStorage = .userDefaults
        }

        return apiKeyStorage
    }

    func clearAPIKey() {
        apiKey = ""
        clearStoredKey()
        AppLogger.settings.info("Cleared the stored FRED API key")
    }

    private func clearStoredKey() {
        try? KeychainStore.set(nil, account: keychainAccount)
        defaults.removeObject(forKey: Keys.apiKey)
        apiKeyStorage = .none
    }

    private func migrateLegacyKeyToKeychain(_ key: String) {
        do {
            try KeychainStore.set(key, account: keychainAccount)
            defaults.removeObject(forKey: Keys.apiKey)
            apiKeyStorage = .keychain
            AppLogger.settings.info("Migrated the stored API key from preferences into the Keychain")
        } catch {
            AppLogger.settings.error("Keychain migration failed, key remains in preferences: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Favorites

    func isFavorite(_ seriesId: String) -> Bool {
        favorites.contains { $0.id == seriesId }
    }

    func isFavorite(_ series: FREDSeries) -> Bool {
        isFavorite(series.id)
    }

    func addFavorite(_ series: FREDSeries) {
        guard !isFavorite(series.id) else { return }
        favorites.insert(FavoriteSeries(from: series), at: 0)
        persistFavorites()
        AppLogger.settings.info("Added favorite: \(series.id, privacy: .public)")
    }

    func removeFavorite(id seriesId: String) {
        guard favorites.contains(where: { $0.id == seriesId }) else { return }
        favorites.removeAll { $0.id == seriesId }
        persistFavorites()
        AppLogger.settings.info("Removed favorite: \(seriesId, privacy: .public)")
    }

    func removeFavorite(_ series: FREDSeries) {
        removeFavorite(id: series.id)
    }

    func removeFavorite(_ favorite: FavoriteSeries) {
        removeFavorite(id: favorite.id)
    }

    func toggleFavorite(_ series: FREDSeries) {
        if isFavorite(series.id) {
            removeFavorite(id: series.id)
        } else {
            addFavorite(series)
        }
    }

    func clearFavorites() {
        guard !favorites.isEmpty else { return }
        favorites.removeAll()
        persistFavorites()
        AppLogger.settings.info("Cleared all favorites")
    }

    private func persistFavorites() {
        guard let encoded = try? JSONEncoder().encode(favorites) else {
            AppLogger.settings.error("Failed to encode favorites for persistence")
            return
        }
        defaults.set(encoded, forKey: Keys.favorites)
    }

    // MARK: Recent searches

    func addRecentSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var updated = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        updated.insert(trimmed, at: 0)
        recentSearches = Array(updated.prefix(Self.maximumRecentSearches))
        defaults.set(recentSearches, forKey: Keys.recentSearches)
    }

    func clearRecentSearches() {
        guard !recentSearches.isEmpty else { return }
        recentSearches.removeAll()
        defaults.set(recentSearches, forKey: Keys.recentSearches)
        AppLogger.settings.info("Cleared recent searches")
    }
}
