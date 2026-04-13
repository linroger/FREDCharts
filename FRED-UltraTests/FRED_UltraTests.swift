//
//  FRED_UltraTests.swift
//  FRED-UltraTests
//
//  Created by Roger Lin on 12/11/24.
//

import Testing
import Foundation
@testable import FRED_Ultra

// MARK: - Model Tests

struct FREDModelsTests {
    
    @Test func testFREDObservationParsing() async throws {
        let json = """
        {
            "date": "2024-01-01",
            "value": "123.45"
        }
        """
        let data = json.data(using: .utf8)!
        let observation = try JSONDecoder().decode(FREDObservation.self, from: data)
        
        #expect(observation.date == "2024-01-01")
        #expect(observation.value == "123.45")
        #expect(observation.doubleValue == 123.45)
        #expect(observation.isValidValue == true)
        #expect(observation.dateObject != nil)
    }
    
    @Test func testFREDObservationInvalidValue() async throws {
        let json = """
        {
            "date": "2024-01-01",
            "value": "."
        }
        """
        let data = json.data(using: .utf8)!
        let observation = try JSONDecoder().decode(FREDObservation.self, from: data)
        
        #expect(observation.value == ".")
        #expect(observation.doubleValue == nil)
        #expect(observation.isValidValue == false)
    }
    
    @Test func testFREDSeriesParsing() async throws {
        let json = """
        {
            "id": "GDP",
            "title": "Gross Domestic Product",
            "observation_start": "1947-01-01",
            "observation_end": "2024-01-01",
            "frequency": "Quarterly",
            "units": "Billions of Dollars",
            "seasonal_adjustment": "Seasonally Adjusted Annual Rate",
            "last_updated": "2024-01-01 07:00:00-06"
        }
        """
        let data = json.data(using: .utf8)!
        let series = try JSONDecoder().decode(FREDSeries.self, from: data)
        
        #expect(series.id == "GDP")
        #expect(series.title == "Gross Domestic Product")
        #expect(series.frequency == "Quarterly")
        #expect(series.units == "Billions of Dollars")
        #expect(series.formattedDateRange == "1947-01-01 to 2024-01-01")
    }
    
    @Test func testFREDSearchResponseParsing() async throws {
        let json = """
        {
            "seriess": [
                {
                    "id": "GDP",
                    "title": "Gross Domestic Product",
                    "observation_start": "1947-01-01",
                    "observation_end": "2024-01-01",
                    "frequency": "Quarterly",
                    "units": "Billions of Dollars",
                    "seasonal_adjustment": "Seasonally Adjusted",
                    "last_updated": "2024-01-01"
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(FREDSearchResponse.self, from: data)
        
        #expect(response.series.count == 1)
        #expect(response.series.first?.id == "GDP")
    }
    
    @Test func testChartDataPointCreation() async throws {
        let observation = FREDObservation(
            realtimeStart: nil,
            realtimeEnd: nil,
            date: "2024-01-15",
            value: "100.5"
        )
        
        let dataPoint = ChartDataPoint(observation: observation, seriesId: "GDP", seriesTitle: "GDP Title")
        
        #expect(dataPoint != nil)
        #expect(dataPoint?.seriesId == "GDP")
        #expect(dataPoint?.seriesTitle == "GDP Title")
        #expect(dataPoint?.value == 100.5)
    }
    
    @Test func testChartDataPointWithInvalidValue() async throws {
        let observation = FREDObservation(
            realtimeStart: nil,
            realtimeEnd: nil,
            date: "2024-01-15",
            value: "."
        )
        
        let dataPoint = ChartDataPoint(observation: observation, seriesId: "GDP", seriesTitle: "GDP Title")
        
        #expect(dataPoint == nil)
    }
    
    @Test func testObservationRowCreation() async throws {
        let observation = FREDObservation(
            realtimeStart: nil,
            realtimeEnd: nil,
            date: "2024-01-15",
            value: "1234.56"
        )
        
        let row = ObservationRow(observation: observation)
        
        #expect(row.date == "2024-01-15")
        #expect(row.value == "1234.56")
        #expect(row.numericValue == 1234.56)
        #expect(row.formattedValue == "1,234.56")
    }
    
    @Test func testFavoriteSeriesCreation() async throws {
        let series = FREDSeries(
            id: "GDP",
            title: "Gross Domestic Product",
            observationStart: "1947-01-01",
            observationEnd: "2024-01-01",
            frequency: "Quarterly",
            frequencyShort: "Q",
            units: "Billions of Dollars",
            unitsShort: "Bil. of $",
            seasonalAdjustment: "Seasonally Adjusted",
            seasonalAdjustmentShort: "SA",
            lastUpdated: "2024-01-01",
            popularity: 100,
            notes: nil
        )
        
        let favorite = FavoriteSeries(from: series)
        
        #expect(favorite.id == "GDP")
        #expect(favorite.title == "Gross Domestic Product")
        #expect(favorite.units == "Billions of Dollars")
        #expect(favorite.frequency == "Quarterly")
    }
}

// MARK: - Date Range Tests

struct DateRangeTests {
    
    @Test func testDateRangeOptionAll() async throws {
        let option = DateRangeOption.all
        #expect(option.startDate == nil)
        #expect(option.rawValue == "All Time")
    }
    
    @Test func testDateRangeOptionOneYear() async throws {
        let option = DateRangeOption.oneYear
        #expect(option.startDate != nil)
        
        let calendar = Calendar.current
        let expectedStart = calendar.date(byAdding: .year, value: -1, to: Date())!
        let actualStart = option.startDate!
        
        // Check that dates are within 1 day of each other (accounting for test timing)
        let difference = abs(expectedStart.timeIntervalSince(actualStart))
        #expect(difference < 86400) // Less than 1 day
    }
    
    @Test func testAllDateRangeOptions() async throws {
        let options = DateRangeOption.allCases
        #expect(options.count == 8)
        
        // All options should have valid IDs
        for option in options {
            #expect(!option.id.isEmpty)
        }
    }
}

// MARK: - Export Format Tests

struct ExportFormatTests {
    
    @Test func testCSVFormat() async throws {
        let format = ExportFormat.csv
        #expect(format.fileExtension == "csv")
        #expect(format.contentType == "text/csv")
    }
    
    @Test func testJSONFormat() async throws {
        let format = ExportFormat.json
        #expect(format.fileExtension == "json")
        #expect(format.contentType == "application/json")
    }
}

// MARK: - Export Service Tests

struct ExportServiceTests {
    
    @Test func testCSVExport() async throws {
        let series = FREDSeries(
            id: "TEST",
            title: "Test Series",
            observationStart: "2024-01-01",
            observationEnd: "2024-12-31",
            frequency: "Monthly",
            frequencyShort: "M",
            units: "Index",
            unitsShort: "Idx",
            seasonalAdjustment: "Not Adjusted",
            seasonalAdjustmentShort: "NSA",
            lastUpdated: "2024-01-01",
            popularity: nil,
            notes: nil
        )
        
        let observations = [
            FREDObservation(realtimeStart: nil, realtimeEnd: nil, date: "2024-01-01", value: "100.0"),
            FREDObservation(realtimeStart: nil, realtimeEnd: nil, date: "2024-02-01", value: "101.5")
        ]
        
        let csv = ExportService.exportToCSV(series: series, observations: observations)
        
        #expect(csv.contains("Date,Value"))
        #expect(csv.contains("Test Series"))
        #expect(csv.contains("TEST"))
        #expect(csv.contains("2024-01-01"))
        #expect(csv.contains("100.0"))
    }
    
    @Test func testJSONExport() async throws {
        let series = FREDSeries(
            id: "TEST",
            title: "Test Series",
            observationStart: "2024-01-01",
            observationEnd: "2024-12-31",
            frequency: "Monthly",
            frequencyShort: "M",
            units: "Index",
            unitsShort: "Idx",
            seasonalAdjustment: "Not Adjusted",
            seasonalAdjustmentShort: "NSA",
            lastUpdated: "2024-01-01",
            popularity: nil,
            notes: nil
        )
        
        let observations = [
            FREDObservation(realtimeStart: nil, realtimeEnd: nil, date: "2024-01-01", value: "100.0")
        ]
        
        let json = ExportService.exportToJSON(series: series, observations: observations)
        
        #expect(json.contains("\"id\" : \"TEST\""))
        #expect(json.contains("\"title\" : \"Test Series\""))
        #expect(json.contains("observations"))
        #expect(json.contains("metadata"))
    }
}

// MARK: - Statistics Tests

struct StatisticsTests {
    
    @Test func testSeriesStatisticsFormatting() async throws {
        let stats = SeriesStatistics(
            count: 100,
            min: 10.0,
            max: 200.0,
            mean: 105.5,
            median: 100.0,
            standardDeviation: 25.3,
            latestValue: 150.0,
            latestChange: 5.5,
            latestPercentChange: 3.8
        )
        
        #expect(stats.count == 100)
        #expect(stats.formattedMin == "10")
        #expect(stats.formattedMax == "200")
        #expect(stats.formattedLatestChange == "+5.5")
        #expect(stats.formattedPercentChange == "+3.80%")
    }
    
    @Test func testNegativeChangeFormatting() async throws {
        let stats = SeriesStatistics(
            count: 50,
            min: 5.0,
            max: 100.0,
            mean: 50.0,
            median: 45.0,
            standardDeviation: 10.0,
            latestValue: 40.0,
            latestChange: -5.0,
            latestPercentChange: -11.11
        )
        
        #expect(stats.formattedLatestChange == "-5")
        #expect(stats.formattedPercentChange == "-11.11%")
    }
}

// MARK: - Error Tests

struct FREDErrorTests {
    
    @Test func testMissingAPIKeyError() async throws {
        let error = FREDError.missingAPIKey
        #expect(error.errorDescription?.contains("API key") == true)
        #expect(error.recoverySuggestion != nil)
    }
    
    @Test func testRateLimitedError() async throws {
        let error = FREDError.rateLimited
        #expect(error.errorDescription?.contains("Rate limited") == true)
        #expect(error.recoverySuggestion?.contains("120") == true)
    }
    
    @Test func testInvalidURLError() async throws {
        let error = FREDError.invalidURL
        #expect(error.errorDescription?.contains("URL") == true)
    }
}
