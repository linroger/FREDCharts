import Foundation

// MARK: - Search Response

struct FREDSearchResponse: Codable {
    let realtimeStart: String?
    let realtimeEnd: String?
    let orderBy: String?
    let sortOrder: String?
    let count: Int?
    let offset: Int?
    let limit: Int?
    let series: [FREDSeries]

    enum CodingKeys: String, CodingKey {
        case realtimeStart = "realtime_start"
        case realtimeEnd = "realtime_end"
        case orderBy = "order_by"
        case sortOrder = "sort_order"
        case count, offset, limit
        case series = "seriess"
    }
}

// MARK: - Series

struct FREDSeries: Codable, Identifiable, Hashable {
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

    var formattedDateRange: String {
        "\(observationStart) to \(observationEnd)"
    }

    var subtitleLine: String {
        "\(frequency) • \(units)"
    }

    var shortNotes: String? {
        guard let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if notes.count <= 180 {
            return notes
        }

        return String(notes.prefix(177)) + "..."
    }
}

// MARK: - Observations Response

struct FREDObservationsResponse: Codable {
    let realtimeStart: String?
    let realtimeEnd: String?
    let observationStart: String?
    let observationEnd: String?
    let units: String?
    let outputType: Int?
    let fileType: String?
    let orderBy: String?
    let sortOrder: String?
    let count: Int?
    let offset: Int?
    let limit: Int?
    let observations: [FREDObservation]

    enum CodingKeys: String, CodingKey {
        case realtimeStart = "realtime_start"
        case realtimeEnd = "realtime_end"
        case observationStart = "observation_start"
        case observationEnd = "observation_end"
        case units
        case outputType = "output_type"
        case fileType = "file_type"
        case orderBy = "order_by"
        case sortOrder = "sort_order"
        case count, offset, limit
        case observations
    }
}

// MARK: - Observation

struct FREDObservation: Codable, Identifiable, Hashable {
    var id: String { date }

    let realtimeStart: String?
    let realtimeEnd: String?
    let date: String
    let value: String

    enum CodingKeys: String, CodingKey {
        case realtimeStart = "realtime_start"
        case realtimeEnd = "realtime_end"
        case date, value
    }

    private static let storageDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var doubleValue: Double? {
        Double(value)
    }

    var isValidValue: Bool {
        value != "." && doubleValue != nil
    }

    var dateObject: Date? {
        Self.storageDateFormatter.date(from: date)
    }

    var formattedDate: String {
        guard let dateObject else { return date }
        return Self.displayDateFormatter.string(from: dateObject)
    }

    var formattedValue: String {
        guard let doubleValue else { return value }
        return ObservationRow.defaultNumberFormatter.string(from: NSNumber(value: doubleValue)) ?? value
    }
}

// MARK: - Chart Data

struct ChartDataPoint: Identifiable, Hashable {
    var id: String { "\(seriesId)-\(date.timeIntervalSince1970)" }

    let seriesId: String
    let seriesTitle: String
    let date: Date
    let value: Double

    init?(observation: FREDObservation, seriesId: String, seriesTitle: String) {
        guard let date = observation.dateObject,
              let value = observation.doubleValue else {
            return nil
        }

        self.seriesId = seriesId
        self.seriesTitle = seriesTitle
        self.date = date
        self.value = value
    }

    init(seriesId: String, seriesTitle: String, date: Date, value: Double) {
        self.seriesId = seriesId
        self.seriesTitle = seriesTitle
        self.date = date
        self.value = value
    }
}

// MARK: - Table Row

struct ObservationRow: Identifiable, Hashable {
    static let defaultNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    let id: String
    let date: String
    let dateObject: Date?
    let value: String
    let numericValue: Double?
    let formattedDate: String
    let formattedValue: String
    let units: String

    init(observation: FREDObservation, units: String = "") {
        id = observation.id
        date = observation.date
        dateObject = observation.dateObject
        value = observation.value
        numericValue = observation.doubleValue
        formattedDate = observation.formattedDate
        self.units = units

        if let numericValue {
            formattedValue = ValueFormatter(units: units).formatValue(numericValue, compact: false)
        } else {
            formattedValue = observation.value
        }
    }
}

// MARK: - Favorites

struct FavoriteSeries: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let units: String
    let frequency: String
    let addedDate: Date

    init(from series: FREDSeries) {
        id = series.id
        title = series.title
        units = series.units
        frequency = series.frequency
        addedDate = Date()
    }
}

// MARK: - Date Range Filter

enum DateRangeOption: String, CaseIterable, Identifiable {
    case all = "All Time"
    case oneMonth = "1 Month"
    case threeMonths = "3 Months"
    case sixMonths = "6 Months"
    case oneYear = "1 Year"
    case fiveYears = "5 Years"
    case tenYears = "10 Years"
    case twentyYears = "20 Years"

    var id: String { rawValue }

    var startDate: Date? {
        let calendar = Calendar.current
        let now = Date()

        switch self {
        case .all:
            return nil
        case .oneMonth:
            return calendar.date(byAdding: .month, value: -1, to: now)
        case .threeMonths:
            return calendar.date(byAdding: .month, value: -3, to: now)
        case .sixMonths:
            return calendar.date(byAdding: .month, value: -6, to: now)
        case .oneYear:
            return calendar.date(byAdding: .year, value: -1, to: now)
        case .fiveYears:
            return calendar.date(byAdding: .year, value: -5, to: now)
        case .tenYears:
            return calendar.date(byAdding: .year, value: -10, to: now)
        case .twentyYears:
            return calendar.date(byAdding: .year, value: -20, to: now)
        }
    }
}

// MARK: - Export Format

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv = "CSV"
    case json = "JSON"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .csv:
            return "csv"
        case .json:
            return "json"
        }
    }

    var contentType: String {
        switch self {
        case .csv:
            return "text/csv"
        case .json:
            return "application/json"
        }
    }
}

// MARK: - Formatting Helpers

struct ValueFormatter {
    let units: String

    private var lowerUnits: String {
        units.lowercased()
    }

    private var isPercent: Bool { lowerUnits.contains("percent") }
    private var isCurrency: Bool { lowerUnits.contains("dollar") }
    private var isBillions: Bool { lowerUnits.contains("billion") }
    private var isMillions: Bool { lowerUnits.contains("million") }
    private var isThousands: Bool { lowerUnits.contains("thousand") }
    private var isIndex: Bool { lowerUnits.contains("index") }

    func formatValue(_ value: Double, compact: Bool) -> String {
        if isPercent {
            return String(format: "%.2f%%", value)
        }

        if isBillions {
            return formatCurrency(value * 1_000_000_000, compact: compact)
        }

        if isMillions {
            return formatCurrency(value * 1_000_000, compact: compact)
        }

        if isThousands {
            return formatCurrency(value * 1_000, compact: compact)
        }

        if isCurrency {
            return formatCurrency(value, compact: compact)
        }

        if isIndex {
            return compact ? String(format: "%.1f", value) : String(format: "%.2f", value)
        }

        return formatDecimal(value, compact: compact)
    }

    func formatAxisValue(_ value: Double) -> String {
        if isPercent {
            return String(format: "%.1f%%", value)
        }

        if isCurrency || isBillions || isMillions || isThousands {
            return formatCurrency(value, compact: true)
        }

        return formatDecimal(value, compact: true)
    }

    private func formatCurrency(_ value: Double, compact: Bool) -> String {
        if compact || abs(value) >= 1_000_000 {
            switch abs(value) {
            case 1_000_000_000_000...:
                return String(format: "$%.1fT", value / 1_000_000_000_000)
            case 1_000_000_000...:
                return String(format: "$%.1fB", value / 1_000_000_000)
            case 1_000_000...:
                return String(format: "$%.1fM", value / 1_000_000)
            case 1_000...:
                return String(format: "$%.1fK", value / 1_000)
            default:
                break
            }
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "$\(value)"
    }

    private func formatDecimal(_ value: Double, compact: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = compact ? 1 : 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: compact ? "%.1f" : "%.2f", value)
    }
}

// MARK: - Statistics

struct SeriesStatistics: Equatable {
    let count: Int
    let min: Double
    let max: Double
    let mean: Double
    let median: Double
    let standardDeviation: Double
    let latestValue: Double
    let latestChange: Double
    let latestPercentChange: Double
    let firstValue: Double
    let totalChange: Double
    let annualizedChange: Double
    let range: Double
    let units: String

    init(
        count: Int,
        min: Double,
        max: Double,
        mean: Double,
        median: Double,
        standardDeviation: Double,
        latestValue: Double,
        latestChange: Double,
        latestPercentChange: Double,
        firstValue: Double = 0,
        totalChange: Double = 0,
        annualizedChange: Double = 0,
        range: Double? = nil,
        units: String = ""
    ) {
        self.count = count
        self.min = min
        self.max = max
        self.mean = mean
        self.median = median
        self.standardDeviation = standardDeviation
        self.latestValue = latestValue
        self.latestChange = latestChange
        self.latestPercentChange = latestPercentChange
        self.firstValue = firstValue == 0 ? min : firstValue
        self.totalChange = totalChange == 0 ? latestValue - (firstValue == 0 ? min : firstValue) : totalChange
        self.annualizedChange = annualizedChange
        self.range = range ?? (max - min)
        self.units = units
    }

    private var formatter: ValueFormatter {
        ValueFormatter(units: units)
    }

    var formattedMin: String { formatter.formatValue(min, compact: true) }
    var formattedMax: String { formatter.formatValue(max, compact: true) }
    var formattedMean: String { formatter.formatValue(mean, compact: true) }
    var formattedMedian: String { formatter.formatValue(median, compact: true) }
    var formattedStdDev: String { formatNumber(standardDeviation) }
    var formattedLatestValue: String { formatter.formatValue(latestValue, compact: true) }
    var formattedRange: String { formatter.formatValue(range, compact: true) }
    var formattedTotalChange: String { signed(formatter.formatValue(totalChange, compact: true), value: totalChange) }
    var formattedAnnualizedChange: String { String(format: "%.2f%% / yr", annualizedChange) }

    var formattedLatestChange: String {
        signed(formatter.formatValue(latestChange, compact: true), value: latestChange)
    }

    var formattedPercentChange: String {
        signed(String(format: "%.2f%%", abs(latestPercentChange)), value: latestPercentChange)
    }

    private func formatNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    private func signed(_ string: String, value: Double) -> String {
        let unsignedString = string.hasPrefix("-") ? String(string.dropFirst()) : string
        if value > 0 { return "+\(unsignedString)" }
        if value < 0 { return "-\(unsignedString)" }
        return unsignedString
    }
}

struct SeriesInsight: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let value: String
    let detail: String
    let symbol: String
}
