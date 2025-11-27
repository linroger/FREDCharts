import Foundation

// MARK: - Search Response
struct FREDSearchResponse: Codable {
    let series: [FREDSeries]

    enum CodingKeys: String, CodingKey {
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
    let units: String
    let seasonalAdjustment: String
    let lastUpdated: String

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case observationStart = "observation_start"
        case observationEnd = "observation_end"
        case frequency
        case units
        case seasonalAdjustment = "seasonal_adjustment"
        case lastUpdated = "last_updated"
    }
}

// MARK: - Observations Response
struct FREDObservationsResponse: Codable {
    let observations: [FREDObservation]
}

// MARK: - Observation
struct FREDObservation: Codable, Identifiable, Hashable {
    var id: String { date + value }
    let date: String
    let value: String

    var doubleValue: Double? {
        Double(value)
    }

    // Shared formatter for performance
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var dateObject: Date? {
        Self.dateFormatter.date(from: date)
    }
}
