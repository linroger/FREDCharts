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

    var doubleValue: Double? {
        Double(value)
    }
    
    var isValidValue: Bool {
        value != "." && doubleValue != nil
    }

    // Shared formatter for performance
    private static let dateFormatter: DateFormatter = {
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

    var dateObject: Date? {
        Self.dateFormatter.date(from: date)
    }
    
    var formattedDate: String {
        guard let date = dateObject else { return self.date }
        return Self.displayDateFormatter.string(from: date)
    }
    
    var formattedValue: String {
        guard let value = doubleValue else { return self.value }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? self.value
    }
}

// MARK: - Chart Data Point (for charting with valid data only)
struct ChartDataPoint: Identifiable {
    let id = UUID()
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
}

// MARK: - Table Row (for table display)
struct ObservationRow: Identifiable {
    let id: String
    let date: String
    let dateObject: Date?
    let value: String
    let numericValue: Double?
    let formattedDate: String
    let formattedValue: String
    let units: String
    
    init(observation: FREDObservation, units: String = "") {
        self.id = observation.id
        self.date = observation.date
        self.dateObject = observation.dateObject
        self.value = observation.value
        self.numericValue = observation.doubleValue
        self.formattedDate = observation.formattedDate
        self.units = units
        
        // Unit-aware formatting
        if let numValue = observation.doubleValue {
            self.formattedValue = ObservationRow.formatValue(numValue, units: units)
        } else {
            self.formattedValue = observation.value
        }
    }
    
    private static func formatValue(_ value: Double, units: String) -> String {
        let lowerUnits = units.lowercased()
        
        if lowerUnits.contains("percent") {
            return String(format: "%.2f%%", value)
        }
        
        if lowerUnits.contains("billion") && lowerUnits.contains("dollar") {
            // Value is in billions, display as trillions/billions
            if value >= 1000 {
                return String(format: "$%.2fT", value / 1000)
            } else {
                return String(format: "$%.2fB", value)
            }
        }
        
        if lowerUnits.contains("million") && lowerUnits.contains("dollar") {
            if value >= 1000 {
                return String(format: "$%.2fB", value / 1000)
            } else {
                return String(format: "$%.2fM", value)
            }
        }
        
        if lowerUnits.contains("dollar") {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencySymbol = "$"
            formatter.maximumFractionDigits = 2
            return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
        }
        
        // Default decimal formatting
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
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
        self.id = series.id
        self.title = series.title
        self.units = series.units
        self.frequency = series.frequency
        self.addedDate = Date()
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
        case .all: return nil
        case .oneMonth: return calendar.date(byAdding: .month, value: -1, to: now)
        case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: now)
        case .sixMonths: return calendar.date(byAdding: .month, value: -6, to: now)
        case .oneYear: return calendar.date(byAdding: .year, value: -1, to: now)
        case .fiveYears: return calendar.date(byAdding: .year, value: -5, to: now)
        case .tenYears: return calendar.date(byAdding: .year, value: -10, to: now)
        case .twentyYears: return calendar.date(byAdding: .year, value: -20, to: now)
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
        case .csv: return "csv"
        case .json: return "json"
        }
    }
    
    var contentType: String {
        switch self {
        case .csv: return "text/csv"
        case .json: return "application/json"
        }
    }
}
