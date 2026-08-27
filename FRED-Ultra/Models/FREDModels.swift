import Foundation

// MARK: - Shared Date Handling

/// FRED serialises observation dates as `yyyy-MM-dd` with no time component.
///
/// Everything in the app parses *and* displays those dates in the same calendar
/// (`Calendar.current`), so a date never drifts to the neighbouring day when a chart
/// axis, a table cell, and a filter each render it.
enum FREDDate {
    /// `DateFormatter` is documented as thread-safe on macOS 10.9+ and is `Sendable`,
    /// so these are shared rather than reallocated per observation.
    private static let storageFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func date(from string: String) -> Date? {
        storageFormatter.date(from: string)
    }

    static func string(from date: Date) -> String {
        storageFormatter.string(from: date)
    }

    static func displayString(from date: Date) -> String {
        displayFormatter.string(from: date)
    }
}

// MARK: - Search Response

struct FREDSearchResponse: Codable, Sendable {
    let count: Int?
    let offset: Int?
    let limit: Int?
    let series: [FREDSeries]

    enum CodingKeys: String, CodingKey {
        case count, offset, limit
        case series = "seriess"
    }
}

// MARK: - Series

/// Metadata for one FRED series.
///
/// Decoding is deliberately forgiving: FRED occasionally omits optional descriptive
/// fields on less-curated series, and a single missing key must not discard an entire
/// page of search results.
struct FREDSeries: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let observationStart: String
    let observationEnd: String
    let frequency: String
    let frequencyShort: String?
    let units: String
    let unitsShort: String?
    let seasonalAdjustment: String
    let seasonalAdjustmentShort: String?
    let lastUpdated: String
    let popularity: Int?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case observationStart = "observation_start"
        case observationEnd = "observation_end"
        case frequency
        case frequencyShort = "frequency_short"
        case units
        case unitsShort = "units_short"
        case seasonalAdjustment = "seasonal_adjustment"
        case seasonalAdjustmentShort = "seasonal_adjustment_short"
        case lastUpdated = "last_updated"
        case popularity
        case notes
    }

    init(
        id: String,
        title: String,
        observationStart: String,
        observationEnd: String,
        frequency: String,
        frequencyShort: String? = nil,
        units: String,
        unitsShort: String? = nil,
        seasonalAdjustment: String,
        seasonalAdjustmentShort: String? = nil,
        lastUpdated: String,
        popularity: Int? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.observationStart = observationStart
        self.observationEnd = observationEnd
        self.frequency = frequency
        self.frequencyShort = frequencyShort
        self.units = units
        self.unitsShort = unitsShort
        self.seasonalAdjustment = seasonalAdjustment
        self.seasonalAdjustmentShort = seasonalAdjustmentShort
        self.lastUpdated = lastUpdated
        self.popularity = popularity
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        observationStart = try container.decodeIfPresent(String.self, forKey: .observationStart) ?? ""
        observationEnd = try container.decodeIfPresent(String.self, forKey: .observationEnd) ?? ""
        frequency = try container.decodeIfPresent(String.self, forKey: .frequency) ?? "Unknown"
        frequencyShort = try container.decodeIfPresent(String.self, forKey: .frequencyShort)
        units = try container.decodeIfPresent(String.self, forKey: .units) ?? ""
        unitsShort = try container.decodeIfPresent(String.self, forKey: .unitsShort)
        seasonalAdjustment = try container.decodeIfPresent(String.self, forKey: .seasonalAdjustment) ?? "Not Applicable"
        seasonalAdjustmentShort = try container.decodeIfPresent(String.self, forKey: .seasonalAdjustmentShort)
        lastUpdated = try container.decodeIfPresent(String.self, forKey: .lastUpdated) ?? ""
        popularity = try container.decodeIfPresent(Int.self, forKey: .popularity)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    var formattedDateRange: String {
        guard !observationStart.isEmpty, !observationEnd.isEmpty else { return "Unknown coverage" }
        return "\(observationStart) to \(observationEnd)"
    }

    var subtitleLine: String {
        let unitText = units.isEmpty ? "Units n/a" : units
        return "\(frequency) • \(unitText)"
    }

    var unitDescriptor: UnitDescriptor {
        .cached(units: units)
    }

    var seriesFrequency: SeriesFrequency {
        SeriesFrequency.parse(short: frequencyShort, long: frequency)
    }

    /// Notes trimmed to a single sidebar-friendly paragraph.
    var shortNotes: String? {
        guard let notes else { return nil }

        let collapsed = notes
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > 180 else { return collapsed }

        return String(collapsed.prefix(177)) + "…"
    }
}

// MARK: - Observations Response

struct FREDObservationsResponse: Codable, Sendable {
    let count: Int?
    let offset: Int?
    let limit: Int?
    let observations: [FREDObservation]
}

// MARK: - Observation

/// A raw FRED observation. `value` stays a `String` because FRED encodes missing
/// readings as `"."`, which is not representable as a number.
struct FREDObservation: Codable, Identifiable, Hashable, Sendable {
    var id: String { date }

    let date: String
    let value: String

    init(date: String, value: String) {
        self.date = date
        self.value = value
    }

    var doubleValue: Double? {
        Double(value)
    }

    var isValidValue: Bool {
        guard let doubleValue else { return false }
        return doubleValue.isFinite
    }

    var dateObject: Date? {
        FREDDate.date(from: date)
    }

    var formattedDate: String {
        guard let dateObject else { return date }
        return FREDDate.displayString(from: dateObject)
    }

    /// Parsed representation, or `nil` when the observation is missing or malformed.
    var dataPoint: SeriesDataPoint? {
        guard let dateObject, let doubleValue, doubleValue.isFinite else { return nil }
        return SeriesDataPoint(date: dateObject, value: doubleValue)
    }
}

// MARK: - Parsed Observation

/// Fully parsed observation used by every analytics and charting path.
///
/// Parsing once, at the service boundary, keeps date parsing and `Double` conversion
/// out of view-update hot paths.
struct SeriesDataPoint: Hashable, Sendable {
    let date: Date
    let value: Double

    init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

extension Array where Element == FREDObservation {
    /// Parsed, chronologically sorted points with missing readings dropped.
    func parsedDataPoints() -> [SeriesDataPoint] {
        compactMap(\.dataPoint).sorted { $0.date < $1.date }
    }
}

// MARK: - Frequency

/// Reporting cadence of a series, used to size moving-average windows and to explain
/// what "one period" means in period-over-period transforms.
enum SeriesFrequency: String, Sendable, Equatable, CaseIterable {
    case daily
    case weekly
    case biweekly
    case monthly
    case quarterly
    case semiannual
    case annual
    case unknown

    static func parse(short: String?, long: String) -> SeriesFrequency {
        let shortCode = short?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""

        switch shortCode {
        case "D": return .daily
        case "W": return .weekly
        case "BW": return .biweekly
        case "M": return .monthly
        case "Q": return .quarterly
        case "SA": return .semiannual
        case "A": return .annual
        default: break
        }

        let normalized = long.lowercased()
        if normalized.contains("daily") { return .daily }
        if normalized.contains("biweekly") || normalized.contains("bi-weekly") { return .biweekly }
        if normalized.contains("weekly") { return .weekly }
        if normalized.contains("monthly") { return .monthly }
        if normalized.contains("quarterly") { return .quarterly }
        if normalized.contains("semiannual") || normalized.contains("semi-annual") { return .semiannual }
        if normalized.contains("annual") || normalized.contains("yearly") { return .annual }
        return .unknown
    }

    /// Approximate observations per calendar year. `nil` when the cadence is unknown.
    var periodsPerYear: Int? {
        switch self {
        case .daily: return 252
        case .weekly: return 52
        case .biweekly: return 26
        case .monthly: return 12
        case .quarterly: return 4
        case .semiannual: return 2
        case .annual: return 1
        case .unknown: return nil
        }
    }

    var periodNoun: String {
        switch self {
        case .daily: return "day"
        case .weekly: return "week"
        case .biweekly: return "two weeks"
        case .monthly: return "month"
        case .quarterly: return "quarter"
        case .semiannual: return "half-year"
        case .annual: return "year"
        case .unknown: return "period"
        }
    }
}

// MARK: - Favorites

struct FavoriteSeries: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let units: String
    let frequency: String
    let addedDate: Date

    init(id: String, title: String, units: String, frequency: String, addedDate: Date = Date()) {
        self.id = id
        self.title = title
        self.units = units
        self.frequency = frequency
        self.addedDate = addedDate
    }

    init(from series: FREDSeries, addedDate: Date = Date()) {
        self.init(
            id: series.id,
            title: series.title,
            units: series.units,
            frequency: series.frequency,
            addedDate: addedDate
        )
    }
}
