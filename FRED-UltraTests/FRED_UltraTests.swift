import Foundation
import SwiftUI
import Testing
@testable import FRED_Ultra

// MARK: - Fixtures

enum Fixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar
    }()

    static func date(_ string: String) -> Date {
        guard let date = FREDDate.date(from: string) else {
            fatalError("Fixture date \(string) could not be parsed")
        }
        return date
    }

    static func points(_ entries: [(String, Double)]) -> [SeriesDataPoint] {
        entries.map { SeriesDataPoint(date: date($0.0), value: $0.1) }
    }

    /// Monthly points starting at `start`, one per month.
    static func monthly(start: String, values: [Double]) -> [SeriesDataPoint] {
        let first = date(start)
        return values.enumerated().compactMap { index, value in
            guard let stamped = calendar.date(byAdding: .month, value: index, to: first) else { return nil }
            return SeriesDataPoint(date: stamped, value: value)
        }
    }

    static func series(
        id: String,
        title: String? = nil,
        units: String = "Index",
        frequency: String = "Monthly",
        frequencyShort: String? = "M",
        observationStart: String = "2000-01-01",
        observationEnd: String = "2026-01-01"
    ) -> FREDSeries {
        FREDSeries(
            id: id,
            title: title ?? "\(id) Series",
            observationStart: observationStart,
            observationEnd: observationEnd,
            frequency: frequency,
            frequencyShort: frequencyShort,
            units: units,
            unitsShort: nil,
            seasonalAdjustment: "Not Seasonally Adjusted",
            seasonalAdjustmentShort: "NSA",
            lastUpdated: "2026-01-02 08:00:00-06",
            popularity: 50,
            notes: nil
        )
    }

    /// Loader that always succeeds with the supplied history and counts invocations.
    static func loader(
        _ history: [String: [SeriesDataPoint]],
        failures: [String: String] = [:],
        callCount: CallCounter? = nil
    ) -> SeriesDetailViewModel.ObservationsLoader {
        { ids, _ in
            callCount?.increment()
            return ids.map { id in
                if let failure = failures[id] {
                    return SeriesLoadResult(seriesId: id, points: [], failureMessage: failure)
                }
                return SeriesLoadResult(seriesId: id, points: history[id] ?? [], failureMessage: nil)
            }
        }
    }
}

/// Thread-safe counter usable from `@Sendable` loader closures.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - Decoding

struct DecodingTests {

    @Test func observationParsesNumericValue() throws {
        let json = #"{"realtime_start":"2026-01-01","date":"2024-01-01","value":"123.45"}"#
        let observation = try JSONDecoder().decode(FREDObservation.self, from: Data(json.utf8))

        #expect(observation.date == "2024-01-01")
        #expect(observation.doubleValue == 123.45)
        #expect(observation.isValidValue)
        #expect(observation.dataPoint != nil)
    }

    @Test func observationTreatsMissingMarkerAsInvalid() throws {
        let json = #"{"date":"2024-01-01","value":"."}"#
        let observation = try JSONDecoder().decode(FREDObservation.self, from: Data(json.utf8))

        #expect(observation.doubleValue == nil)
        #expect(observation.isValidValue == false)
        #expect(observation.dataPoint == nil)
    }

    /// FRED encodes gaps as "."; those rows must be dropped rather than charted as zero.
    @Test func parsingDropsMissingRowsAndSorts() {
        let observations = [
            FREDObservation(date: "2024-03-01", value: "3"),
            FREDObservation(date: "2024-01-01", value: "1"),
            FREDObservation(date: "2024-02-01", value: "."),
            FREDObservation(date: "2024-04-01", value: "nan")
        ]

        let points = observations.parsedDataPoints()

        #expect(points.count == 2)
        #expect(points[0].value == 1)
        #expect(points[1].value == 3)
        #expect(points[0].date < points[1].date)
    }

    @Test func searchResponseUsesSeriessKey() throws {
        let json = """
        {"count":1,"seriess":[{"id":"GDP","title":"Gross Domestic Product","observation_start":"1947-01-01",
        "observation_end":"2026-04-01","frequency":"Quarterly","frequency_short":"Q","units":"Billions of Dollars",
        "seasonal_adjustment":"Seasonally Adjusted Annual Rate","last_updated":"2026-08-26 07:49:01-05","popularity":92}]}
        """
        let response = try JSONDecoder().decode(FREDSearchResponse.self, from: Data(json.utf8))

        #expect(response.series.count == 1)
        #expect(response.series[0].id == "GDP")
        #expect(response.series[0].seriesFrequency == .quarterly)
    }

    /// A single sparsely-populated series must not discard an entire page of results.
    @Test func seriesDecodingToleratesMissingOptionalFields() throws {
        let json = #"{"id":"OBSCURE"}"#
        let series = try JSONDecoder().decode(FREDSeries.self, from: Data(json.utf8))

        #expect(series.id == "OBSCURE")
        #expect(series.title == "OBSCURE")
        #expect(series.units.isEmpty)
        #expect(series.frequency == "Unknown")
        #expect(series.formattedDateRange == "Unknown coverage")
    }

    @Test func seriesDecodingFailsWithoutAnIdentifier() {
        let json = #"{"title":"No identifier"}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(FREDSeries.self, from: Data(json.utf8))
        }
    }

    @Test func shortNotesCollapseNewlinesAndTruncate() {
        let long = String(repeating: "a", length: 400)
        let series = Fixture.series(id: "X")
        let withNotes = FREDSeries(
            id: series.id, title: series.title, observationStart: series.observationStart,
            observationEnd: series.observationEnd, frequency: series.frequency,
            units: series.units, seasonalAdjustment: series.seasonalAdjustment,
            lastUpdated: series.lastUpdated, notes: "line one\nline two"
        )

        #expect(withNotes.shortNotes == "line one line two")

        let truncated = FREDSeries(
            id: series.id, title: series.title, observationStart: series.observationStart,
            observationEnd: series.observationEnd, frequency: series.frequency,
            units: series.units, seasonalAdjustment: series.seasonalAdjustment,
            lastUpdated: series.lastUpdated, notes: long
        )

        #expect(truncated.shortNotes?.count == 178)
        #expect(truncated.shortNotes?.hasSuffix("…") == true)
    }
}

private extension String {
    init(repeating character: String, length: Int) {
        self = String(repeating: character, count: length)
    }
}

// MARK: - Units

struct UnitTests {

    @Test func currencyScalesAreParsed() {
        let billions = UnitDescriptor(units: "Billions of Dollars")
        let dollars = UnitDescriptor(units: "Current U.S. Dollars")

        #expect(billions.family == .currency)
        #expect(billions.scale == 1_000_000_000)
        #expect(dollars.scale == 1)
        #expect(billions.canonicalUnits == "U.S. Dollars")
        #expect(billions.isComparable(to: dollars))
        #expect(billions.convertedValue(31_000) == 31_000_000_000_000)
    }

    /// Chained dollars are a different price basis; treating them as nominal dollars
    /// would silently compare real and nominal magnitudes.
    @Test func chainedDollarsAreNotComparableWithNominal() {
        let chained = UnitDescriptor(units: "Billions of Chained 2017 Dollars")
        let nominal = UnitDescriptor(units: "Current U.S. Dollars")

        #expect(chained.canonicalUnits == "Chained 2017 Dollars")
        #expect(chained.isComparable(to: nominal) == false)
    }

    @Test func nonCurrencyFamiliesAreDetected() {
        #expect(UnitDescriptor(units: "Percent").family == .percent)
        #expect(UnitDescriptor(units: "Percent Change at Annual Rate").family == .percent)
        #expect(UnitDescriptor(units: "Index 1982-1984=100").family == .index)
        #expect(UnitDescriptor(units: "Thousands of Persons").family == .persons)
        #expect(UnitDescriptor(units: "Thousands of Persons").scale == 1_000)
        #expect(UnitDescriptor(units: "Thousands of Units").family == .generic)
        #expect(UnitDescriptor(units: "Thousands of Units").canonicalUnits == "Units")
    }

    /// Every magnitude form FRED (or a user) can write must reduce to one multiplier.
    @Test func magnitudesNormaliseOntoASingleBase() {
        #expect(UnitDescriptor(units: "Thousands of Dollars").scale == 1_000)
        #expect(UnitDescriptor(units: "Millions of Dollars").scale == 1_000_000)
        #expect(UnitDescriptor(units: "Billions of Dollars").scale == 1_000_000_000)
        #expect(UnitDescriptor(units: "Trillions of Dollars").scale == 1_000_000_000_000)

        // Chained magnitude words multiply.
        #expect(UnitDescriptor(units: "Hundreds of Millions of Dollars").scale == 100_000_000)
        #expect(UnitDescriptor(units: "Tens of Thousands of Units").scale == 10_000)

        // An explicit factor in front of a magnitude word.
        #expect(UnitDescriptor(units: "0.4 Billion Dollars").scale == 400_000_000)
        #expect(UnitDescriptor(units: "100 Billions of Dollars").scale == 100_000_000_000)

        // A bare literal, with or without digit-group separators or a plural.
        #expect(UnitDescriptor(units: "1,000,000 Dollars").scale == 1_000_000)
        #expect(UnitDescriptor(units: "1000000 Dollars").scale == 1_000_000)
        #expect(UnitDescriptor(units: "1,000,000s of Dollars").scale == 1_000_000)

        // Small literals are quantities, not magnitudes.
        #expect(UnitDescriptor(units: "Dollars").scale == 1)
        #expect(UnitDescriptor(units: "U.S. Dollars").scale == 1)
    }

    /// A rate's magnitude comes from its numerator alone. "Dollars per Million BTU" used
    /// to pick up "million" and render $3.50 as "$3.5M".
    @Test func rateDenominatorsDoNotContributeAScale() {
        let btu = UnitDescriptor(units: "Dollars per Million BTU")
        #expect(btu.scale == 1)
        #expect(btu.family == .currency)
        #expect(btu.denominator == "Million BTU")
        #expect(btu.canonicalUnits == "U.S. Dollars per Million BTU")

        let births = UnitDescriptor(units: "Number per 1,000 Live Births")
        #expect(births.scale == 1)
        #expect(births.denominator == "1,000 Live Births")

        let hourly = ValueFormatter(units: "Dollars per Hour", locale: Locale(identifier: "en_US"))
        #expect(hourly.formatValue(28.5, compact: false) == "$28.5")
    }

    /// Two rates measured per different things cannot share an axis, even though both
    /// are "dollars". Dollars per hour is not comparable with billions of dollars.
    @Test func ratesAreOnlyComparableWithMatchingDenominators() {
        let perHour = UnitDescriptor(units: "Dollars per Hour")
        let perGallon = UnitDescriptor(units: "Dollars per Gallon")
        let billions = UnitDescriptor(units: "Billions of Dollars")

        #expect(perHour.isComparable(to: perGallon) == false)
        #expect(perHour.isComparable(to: billions) == false)
        #expect(perHour.isComparable(to: UnitDescriptor(units: "U.S. Dollars per Hour")))
    }

    /// Constant-dollar series are a different price basis from nominal ones, however
    /// FRED words it.
    @Test func deflatedDollarsAreDistinguishedFromNominal() {
        let nominal = UnitDescriptor(units: "Current Dollars")
        let cpiAdjusted = UnitDescriptor(units: "1982-84 CPI Adjusted Dollars")
        let constantYear = UnitDescriptor(units: "2010 U.S. Dollars")
        let chained = UnitDescriptor(units: "Chained 2017 Dollars")

        #expect(nominal.currencyBasis == .nominal)
        #expect(cpiAdjusted.currencyBasis == .real(year: 1982))
        #expect(constantYear.currencyBasis == .real(year: 2010))
        #expect(chained.currencyBasis == .chained(year: 2017))

        #expect(nominal.isComparable(to: cpiAdjusted) == false)
        #expect(nominal.isComparable(to: constantYear) == false)
        #expect(constantYear.isComparable(to: chained) == false)

        // A year inside a constant-dollar label is a price base, never a multiplier.
        #expect(constantYear.scale == 1)
        #expect(cpiAdjusted.scale == 1)
    }

    /// Basis points are hundredths of a percent, so they normalise onto the percent base.
    @Test func basisPointsNormaliseOntoThePercentBase() {
        let basisPoints = UnitDescriptor(units: "Basis Points")
        #expect(basisPoints.family == .percent)
        #expect(basisPoints.scale == 0.01)
        #expect(basisPoints.isComparable(to: UnitDescriptor(units: "Percent")))

        let formatter = ValueFormatter(units: "Basis Points", locale: Locale(identifier: "en_US"))
        #expect(formatter.formatValue(25, compact: false) == "0.25%")
        // The published figure stays in basis points in the table and exports.
        #expect(formatter.formatPrecise(25) == "25")
    }

    /// An index base period is not a magnitude: none of 1982, 1984, or 100 is a scale.
    @Test func indexBasePeriodsAreNeverTreatedAsMagnitudes() {
        for units in ["Index 1982-1984=100", "Index 2017=100", "Index Jan 1990=1", "Index 1995:Q1=100"] {
            let descriptor = UnitDescriptor(units: units)
            #expect(descriptor.family == .index)
            #expect(descriptor.scale == 1)
            #expect(descriptor.presentationUnits == units)
        }
    }

    /// Ratios need more decimal places than a general count; 0.0234 must not read 0.02.
    @Test func ratiosGetTheirOwnPrecision() {
        let descriptor = UnitDescriptor(units: "Ratio")
        #expect(descriptor.family == .ratio)

        let formatter = ValueFormatter(units: "Ratio", locale: Locale(identifier: "en_US"))
        #expect(formatter.formatValue(0.0234, compact: false) == "0.0234")
        #expect(formatter.formatValue(0.0234, compact: true) == "0.02")
    }

    /// A bare "Thousands" has nothing left once the magnitude is stripped, and labelling
    /// the scaled value "Thousands" would overstate it a thousandfold.
    @Test func bareMagnitudesAreRelabelledAfterScaling() {
        let descriptor = UnitDescriptor(units: "Thousands")
        #expect(descriptor.scale == 1_000)
        #expect(descriptor.canonicalUnits == "Units")
        #expect(descriptor.presentationUnits == "Units")
    }

    /// Percent variants stay in the percent family whatever qualifies them.
    @Test func percentVariantsAreRecognised() {
        for units in [
            "Percent", "Percent Change at Annual Rate", "Percent of Total",
            "Percent of Working-Age Population", "Percent per Annum",
            "Percent Change from Quarter One Year Ago"
        ] {
            #expect(UnitDescriptor(units: units).family == .percent)
            #expect(UnitDescriptor(units: units).scale == 1)
        }
    }

    @Test func descriptorCacheReturnsEqualValues() {
        let first = UnitDescriptor.cached(units: "Millions of Dollars")
        let second = UnitDescriptor.cached(units: "Millions of Dollars")

        #expect(first == second)
        #expect(first.scale == 1_000_000)
    }

    @Test func percentFormattingIsLocaleIndependent() {
        let formatter = ValueFormatter(units: "Percent", locale: Locale(identifier: "de_DE"))
        #expect(formatter.formatValue(4.6612, compact: false) == "4.66%")
    }

    @Test func currencyFormattingCompactsLargeMagnitudes() {
        let formatter = ValueFormatter(units: "Billions of Dollars", locale: Locale(identifier: "en_US"))

        #expect(formatter.formatValue(29_016.714, compact: true) == "$29.0T")
        #expect(formatter.formatAxisValue(29_016.714) == "$29.0T")
        #expect(formatter.formatValue(-1.5, compact: true) == "-$1.5B")
    }

    /// A difference between two percentages is measured in percentage points; labelling
    /// it "%" would overstate the quantity.
    @Test func percentDeltasUsePercentagePoints() {
        let formatter = ValueFormatter(units: "Percent")

        #expect(formatter.formatMagnitude(0.25, compact: false) == "0.25 pp")
        #expect(formatter.formatChange(-0.25, compact: false) == "-0.25 pp")
        #expect(formatter.deltaUnitLabel == "pp")
    }

    /// A "Billions of Dollars" reading is rendered in dollars, so the column it sits
    /// under must say dollars. Labelling it "Billions of Dollars" overstated the figure
    /// by a factor of a billion.
    @Test func presentationUnitsDescribeTheScaledValue() {
        #expect(UnitDescriptor(units: "Billions of Dollars").presentationUnits == "U.S. Dollars")
        #expect(UnitDescriptor(units: "Thousands of Persons").presentationUnits == "Persons")
        #expect(UnitDescriptor(units: "Current U.S. Dollars").presentationUnits == "Current U.S. Dollars")
        #expect(UnitDescriptor(units: "Index 1982-1984=100").presentationUnits == "Index 1982-1984=100")
        #expect(UnitDescriptor(units: "Percent").presentationUnits == "Percent")
    }

    /// The Data tab and every export show values exactly as FRED publishes them, so a
    /// figure copied from the table matches the CSV and the FRED website.
    @Test func preciseFormattingLeavesPublishedValuesAlone() {
        let dollars = ValueFormatter(units: "Billions of Dollars", locale: Locale(identifier: "en_US"))
        #expect(dollars.formatPrecise(29_016.714) == "29,016.714")
        #expect(dollars.formatPrecise(-1.5) == "-1.5")
        #expect(dollars.formatPreciseChange(12.25) == "+12.25")

        let percent = ValueFormatter(units: "Percent", locale: Locale(identifier: "en_US"))
        #expect(percent.formatPrecise(4.66) == "4.66%")
        #expect(percent.formatPreciseChange(-0.25) == "-0.25 pp")
    }

    /// Levels are not deltas: a positive reading must not be prefixed with "+".
    @Test func levelsAreUnsignedAndDeltasAreSigned() {
        let formatter = ValueFormatter(units: "Billions of Dollars", locale: Locale(identifier: "en_US"))
        #expect(formatter.formatValue(1_000, compact: true) == "$1.0T")
        #expect(formatter.formatChange(1_000, compact: true) == "+$1.0T")
        #expect(formatter.formatChange(-1_000, compact: true) == "-$1.0T")
    }

    /// A difference between two rates is measured in percentage points, and the label
    /// must say so — calling it "%" understates it by the size of the base.
    @Test func differenceFormattingUsesPercentagePoints() {
        let delta = ValueFormatter(units: "Percent", locale: Locale(identifier: "en_US"), representsDifference: true)

        #expect(delta.presentationUnits == "Percentage Points")
        #expect(delta.formatValue(-0.5, compact: false) == "-0.50 pp")
        #expect(delta.formatValue(0.25, compact: false) == "+0.25 pp")
        #expect(delta.formatPrecise(-0.5) == "-0.5 pp")
        // Axis labels stay unsigned for positives; a column of "+" is noise.
        #expect(delta.formatAxisValue(0.25) == "0.2 pp")
        #expect(delta.formatAxisValue(-0.25) == "-0.2 pp")

        let level = ValueFormatter(units: "Percent", locale: Locale(identifier: "en_US"))
        #expect(level.presentationUnits == "Percent")
        #expect(level.formatValue(0.25, compact: false) == "0.25%")
    }

    @Test func nonFiniteValuesAreRenderedAsPlaceholders() {
        let formatter = ValueFormatter(units: "Index")
        #expect(formatter.formatValue(.nan, compact: false) == "—")
        #expect(formatter.formatChange(.infinity, compact: false) == "—")
    }
}

// MARK: - Date Ranges

struct DateRangeTests {

    @Test func allTimeHasNoLowerBound() {
        #expect(DateRangeOption.all.startDate(anchoredTo: Date()) == nil)
    }

    /// Windows are measured from the series' own last observation, so a series that
    /// stopped publishing in 2015 still has a populated "1 Year" view.
    @Test func windowsAreAnchoredToTheSuppliedDate() throws {
        let anchor = Fixture.date("2015-06-30")
        let start = try #require(DateRangeOption.oneYear.startDate(anchoredTo: anchor, calendar: Fixture.calendar))

        #expect(start == Fixture.date("2014-06-30"))
    }

    /// A custom window is ordered and clamped to what the data covers, so a reader
    /// cannot select an interval with nothing in it.
    @Test func customWindowsAreOrderedAndClamped() {
        let coverage = Fixture.date("2010-01-01")...Fixture.date("2020-01-01")

        // Endpoints given backwards are corrected rather than rejected.
        let reversed = DateWindow.custom(
            start: Fixture.date("2015-01-01"),
            end: Fixture.date("2012-01-01"),
            clampedTo: coverage
        )
        #expect(reversed == .custom(start: Fixture.date("2012-01-01"), end: Fixture.date("2015-01-01")))

        // Endpoints outside the data are pulled back to it.
        let overshooting = DateWindow.custom(
            start: Fixture.date("1990-01-01"),
            end: Fixture.date("2030-01-01"),
            clampedTo: coverage
        )
        #expect(overshooting == .custom(start: coverage.lowerBound, end: coverage.upperBound))

        // With no coverage known, the endpoints are only ordered.
        let unclamped = DateWindow.custom(
            start: Fixture.date("2030-01-01"),
            end: Fixture.date("1990-01-01"),
            clampedTo: nil
        )
        #expect(unclamped == .custom(start: Fixture.date("1990-01-01"), end: Fixture.date("2030-01-01")))
    }

    @Test func windowsReportTheirBoundsAndLabels() {
        let anchor = Fixture.date("2020-01-01")

        let preset = DateWindow.preset(.oneYear)
        #expect(preset.label == "1 Year")
        #expect(preset.isCustom == false)
        #expect(preset.preset == .oneYear)
        #expect(preset.bounds(anchoredTo: anchor, calendar: Fixture.calendar).end == nil)

        let custom = DateWindow.custom(start: Fixture.date("2008-01-01"), end: Fixture.date("2010-12-01"))
        let bounds = custom.bounds(anchoredTo: anchor, calendar: Fixture.calendar)
        #expect(custom.isCustom)
        #expect(custom.preset == nil)
        #expect(bounds.start == Fixture.date("2008-01-01"))
        #expect(bounds.end == Fixture.date("2010-12-01"))
        #expect(custom.label.contains("–"))
    }

    /// An upper bound is what makes "just 2008 to 2010" possible.
    @Test func filteringHonoursBothBounds() {
        let points = Fixture.monthly(start: "2024-01-01", values: [1, 2, 3, 4, 5])

        #expect(SeriesAnalytics.filter(points, from: nil, through: nil).count == 5)
        #expect(SeriesAnalytics.filter(points, from: points[1].date, through: points[3].date).map(\.value) == [2, 3, 4])
        #expect(SeriesAnalytics.filter(points, from: nil, through: points[1].date).map(\.value) == [1, 2])
        #expect(SeriesAnalytics.filter(points, from: points[3].date).map(\.value) == [4, 5])

        // A window entirely outside the data yields nothing rather than the nearest rows.
        #expect(SeriesAnalytics.filter(points, from: Fixture.date("2030-01-01")).isEmpty)
        #expect(SeriesAnalytics.filter(points, from: nil, through: Fixture.date("1990-01-01")).isEmpty)
    }

    @Test func everyOptionHasAStableIdentifier() {
        let options = DateRangeOption.allCases
        #expect(options.count == 9)
        #expect(Set(options.map(\.id)).count == options.count)
    }
}

// MARK: - Analytics

struct AnalyticsTests {

    @Test func periodChangeAndPercentChange() {
        let points = Fixture.monthly(start: "2024-01-01", values: [100, 110, 99])

        let change = SeriesAnalytics.periodDifference(points, asPercent: false)
        #expect(change.count == 2)
        #expect(change[0].value == 10)
        #expect(abs(change[1].value - (-11)) < 0.000_001)

        let percent = SeriesAnalytics.periodDifference(points, asPercent: true)
        #expect(percent.count == 2)
        #expect(abs(percent[0].value - 10) < 0.000_001)
        #expect(abs(percent[1].value - (-10)) < 0.000_001)
    }

    /// Percent change on a series that crosses zero must keep the sign of the movement.
    @Test func percentChangeUsesAbsoluteDenominator() {
        let points = Fixture.monthly(start: "2024-01-01", values: [-2, -1])
        let percent = SeriesAnalytics.periodDifference(points, asPercent: true)

        #expect(percent.count == 1)
        #expect(abs(percent[0].value - 50) < 0.000_001)
    }

    @Test func periodChangeNeedsAtLeastTwoPoints() {
        #expect(SeriesAnalytics.periodDifference(Fixture.monthly(start: "2024-01-01", values: [1]), asPercent: false).isEmpty)
        #expect(SeriesAnalytics.periodDifference([], asPercent: true).isEmpty)
    }

    @Test func yearOverYearMatchesTheObservationOneYearBack() {
        let values = (0..<25).map { Double(100 + $0) }
        let points = Fixture.monthly(start: "2020-01-01", values: values)

        let yoy = SeriesAnalytics.yearOverYearPercentChange(points, calendar: Fixture.calendar)

        // The first 12 months have no prior-year counterpart within tolerance.
        #expect(yoy.count == 13)
        #expect(yoy[0].date == points[12].date)
        #expect(abs(yoy[0].value - 12.0) < 0.000_001)
    }

    /// Annual data has a 365-day cadence: a fixed index offset would look 12 rows back
    /// and find nothing, so matching is done by date.
    @Test func yearOverYearWorksForAnnualSeries() {
        let points = Fixture.points([
            ("2020-01-01", 100), ("2021-01-01", 110), ("2022-01-01", 121)
        ])

        let yoy = SeriesAnalytics.yearOverYearPercentChange(points, calendar: Fixture.calendar)

        #expect(yoy.count == 2)
        #expect(abs(yoy[0].value - 10) < 0.000_001)
        #expect(abs(yoy[1].value - 10) < 0.000_001)
    }

    @Test func rebasingSetsTheFirstVisiblePointToOneHundred() {
        let points = Fixture.monthly(start: "2024-01-01", values: [50, 75, 100])
        let rebased = SeriesAnalytics.rebasedToOneHundred(points)

        #expect(rebased[0].value == 100)
        #expect(rebased[1].value == 150)
        #expect(rebased[2].value == 200)
    }

    @Test func rebasingLeavesZeroBaseUntouched() {
        let points = Fixture.monthly(start: "2024-01-01", values: [0, 10])
        #expect(SeriesAnalytics.rebasedToOneHundred(points) == points)
    }

    @Test func movingAverageIsTrailingAndFullWindowOnly() {
        let points = Fixture.monthly(start: "2024-01-01", values: [1, 2, 3, 4, 5])
        let averaged = SeriesAnalytics.movingAverage(points, window: 3)

        #expect(averaged.count == 3)
        #expect(averaged[0].value == 2)
        #expect(averaged[0].date == points[2].date)
        #expect(averaged[2].value == 4)
        #expect(SeriesAnalytics.movingAverage(points, window: 9).isEmpty)
    }

    @Test func filterReturnsTheWindowSuffix() {
        let points = Fixture.monthly(start: "2024-01-01", values: [1, 2, 3, 4])

        #expect(SeriesAnalytics.filter(points, from: nil).count == 4)
        #expect(SeriesAnalytics.filter(points, from: points[2].date).count == 2)
        #expect(SeriesAnalytics.filter(points, from: Fixture.date("2030-01-01")).isEmpty)
    }

    @Test func downsamplingPreservesEndpointsAndBudget() {
        let values = (0..<5_000).map { Double($0 % 97) }
        let points = Fixture.monthly(start: "1900-01-01", values: values)

        let sampled = SeriesAnalytics.downsample(points, threshold: 500)

        #expect(sampled.count <= 500)
        #expect(sampled.count >= 490)
        #expect(sampled.first == points.first)
        #expect(sampled.last == points.last)
        #expect(zip(sampled, sampled.dropFirst()).allSatisfy { $0.date < $1.date })
    }

    @Test func downsamplingIsANoOpBelowThreshold() {
        let points = Fixture.monthly(start: "2024-01-01", values: [1, 2, 3])
        #expect(SeriesAnalytics.downsample(points, threshold: 500) == points)
    }

    /// Extremes are what make an economic chart readable; uniform sampling loses them.
    @Test func downsamplingKeepsExtremeValues() {
        var values = (0..<4_000).map { _ in 10.0 }
        values[1_234] = 999
        values[2_345] = -999
        let points = Fixture.monthly(start: "1900-01-01", values: values)

        let sampled = SeriesAnalytics.downsample(points, threshold: 400)

        #expect(sampled.contains { $0.value == 999 })
        #expect(sampled.contains { $0.value == -999 })
    }

    /// USREC is 1 for every month from the month after a peak through the trough, so a
    /// run of 1s is one recession band.
    /// A yield curve is one series minus another. Matching is by nearest date so a
    /// monthly series can be differenced against a quarterly one.
    @Test func spreadSubtractsOnTheMinuendDateGrid() {
        let tenYear = Fixture.monthly(start: "2024-01-01", values: [4.0, 4.2, 4.1])
        let twoYear = Fixture.monthly(start: "2024-01-01", values: [4.5, 4.4, 3.9])

        let spread = SeriesAnalytics.spread(tenYear, minus: twoYear)

        #expect(spread.count == 3)
        #expect(abs(spread[0].value - (-0.5)) < 0.000_001)
        #expect(abs(spread[1].value - (-0.2)) < 0.000_001)
        #expect(abs(spread[2].value - 0.2) < 0.000_001)
        #expect(spread.map(\.date) == tenYear.map(\.date))
    }

    /// A quarterly value describes its whole quarter, so every month of that quarter must
    /// be differenced against it. Nearest-date matching dropped the third month.
    @Test func spreadCarriesALowerFrequencySeriesAcrossItsPeriod() {
        let monthly = Fixture.monthly(start: "2024-01-01", values: [10, 11, 12, 13, 14, 15])
        let quarterly = Fixture.points([("2024-01-01", 1), ("2024-04-01", 2)])

        let spread = SeriesAnalytics.spread(monthly, minus: quarterly)

        #expect(spread.count == 6)
        #expect(spread.map(\.value) == [9, 10, 11, 11, 12, 13])
    }

    /// A series that stopped publishing must not be carried forward for ever.
    @Test func spreadStopsCarryingAfterOnePeriod() {
        let monthly = Fixture.monthly(start: "2024-01-01", values: [10, 11, 12, 13])
        let stale = Fixture.points([("2024-01-01", 1)])

        let spread = SeriesAnalytics.spread(monthly, minus: stale)

        // One observation has no measurable cadence, so it is carried a single day.
        #expect(spread.count == 1)
        #expect(spread[0].value == 9)
    }

    /// Minuend points that predate every subtrahend observation are dropped, never
    /// extrapolated backwards.
    @Test func spreadDoesNotExtrapolateBackwards() {
        let monthly = Fixture.monthly(start: "2024-01-01", values: [10, 11, 12])
        let laterStart = Fixture.points([("2024-02-01", 1), ("2024-03-01", 2)])

        let spread = SeriesAnalytics.spread(monthly, minus: laterStart)

        #expect(spread.count == 2)
        #expect(spread[0].date == monthly[1].date)
        #expect(spread.map(\.value) == [10, 10])
    }

    /// Points with no counterpart inside tolerance are dropped rather than differenced
    /// against a stale value from months away.
    @Test func spreadDropsUnmatchablePoints() {
        let recent = Fixture.monthly(start: "2024-01-01", values: [10, 11])
        let ancient = Fixture.monthly(start: "1990-01-01", values: [1, 2])

        #expect(SeriesAnalytics.spread(recent, minus: ancient).isEmpty)
        #expect(SeriesAnalytics.spread([], minus: recent).isEmpty)
        #expect(SeriesAnalytics.spread(recent, minus: []).isEmpty)
    }

    @Test func recessionRunsBecomeShadeableIntervals() throws {
        let points = Fixture.monthly(start: "2019-11-01", values: [0, 0, 0, 0, 1, 1, 0, 0])
        let intervals = SeriesAnalytics.recessionIntervals(from: points)

        #expect(intervals.count == 1)
        let interval = try #require(intervals.first)
        #expect(interval.start == points[4].date)
        // Ends where the indicator returns to zero, so both flagged months are covered.
        #expect(interval.end == points[6].date)
    }

    /// An ongoing recession has no closing zero; the band must still cover its last month
    /// instead of collapsing to a zero-width line on the first of that month.
    @Test func anOngoingRecessionExtendsPastItsLastObservation() throws {
        let points = Fixture.monthly(start: "2024-01-01", values: [0, 1, 1])
        let intervals = SeriesAnalytics.recessionIntervals(from: points)

        let interval = try #require(intervals.first)
        #expect(interval.start == points[1].date)
        #expect(interval.end > points[2].date)
    }

    @Test func separateRecessionsProduceSeparateBands() {
        let points = Fixture.monthly(start: "2000-01-01", values: [1, 1, 0, 0, 1, 0])
        #expect(SeriesAnalytics.recessionIntervals(from: points).count == 2)
    }

    @Test func aSeriesWithoutRecessionsProducesNoBands() {
        #expect(SeriesAnalytics.recessionIntervals(from: Fixture.monthly(start: "2000-01-01", values: [0, 0, 0])).isEmpty)
        #expect(SeriesAnalytics.recessionIntervals(from: []).isEmpty)
    }

    @Test func bandsAreClippedToTheVisibleWindow() throws {
        let bands = [
            DateInterval(start: Fixture.date("2008-01-01"), end: Fixture.date("2009-07-01")),
            DateInterval(start: Fixture.date("2020-03-01"), end: Fixture.date("2020-05-01"))
        ]
        let window = DateInterval(start: Fixture.date("2009-01-01"), end: Fixture.date("2020-04-01"))

        let clipped = SeriesAnalytics.clip(bands, to: window)

        #expect(clipped.count == 2)
        #expect(clipped[0].start == window.start)
        #expect(clipped[0].end == bands[0].end)
        #expect(clipped[1].end == window.end)

        // A band entirely outside the window is dropped, not squashed to zero width.
        let narrow = DateInterval(start: Fixture.date("2015-01-01"), end: Fixture.date("2016-01-01"))
        #expect(SeriesAnalytics.clip(bands, to: narrow).isEmpty)
        #expect(SeriesAnalytics.clip(bands, to: nil).count == 2)
    }

    @Test func correlationDetectsPerfectRelationships() {
        let base = Fixture.monthly(start: "2024-01-01", values: [1, 2, 3, 4, 5])
        let same = Fixture.monthly(start: "2024-01-01", values: [2, 4, 6, 8, 10])
        let inverse = Fixture.monthly(start: "2024-01-01", values: [10, 8, 6, 4, 2])

        let positive = SeriesAnalytics.pearsonCorrelation(SeriesAnalytics.alignedPairs(base, same))
        let negative = SeriesAnalytics.pearsonCorrelation(SeriesAnalytics.alignedPairs(base, inverse))

        #expect(positive != nil)
        #expect(negative != nil)
        #expect(abs((positive ?? 0) - 1) < 0.000_001)
        #expect(abs((negative ?? 0) + 1) < 0.000_001)
    }

    /// A known fit: y = 2x + 1 with no noise must recover its own coefficients exactly.
    @Test func regressionRecoversAKnownFit() throws {
        let x = Fixture.monthly(start: "2024-01-01", values: [1, 2, 3, 4, 5])
        let y = Fixture.monthly(start: "2024-01-01", values: [3, 5, 7, 9, 11])

        // `alignedObservations` puts the first argument in `lhs`, which the regression
        // treats as the dependent series.
        let fit = try #require(SeriesAnalytics.linearRegression(SeriesAnalytics.alignedObservations(y, x)))

        #expect(abs(fit.slope - 2) < 0.000_001)
        #expect(abs(fit.intercept - 1) < 0.000_001)
        #expect(abs(fit.rSquared - 1) < 0.000_001)
        #expect(fit.sampleCount == 5)
    }

    @Test func regressionHandlesNegativeSlopesAndPartialFits() throws {
        let x = Fixture.monthly(start: "2024-01-01", values: [1, 2, 3, 4, 5, 6])
        let y = Fixture.monthly(start: "2024-01-01", values: [10, 8, 7, 5, 4, 2])

        let fit = try #require(SeriesAnalytics.linearRegression(SeriesAnalytics.alignedObservations(y, x)))

        #expect(fit.slope < 0)
        #expect(fit.rSquared > 0.95)
        #expect(fit.rSquared <= 1)
        #expect(fit.isSlopeDistinguishableFromZero)
    }

    /// A fit needs variation in x and enough points to be defined at all.
    @Test func regressionIsUndefinedWithoutVariationOrData() {
        let x = Fixture.monthly(start: "2024-01-01", values: [5, 5, 5, 5])
        let y = Fixture.monthly(start: "2024-01-01", values: [1, 2, 3, 4])

        #expect(SeriesAnalytics.linearRegression(SeriesAnalytics.alignedObservations(y, x)) == nil)

        let tooFew = Fixture.monthly(start: "2024-01-01", values: [1, 2])
        #expect(SeriesAnalytics.linearRegression(SeriesAnalytics.alignedObservations(tooFew, tooFew)) == nil)
        #expect(SeriesAnalytics.linearRegression([]) == nil)
    }

    /// A slope smaller than its own uncertainty must not be presented as a finding.
    @Test func aNoisySlopeIsFlaggedAsIndistinguishableFromZero() throws {
        let x = Fixture.monthly(start: "2024-01-01", values: [1, 2, 3, 4, 5, 6, 7, 8])
        let y = Fixture.monthly(start: "2024-01-01", values: [5, -3, 6, -2, 4, -4, 5, -3])

        let fit = try #require(SeriesAnalytics.linearRegression(SeriesAnalytics.alignedObservations(y, x)))

        #expect(fit.isSlopeDistinguishableFromZero == false)
        #expect(fit.interpretation(xUnits: "Percent", yUnits: "Percent").contains("suggestive at best"))
    }

    /// Alignment keeps the date so a scatter can shade by time.
    @Test func alignedObservationsKeepTheirDates() {
        let lhs = Fixture.monthly(start: "2024-01-01", values: [1, 2, 3])
        let rhs = Fixture.monthly(start: "2024-01-01", values: [10, 20, 30])

        let aligned = SeriesAnalytics.alignedObservations(lhs, rhs)

        #expect(aligned.count == 3)
        #expect(aligned.map(\.date) == lhs.map(\.date))
        #expect(aligned[1].lhs == 2)
        #expect(aligned[1].rhs == 20)
        // The pair-only helper stays consistent with the dated one.
        #expect(SeriesAnalytics.alignedPairs(lhs, rhs).map(\.0) == [1, 2, 3])
    }

    @Test func correlationIsUndefinedForConstantSeries() {
        let base = Fixture.monthly(start: "2024-01-01", values: [1, 2, 3, 4])
        let flat = Fixture.monthly(start: "2024-01-01", values: [7, 7, 7, 7])

        #expect(SeriesAnalytics.pearsonCorrelation(SeriesAnalytics.alignedPairs(base, flat)) == nil)
        #expect(SeriesAnalytics.pearsonCorrelation([(1, 2), (2, 4)]) == nil)
    }

    /// Monthly and quarterly series never share a calendar, so alignment is by nearest
    /// date rather than exact match.
    @Test func alignmentPairsDifferentCadences() {
        let monthly = Fixture.monthly(start: "2020-01-01", values: (0..<24).map(Double.init))
        let quarterly = Fixture.points([
            ("2020-01-01", 0), ("2020-04-01", 3), ("2020-07-01", 6), ("2020-10-01", 9)
        ])

        let pairs = SeriesAnalytics.alignedPairs(monthly, quarterly)

        #expect(pairs.count == 4)
        #expect(pairs.allSatisfy { $0.0 == $0.1 })
    }
}

// MARK: - Statistics

struct StatisticsTests {

    @Test func statisticsSummariseAWindow() throws {
        let points = Fixture.monthly(start: "2020-01-01", values: [10, 20, 30, 40])
        let statistics = try #require(SeriesStatistics.make(points: points, units: "Index"))

        #expect(statistics.count == 4)
        #expect(statistics.minimum == 10)
        #expect(statistics.maximum == 40)
        #expect(statistics.mean == 25)
        #expect(statistics.median == 25)
        #expect(statistics.firstValue == 10)
        #expect(statistics.latestValue == 40)
        #expect(statistics.previousValue == 30)
        #expect(statistics.latestChange == 10)
        #expect(statistics.totalChange == 30)
        #expect(statistics.range == 30)
    }

    @Test func medianUsesTheMiddleOfOddSamples() throws {
        let points = Fixture.monthly(start: "2020-01-01", values: [5, 1, 3])
        let statistics = try #require(SeriesStatistics.make(points: points, units: ""))
        #expect(statistics.median == 3)
    }

    /// A one-observation window genuinely has no prior reading; reporting `nil` beats
    /// substituting a placeholder that reads like data.
    @Test func singleObservationHasNoChangeMetrics() throws {
        let statistics = try #require(SeriesStatistics.make(points: Fixture.monthly(start: "2020-01-01", values: [42]), units: ""))

        #expect(statistics.previousValue == nil)
        #expect(statistics.latestChange == nil)
        #expect(statistics.latestPercentChange == nil)
        #expect(statistics.formattedLatestChange == "n/a")
        #expect(statistics.formattedPercentChange == "n/a")
        #expect(statistics.rangePosition == nil)
        #expect(statistics.annualizedChange == nil)
    }

    @Test func emptyWindowProducesNoStatistics() {
        #expect(SeriesStatistics.make(points: [], units: "Index") == nil)
    }

    @Test func compoundGrowthMatchesTheClosedForm() throws {
        let points = Fixture.points([("2015-01-01", 100), ("2025-01-01", 200)])
        let statistics = try #require(SeriesStatistics.make(points: points, units: "Index"))
        let annualized = try #require(statistics.annualizedChange)

        // 2^(1/10) - 1 ≈ 7.177%
        #expect(abs(annualized - 7.177) < 0.05)
        #expect(statistics.formattedAnnualizedChange.hasPrefix("+"))
        #expect(statistics.formattedAnnualizedChange.hasSuffix("/ yr"))
    }

    /// Compounding across a sign change is not a meaningful growth rate.
    @Test func compoundGrowthIsUndefinedAcrossZero() throws {
        let points = Fixture.points([("2015-01-01", -5), ("2025-01-01", 5)])
        let statistics = try #require(SeriesStatistics.make(points: points, units: "Percent"))
        #expect(statistics.annualizedChange == nil)
        #expect(statistics.formattedAnnualizedChange == "n/a")
    }

    @Test func drawdownMeasuresThePeakToTroughDecline() {
        #expect(abs((SeriesStatistics.maxDrawdown([100, 120, 60, 90]) ?? 0) - 50) < 0.000_001)
        #expect(SeriesStatistics.maxDrawdown([100, 110, 120]) == nil)
        #expect(SeriesStatistics.maxDrawdown([1, -1, 2]) == nil)
        #expect(SeriesStatistics.maxDrawdown([5]) == nil)
    }

    /// Dispersion previously printed unscaled while every other figure was scaled, so a
    /// GDP window reported a mean of "$29.0T" beside a standard deviation of "1,234.56".
    @Test func dispersionIsScaledLikeEveryOtherFigure() throws {
        let points = Fixture.monthly(start: "2020-01-01", values: [1_000, 3_000])
        let statistics = try #require(SeriesStatistics.make(points: points, units: "Billions of Dollars"))

        #expect(statistics.formattedMean.contains("T"))
        #expect(statistics.formattedStdDev.contains("B") || statistics.formattedStdDev.contains("T"))
    }

    @Test func signedFormattingUsesExplicitSigns() throws {
        let up = try #require(SeriesStatistics.make(points: Fixture.monthly(start: "2020-01-01", values: [10, 12]), units: ""))
        let down = try #require(SeriesStatistics.make(points: Fixture.monthly(start: "2020-01-01", values: [12, 10]), units: ""))

        #expect(up.formattedLatestChange.hasPrefix("+"))
        #expect(up.formattedPercentChange == "+20.00%")
        #expect(down.formattedLatestChange.hasPrefix("-"))
        #expect(down.formattedPercentChange == "-16.67%")
    }
}

// MARK: - Export

struct ExportTests {

    private func payload(transform: SeriesTransform = .level) -> ExportPayload {
        ExportPayload(
            generatedAt: Fixture.date("2026-01-05"),
            rangeLabel: "5 Years",
            transform: transform,
            columns: [
                ExportPayload.SeriesColumn(
                    series: Fixture.series(id: "GDP", title: "Gross Domestic Product", units: "Billions of Dollars"),
                    points: Fixture.points([("2024-01-01", 100.5), ("2024-04-01", 101.25)])
                ),
                ExportPayload.SeriesColumn(
                    series: Fixture.series(id: "UNRATE", title: "Unemployment Rate", units: "Percent"),
                    points: Fixture.points([("2024-04-01", 3.8)])
                )
            ]
        )
    }

    @Test func csvUsesOneColumnPerVisibleSeries() {
        let csv = ExportService.makeCSV(payload())
        let lines = csv.split(separator: "\n").map(String.init)

        #expect(lines.contains("Date,GDP,UNRATE"))
        #expect(lines.contains("2024-01-01,100.5,"))
        #expect(lines.contains("2024-04-01,101.25,3.8"))
        #expect(csv.contains("# Window: 5 Years"))
        #expect(csv.contains("# Transform: Level"))
        #expect(csv.contains("# Series: GDP — Gross Domestic Product"))
    }

    @Test func csvHeaderRecordsTransformedUnits() {
        let csv = ExportService.makeCSV(payload(transform: .yearOverYear))
        #expect(csv.contains("# Transform: YoY %"))
        #expect(csv.contains("[Percent;"))
    }

    @Test func csvFieldsAreEscapedPerRFC4180() {
        #expect(ExportService.csvField("plain") == "plain")
        #expect(ExportService.csvField("with,comma") == "\"with,comma\"")
        #expect(ExportService.csvField("say \"hi\"") == "\"say \"\"hi\"\"\"")
    }

    /// Large magnitudes must not be exported in scientific notation; spreadsheets
    /// import "1.82734e+13" as text.
    @Test func numbersAvoidScientificNotation() {
        #expect(ExportService.numberString(18_273_400_000_000) == "18273400000000")
        #expect(ExportService.numberString(29_016.714) == "29016.714")
        #expect(ExportService.numberString(-4.5) == "-4.5")
        #expect(ExportService.numberString(0) == "0")
        #expect(ExportService.numberString(.nan).isEmpty)
    }

    @Test func jsonCarriesMetadataAndEveryColumn() throws {
        let json = ExportService.makeJSON(payload())
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        let metadata = try #require(object["metadata"] as? [String: Any])
        #expect(metadata["window"] as? String == "5 Years")
        #expect(metadata["transform"] as? String == "Level")

        let series = try #require(object["series"] as? [[String: Any]])
        #expect(series.count == 2)
        #expect(series[0]["id"] as? String == "GDP")
        #expect((series[0]["observations"] as? [[String: Any]])?.count == 2)
    }

    @Test func clipboardTextIsTabSeparated() {
        let text = ExportService.makeClipboardText(payload())
        let lines = text.split(separator: "\n").map(String.init)

        #expect(lines[0] == "Date\tGDP\tUNRATE")
        #expect(lines[2] == "2024-04-01\t101.25\t3.8")
    }

    @Test func filenamesDropPathSeparators() {
        #expect(ExportService.sanitizedFilename("GDP/2024") == "GDP-2024")
        #expect(ExportService.sanitizedFilename("   ") == "fred-export")
    }

    @Test func emptyPayloadIsDetected() {
        let empty = ExportPayload(rangeLabel: "All Time", transform: .level, columns: [])
        #expect(empty.isEmpty)
    }
}

// MARK: - Chart Image Export

@MainActor
struct ChartImageExportTests {

    private func makeViewModel() async -> SeriesDetailViewModel {
        let series = Fixture.series(id: "GDP", title: "Gross Domestic Product", units: "Billions of Dollars", frequency: "Quarterly", frequencyShort: "Q")
        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            showsRecessionShading: false,
            loader: Fixture.loader([series.id: Fixture.monthly(start: "2020-01-01", values: (0..<24).map(Double.init))]),
            recessionLoader: { [] },
            relationsLoader: { SeriesRelations(seriesID: $0) }
        )
        await viewModel.loadData()
        return viewModel
    }

    /// Renders for real and checks the PNG magic number, so a broken renderer cannot pass
    /// as "compiles fine".
    @Test func chartRendersToRealPNGBytes() async {
        let viewModel = await makeViewModel()
        let snapshot = ChartSnapshotView(viewModel: viewModel, size: CGSize(width: 600, height: 400))

        guard let data = ExportService.pngData(from: snapshot, scale: 1) else {
            Issue.record("The chart produced no PNG data")
            return
        }

        #expect(data.count > 1_000)
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// PDF output must be a real single-page document, not an empty container.
    @Test func chartRendersToRealPDFBytes() async {
        let viewModel = await makeViewModel()
        let size = CGSize(width: 600, height: 400)
        let snapshot = ChartSnapshotView(viewModel: viewModel, size: size)

        guard let data = ExportService.pdfData(from: snapshot, size: size) else {
            Issue.record("The chart produced no PDF data")
            return
        }

        #expect(data.count > 1_000)
        #expect(Array(data.prefix(5)) == Array("%PDF-".utf8))

        let document = PDFishDocument(data: data)
        #expect(document.pageCount == 1)
    }

    /// The exported image has to stand on its own, so its subtitle names every choice
    /// behind the picture.
    @Test func exportSubtitleNamesEveryChoice() async {
        let viewModel = await makeViewModel()

        let level = viewModel.chartExportSubtitle
        #expect(level.contains("GDP"))
        #expect(level.contains("All Time"))
        #expect(level.contains("Level"))
        #expect(level.contains("U.S. Dollars"))

        viewModel.updateTransform(.yearOverYear)
        viewModel.updateMovingAverage(.medium)
        let transformed = viewModel.chartExportSubtitle
        #expect(transformed.contains("YoY %"))
        #expect(transformed.contains("moving average"))
        #expect(transformed.contains("Percent"))

        viewModel.applyCustomWindow(start: Fixture.date("2020-04-01"), end: Fixture.date("2020-09-01"))
        #expect(viewModel.chartExportSubtitle.contains("–"))

        #expect(viewModel.chartExportAttribution.contains("Federal Reserve Bank of St. Louis"))
    }

    @Test func exportFilenameIsSharedAndFileSystemSafe() async {
        let viewModel = await makeViewModel()

        #expect(viewModel.exportFilenameStem == "gdp-all-time-level")
        #expect(viewModel.exportFilenameStem.contains(" ") == false)

        viewModel.updateTransform(.periodPercentChange)
        #expect(viewModel.exportFilenameStem.contains("%-chg"))
        #expect(ExportService.sanitizedFilename(viewModel.exportFilenameStem).contains("/") == false)
    }

    @Test func imageFormatsDeclareTheirExtensions() {
        #expect(ChartImageFormat.png.fileExtension == "png")
        #expect(ChartImageFormat.pdf.fileExtension == "pdf")
        #expect(ChartImageFormat.allCases.count == 2)
    }
}

/// Minimal PDF page counter, so the test does not need PDFKit just to prove the render
/// produced a page.
private struct PDFishDocument {
    let pageCount: Int

    init(data: Data) {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else {
            pageCount = 0
            return
        }
        pageCount = document.numberOfPages
    }
}

// MARK: - Errors

struct FREDErrorTests {

    @Test func errorsExplainThemselves() {
        #expect(FREDError.missingAPIKey.errorDescription?.contains("API key") == true)
        #expect(FREDError.missingAPIKey.recoverySuggestion != nil)
        #expect(FREDError.rateLimited.recoverySuggestion?.contains("120") == true)
        #expect(FREDError.invalidURL.errorDescription?.contains("URL") == true)
        #expect(FREDError.apiError("Bad Request.").errorDescription == "Bad Request.")
    }

    @Test func describeAppendsRecoveryGuidance() {
        let description = SearchViewModel.describe(FREDError.missingAPIKey)
        #expect(description.contains("API key"))
        #expect(description.contains("fred.stlouisfed.org"))
    }
}

// MARK: - Search View Model

@MainActor
struct SearchViewModelTests {

    private func makeViewModel(
        results: [FREDSeries] = [Fixture.series(id: "GDP")],
        error: FREDError? = nil,
        recorded: RecordedSearches = RecordedSearches()
    ) -> (SearchViewModel, RecordedSearches) {
        let viewModel = SearchViewModel(
            debounce: .milliseconds(1),
            searcher: { _, _ in
                if let error { throw error }
                return results
            },
            recordRecentSearch: { recorded.append($0) }
        )
        return (viewModel, recorded)
    }

    @Test func searchPopulatesResultsAndRecordsTheQuery() async {
        let (viewModel, recorded) = makeViewModel()

        await viewModel.performSearch(query: "  gdp  ")

        #expect(viewModel.results.count == 1)
        #expect(viewModel.isLoading == false)
        #expect(viewModel.hasSearched)
        #expect(viewModel.errorMessage == nil)
        #expect(recorded.values == ["gdp"])
    }

    @Test func failedSearchesSurfaceAMessageAndRecordNothing() async {
        let (viewModel, recorded) = makeViewModel(error: .rateLimited)

        await viewModel.performSearch(query: "gdp")

        #expect(viewModel.results.isEmpty)
        #expect(viewModel.isLoading == false)
        #expect(viewModel.errorMessage?.contains("Rate limited") == true)
        #expect(recorded.values.isEmpty)
    }

    /// Clearing the query used to leave `isLoading` stuck at `true`, so the sidebar
    /// showed "Searching FRED…" forever.
    @Test func clearingResetsLoadingState() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.performSearch(query: "gdp")

        viewModel.clearResults()

        #expect(viewModel.isLoading == false)
        #expect(viewModel.hasSearched == false)
        #expect(viewModel.results.isEmpty)
        #expect(viewModel.canRefresh == false)
    }

    @Test func emptyQueriesDoNotSearch() async {
        let (viewModel, recorded) = makeViewModel()

        await viewModel.performSearch(query: "   ")

        #expect(viewModel.hasSearched == false)
        #expect(viewModel.isLoading == false)
        #expect(recorded.values.isEmpty)
    }

    /// A full page of results may not be all of them, and the sidebar says so.
    @Test func aFullResultPageIsReportedAsCapped() async {
        let recorded = RecordedSearches()
        let viewModel = SearchViewModel(
            resultLimit: 3,
            debounce: .milliseconds(1),
            searcher: { _, limit in (0..<limit).map { Fixture.series(id: "S\($0)") } },
            recordRecentSearch: { recorded.append($0) }
        )

        await viewModel.performSearch(query: "gdp")
        #expect(viewModel.results.count == 3)
        #expect(viewModel.resultsAreCapped)
        #expect(viewModel.resultLimitNotice.contains("3 most popular"))
    }

    @Test func debouncedTypingIssuesASingleSearch() async throws {
        let counter = CallCounter()
        let viewModel = SearchViewModel(
            debounce: .milliseconds(40),
            searcher: { _, _ in
                counter.increment()
                return [Fixture.series(id: "GDP")]
            },
            recordRecentSearch: { _ in }
        )

        for text in ["g", "gd", "gdp"] {
            viewModel.query = text
        }

        try await Task.sleep(for: .milliseconds(300))

        #expect(counter.count == 1)
        #expect(viewModel.isLoading == false)
        #expect(viewModel.results.count == 1)
    }
}

/// Collects the queries a view model reports as "recent".
final class RecordedSearches: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - Series Detail View Model

@MainActor
struct SeriesDetailViewModelTests {

    private var gdp: FREDSeries {
        Fixture.series(id: "GDP", title: "Gross Domestic Product", units: "Billions of Dollars", frequency: "Quarterly", frequencyShort: "Q")
    }

    private var annualHistory: [SeriesDataPoint] {
        Fixture.points([
            ("2017-01-01", 88), ("2019-01-01", 91), ("2021-01-01", 97),
            ("2023-01-01", 103), ("2025-01-01", 108)
        ])
    }

    @Test func initialHistoryProducesDerivedState() {
        let series = Fixture.series(id: "TEST", units: "Index", frequency: "Annual", frequencyShort: "A")
        let viewModel = SeriesDetailViewModel(
            series: series,
            initialHistory: [series.id: annualHistory],
            selectedRange: .tenYears,
            calendar: Fixture.calendar,
            loader: Fixture.loader([:])
        )

        #expect(viewModel.visibleObservationCount == 5)
        #expect(viewModel.chartPoints.count == 5)
        #expect(viewModel.statistics?.latestValue == 108)
        #expect(viewModel.displayUnits == "Index")
        #expect(viewModel.tableRows.first?.value == 108)
        #expect(viewModel.tableRows.count == 5)
    }

    /// The window is measured from the series' last observation, so switching ranges is
    /// purely local — the old build refetched from FRED on every range change.
    @Test func changingTheRangeReusesLoadedHistory() async {
        let counter = CallCounter()
        let series = Fixture.series(id: "TEST", units: "Index", frequency: "Annual", frequencyShort: "A")
        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .fiveYears,
            calendar: Fixture.calendar,
            loader: Fixture.loader([series.id: annualHistory], callCount: counter)
        )

        await viewModel.loadData()
        let fiveYearCount = viewModel.visibleObservationCount

        viewModel.updateRange(.tenYears)

        #expect(counter.count == 1)
        #expect(viewModel.selectedRange == .tenYears)
        #expect(viewModel.visibleObservationCount > fiveYearCount)
        #expect(viewModel.visibleObservationCount == 5)
    }

    /// Anchoring to "now" made every discontinued series render an empty chart.
    /// A custom interval narrows the whole surface, and exports record which window
    /// produced them.
    @Test func aCustomWindowNarrowsEverySurface() async {
        let series = Fixture.series(id: "TEST", units: "Index", frequency: "Monthly")
        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            showsRecessionShading: false,
            loader: Fixture.loader([series.id: Fixture.monthly(start: "2020-01-01", values: (0..<24).map(Double.init))]),
            recessionLoader: { [] },
            relationsLoader: { SeriesRelations(seriesID: $0) }
        )
        await viewModel.loadData()
        #expect(viewModel.visibleObservationCount == 24)

        let coverage = try? #require(viewModel.availableDateRange)
        #expect(coverage?.lowerBound == Fixture.date("2020-01-01"))

        viewModel.applyCustomWindow(start: Fixture.date("2020-04-01"), end: Fixture.date("2020-09-01"))

        #expect(viewModel.window.isCustom)
        #expect(viewModel.selectedRange == nil)
        #expect(viewModel.visibleObservationCount == 6)
        #expect(viewModel.statistics?.firstValue == 3)
        #expect(viewModel.statistics?.latestValue == 8)
        #expect(viewModel.tableRows.count == 6)
        #expect(viewModel.makeExportPayload().rangeLabel == viewModel.rangeLabel)
        #expect(viewModel.rangeLabel.contains("–"))

        // Returning to a preset restores the full span.
        viewModel.updateRange(.all)
        #expect(viewModel.window.isCustom == false)
        #expect(viewModel.visibleObservationCount == 24)
    }

    /// Endpoints beyond the loaded data are clamped rather than emptying the chart.
    @Test func aCustomWindowBeyondTheDataIsClampedToIt() async {
        let series = Fixture.series(id: "TEST", units: "Index", frequency: "Monthly")
        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            showsRecessionShading: false,
            loader: Fixture.loader([series.id: Fixture.monthly(start: "2020-01-01", values: [1, 2, 3])]),
            recessionLoader: { [] },
            relationsLoader: { SeriesRelations(seriesID: $0) }
        )
        await viewModel.loadData()

        viewModel.applyCustomWindow(start: Fixture.date("1990-01-01"), end: Fixture.date("2050-01-01"))

        #expect(viewModel.visibleObservationCount == 3)
        #expect(viewModel.isWindowEmpty == false)
    }

    @Test func discontinuedSeriesStillPopulateShortWindows() async {
        let series = Fixture.series(
            id: "OLD", units: "Index", frequency: "Monthly",
            observationStart: "2010-01-01", observationEnd: "2015-06-01"
        )
        let history = Fixture.monthly(start: "2010-01-01", values: (0..<66).map(Double.init))

        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .oneYear,
            calendar: Fixture.calendar,
            loader: Fixture.loader([series.id: history])
        )

        await viewModel.loadData()

        #expect(viewModel.visibleObservationCount > 0)
        #expect(viewModel.isWindowEmpty == false)
        #expect(viewModel.statistics?.latestValue == 65)
    }

    @Test func emptyWindowIsReportedSeparatelyFromFailure() async {
        let series = Fixture.series(id: "SPARSE", units: "Index", observationStart: "1950-01-01", observationEnd: "1950-02-01")
        let history = Fixture.points([("1950-01-01", 1), ("1950-02-01", 2)])

        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            loader: Fixture.loader([series.id: history])
        )
        await viewModel.loadData()
        #expect(viewModel.isWindowEmpty == false)

        // The whole series predates any window anchored after it, but "All Time" works.
        #expect(viewModel.hasLoadedHistory)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func transformsChangeTheDisplayedUnitsAndValues() async {
        let series = Fixture.series(id: "TEST", units: "Billions of Dollars", frequency: "Annual", frequencyShort: "A")
        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            loader: Fixture.loader([series.id: Fixture.points([
                ("2022-01-01", 100), ("2023-01-01", 110), ("2024-01-01", 121)
            ])])
        )
        await viewModel.loadData()

        #expect(viewModel.displayUnits == "Billions of Dollars")

        viewModel.updateTransform(.periodPercentChange)
        #expect(viewModel.displayUnits == "Percent")
        #expect(viewModel.visibleObservationCount == 2)
        #expect(abs((viewModel.statistics?.latestValue ?? 0) - 10) < 0.000_001)

        viewModel.updateTransform(.indexed)
        #expect(viewModel.displayUnits == "Index")
        #expect(viewModel.chartPoints.first?.value == 100)

        viewModel.updateTransform(.level)
        #expect(viewModel.displayUnits == "Billions of Dollars")
    }

    /// Growth transforms are computed on the full history, so the first visible point of
    /// a windowed growth chart is a real calculation rather than a dropped row.
    @Test func growthTransformsUseHistoryOutsideTheWindow() async {
        let series = Fixture.series(id: "TEST", units: "Index", frequency: "Annual", frequencyShort: "A")
        let history = Fixture.points([
            ("2018-01-01", 100), ("2019-01-01", 110), ("2020-01-01", 121),
            ("2021-01-01", 133.1), ("2022-01-01", 146.41), ("2023-01-01", 161.051)
        ])

        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .fiveYears,
            calendar: Fixture.calendar,
            loader: Fixture.loader([series.id: history])
        )
        await viewModel.loadData()
        viewModel.updateTransform(.periodPercentChange)

        // 2019-2023 fall inside a five-year window anchored at 2023, and every one of
        // them has a computable change because 2018 is still available upstream.
        #expect(viewModel.visibleObservationCount == 5)
        #expect(viewModel.chartPoints.allSatisfy { abs($0.value - 10) < 0.001 })
    }

    @Test func comparableCurrencySeriesShareOneAxis() async {
        let usGDP = Fixture.series(id: "GDP", title: "US GDP", units: "Billions of Dollars", frequency: "Quarterly", frequencyShort: "Q")
        let chinaGDP = Fixture.series(id: "CNGDP", title: "China GDP", units: "Current U.S. Dollars", frequency: "Annual", frequencyShort: "A")

        let viewModel = SeriesDetailViewModel(
            series: usGDP,
            comparisonSeries: [chinaGDP],
            selectedRange: .all,
            calendar: Fixture.calendar,
            loader: Fixture.loader([
                usGDP.id: Fixture.points([("2024-01-01", 29_016.714)]),
                chinaGDP.id: Fixture.points([("2024-01-01", 18_273_400_000_000)])
            ])
        )
        await viewModel.loadData()

        #expect(viewModel.transform == .level)
        #expect(viewModel.displayUnits == "U.S. Dollars")

        let usPoint = viewModel.chartPoints.first { $0.seriesId == usGDP.id }
        let chinaPoint = viewModel.chartPoints.first { $0.seriesId == chinaGDP.id }

        #expect(abs((usPoint?.value ?? 0) - 29_016_714_000_000) < 1)
        #expect(chinaPoint?.value == 18_273_400_000_000)
        let axisLabel = viewModel.valueFormatter.formatAxisValue(usPoint?.value ?? 0)
        #expect(axisLabel.contains("T"))
    }

    /// Percent and dollar series cannot honestly share a value axis, so adding one
    /// switches the chart to an index comparison instead of plotting mismatched scales.
    @Test func incompatibleUnitsSwitchToAnIndexComparison() async {
        let gdpSeries = gdp
        let unemployment = Fixture.series(id: "UNRATE", title: "Unemployment Rate", units: "Percent", frequency: "Monthly")

        let viewModel = SeriesDetailViewModel(
            series: gdpSeries,
            selectedRange: .all,
            calendar: Fixture.calendar,
            loader: Fixture.loader([
                gdpSeries.id: Fixture.points([("2024-01-01", 100), ("2024-04-01", 110)]),
                unemployment.id: Fixture.points([("2024-01-01", 4), ("2024-04-01", 3.8)])
            ])
        )
        await viewModel.loadData()
        #expect(viewModel.transform == .level)

        await viewModel.addSeries(unemployment)

        #expect(viewModel.transform == .indexed)
        #expect(viewModel.displayUnits == "Index")
        #expect(viewModel.unitsNotice?.isEmpty == false)
    }

    @Test func anExplicitTransformChoiceIsNotOverridden() async {
        let gdpSeries = gdp
        let unemployment = Fixture.series(id: "UNRATE", units: "Percent", frequency: "Monthly")

        let viewModel = SeriesDetailViewModel(
            series: gdpSeries,
            selectedRange: .all,
            calendar: Fixture.calendar,
            loader: Fixture.loader([
                gdpSeries.id: Fixture.points([("2024-01-01", 100), ("2024-04-01", 110)]),
                unemployment.id: Fixture.points([("2024-01-01", 4), ("2024-04-01", 3.8)])
            ])
        )
        await viewModel.loadData()
        viewModel.updateTransform(.level)

        await viewModel.addSeries(unemployment)

        #expect(viewModel.transform == .level)
        #expect(viewModel.unitsNotice?.contains("do not share units") == true)
    }

    /// One failing comparison series used to abort the whole batch and blank the chart.
    @Test func oneFailingComparisonSeriesDoesNotBlankTheChart() async {
        let gdpSeries = gdp
        let broken = Fixture.series(id: "BROKEN", units: "Billions of Dollars", frequency: "Quarterly", frequencyShort: "Q")

        let viewModel = SeriesDetailViewModel(
            series: gdpSeries,
            comparisonSeries: [broken],
            selectedRange: .all,
            calendar: Fixture.calendar,
            loader: Fixture.loader(
                [gdpSeries.id: Fixture.points([("2024-01-01", 100), ("2024-04-01", 110)])],
                failures: [broken.id: "No observations were returned for this series."]
            )
        )
        await viewModel.loadData()

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.warnings.count == 1)
        #expect(viewModel.warnings[0].contains("BROKEN"))
        #expect(viewModel.chartPoints.contains { $0.seriesId == gdpSeries.id })
        #expect(viewModel.visibleObservationCount == 2)
    }

    @Test func aFailingPrimarySeriesIsAHardError() async {
        let series = Fixture.series(id: "GONE")
        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            loader: Fixture.loader([:], failures: [series.id: "Series not found."])
        )
        await viewModel.loadData()

        #expect(viewModel.errorMessage == "Series not found.")
        #expect(viewModel.hasLoadedHistory == false)
        #expect(viewModel.chartPoints.isEmpty)
    }

    @Test func removingAComparisonSeriesDropsItsData() async {
        let gdpSeries = gdp
        let other = Fixture.series(id: "GNP", units: "Billions of Dollars", frequency: "Quarterly", frequencyShort: "Q")

        let viewModel = SeriesDetailViewModel(
            series: gdpSeries,
            comparisonSeries: [other],
            selectedRange: .all,
            calendar: Fixture.calendar,
            loader: Fixture.loader([
                gdpSeries.id: Fixture.points([("2024-01-01", 100), ("2024-04-01", 110)]),
                other.id: Fixture.points([("2024-01-01", 90), ("2024-04-01", 95)])
            ])
        )
        await viewModel.loadData()
        #expect(viewModel.allSeries.count == 2)
        #expect(viewModel.comparisonSummaries.count == 1)

        viewModel.removeSeries(id: other.id)

        #expect(viewModel.allSeries.count == 1)
        #expect(viewModel.comparisonSummaries.isEmpty)
        #expect(viewModel.chartPoints.allSatisfy { $0.seriesId == gdpSeries.id })

        // The primary series can never be removed.
        viewModel.removeSeries(id: gdpSeries.id)
        #expect(viewModel.allSeries.count == 1)
    }

    @Test func correlationIsReportedForComparisons() async {
        let base = Fixture.series(id: "A", units: "Index", frequency: "Monthly")
        let mirror = Fixture.series(id: "B", units: "Index", frequency: "Monthly")

        let viewModel = SeriesDetailViewModel(
            series: base,
            comparisonSeries: [mirror],
            selectedRange: .all,
            calendar: Fixture.calendar,
            loader: Fixture.loader([
                base.id: Fixture.monthly(start: "2024-01-01", values: [1, 2, 3, 4, 5]),
                mirror.id: Fixture.monthly(start: "2024-01-01", values: [5, 4, 3, 2, 1])
            ])
        )
        await viewModel.loadData()

        let summary = viewModel.comparisonSummaries.first
        #expect(summary?.overlappingObservations == 5)
        #expect(abs((summary?.correlation ?? 0) + 1) < 0.000_001)
        #expect(summary?.interpretation.contains("negative") == true)
    }

    @Test func movingAverageAddsASecondPlotSeries() async {
        let series = Fixture.series(id: "TEST", units: "Index", frequency: "Monthly", frequencyShort: "M")
        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            loader: Fixture.loader([series.id: Fixture.monthly(start: "2024-01-01", values: (0..<24).map(Double.init))])
        )
        await viewModel.loadData()
        #expect(viewModel.chartPoints.allSatisfy { $0.role == .observed })

        viewModel.updateMovingAverage(.medium)

        let overlay = viewModel.chartPoints.filter { $0.role == .movingAverage }
        #expect(!overlay.isEmpty)
        #expect(overlay[0].plotKey.hasSuffix("(avg)"))
        #expect(viewModel.movingAverageLabel == "3-period moving average")
    }

    /// Shading is a chart preference: turning it off must clear the bands, and turning it
    /// on must fetch the indicator without touching the series load.
    /// Spread mode must move the entire surface — chart, statistics, table, and export —
    /// or the numbers would contradict the chart.
    @Test func spreadModeDrivesEverySurface() async {
        let tenYear = Fixture.series(id: "DGS10", title: "10-Year Treasury", units: "Percent", frequency: "Monthly")
        let twoYear = Fixture.series(id: "DGS2", title: "2-Year Treasury", units: "Percent", frequency: "Monthly")

        let viewModel = SeriesDetailViewModel(
            series: tenYear,
            comparisonSeries: [twoYear],
            selectedRange: .all,
            calendar: Fixture.calendar,
            showsRecessionShading: false,
            loader: Fixture.loader([
                tenYear.id: Fixture.monthly(start: "2024-01-01", values: [4.0, 4.2, 4.1]),
                twoYear.id: Fixture.monthly(start: "2024-01-01", values: [4.5, 4.4, 3.9])
            ]),
            recessionLoader: { [] }
        )
        await viewModel.loadData()

        #expect(viewModel.canUseSpreadMode)
        #expect(viewModel.spreadUnavailableReason == nil)

        viewModel.updateChartMode(.spread)

        #expect(viewModel.chartMode == .spread)
        #expect(viewModel.chartSectionTitle.hasPrefix("Spread Chart"))
        #expect(viewModel.displayUnitsLabel == "Percentage Points")

        // One line, carrying the differences rather than either source series.
        let plotted = viewModel.chartPoints.filter { $0.role == .observed }
        #expect(plotted.count == 3)
        #expect(plotted.allSatisfy { $0.seriesTitle == "DGS10 − DGS2" })
        #expect(abs((plotted.first?.value ?? 0) - (-0.5)) < 0.000_001)

        // Statistics and the table describe the spread.
        #expect(abs((viewModel.statistics?.latestValue ?? 0) - 0.2) < 0.000_001)
        #expect(viewModel.visibleObservationCount == 3)
        #expect(viewModel.tableRows.first?.formattedValue.contains("pp") == true)

        // The export mirrors the chart.
        let payload = viewModel.makeExportPayload()
        #expect(payload.columns.count == 1)
        #expect(payload.columns[0].id == "DGS10-DGS2")
        #expect(abs(payload.columns[0].points[0].value - (-0.5)) < 0.000_001)

        // Correlation compares source series, which the spread has already collapsed.
        #expect(viewModel.comparisonSummaries.isEmpty)
    }

    /// Differencing a rate against a dollar figure is meaningless, so the mode is refused.
    @Test func spreadModeIsRefusedForIncompatibleUnits() async {
        let gdp = Fixture.series(id: "GDP", units: "Billions of Dollars", frequency: "Quarterly", frequencyShort: "Q")
        let rate = Fixture.series(id: "UNRATE", units: "Percent", frequency: "Monthly")

        let viewModel = SeriesDetailViewModel(
            series: gdp,
            comparisonSeries: [rate],
            selectedRange: .all,
            calendar: Fixture.calendar,
            showsRecessionShading: false,
            loader: Fixture.loader([
                gdp.id: Fixture.monthly(start: "2024-01-01", values: [100, 110]),
                rate.id: Fixture.monthly(start: "2024-01-01", values: [4, 3.8])
            ]),
            recessionLoader: { [] }
        )
        await viewModel.loadData()

        #expect(viewModel.canUseSpreadMode == false)
        #expect(viewModel.spreadUnavailableReason?.contains("same units") == true)

        viewModel.updateChartMode(.spread)
        #expect(viewModel.chartMode == .overlay)
    }

    /// Removing the series being subtracted leaves nothing to difference, so the chart
    /// must fall back rather than render an empty spread.
    @Test func spreadModeFallsBackWhenItsCounterpartIsRemoved() async {
        let tenYear = Fixture.series(id: "DGS10", units: "Percent", frequency: "Monthly")
        let twoYear = Fixture.series(id: "DGS2", units: "Percent", frequency: "Monthly")

        let viewModel = SeriesDetailViewModel(
            series: tenYear,
            comparisonSeries: [twoYear],
            selectedRange: .all,
            calendar: Fixture.calendar,
            showsRecessionShading: false,
            loader: Fixture.loader([
                tenYear.id: Fixture.monthly(start: "2024-01-01", values: [4.0, 4.2]),
                twoYear.id: Fixture.monthly(start: "2024-01-01", values: [4.5, 4.4])
            ]),
            recessionLoader: { [] }
        )
        await viewModel.loadData()
        viewModel.updateChartMode(.spread)
        #expect(viewModel.chartMode == .spread)

        viewModel.removeSeries(id: twoYear.id)

        #expect(viewModel.chartMode == .overlay)
        #expect(viewModel.spreadUnavailableReason?.contains("Add a comparison") == true)
        #expect(viewModel.visibleObservationCount == 2)
        #expect(viewModel.statistics?.latestValue == 4.2)
    }

    /// The relationship surface must follow the selected partner, and must clear itself
    /// when that partner is removed.
    @Test func scatterAndFitFollowTheSelectedPartner() async {
        let inflation = Fixture.series(id: "CPI", title: "Inflation", units: "Percent", frequency: "Monthly")
        let unemployment = Fixture.series(id: "UNRATE", title: "Unemployment", units: "Percent", frequency: "Monthly")
        let wages = Fixture.series(id: "WAGES", title: "Wage Growth", units: "Percent", frequency: "Monthly")

        let viewModel = SeriesDetailViewModel(
            series: inflation,
            comparisonSeries: [unemployment, wages],
            selectedRange: .all,
            calendar: Fixture.calendar,
            showsRecessionShading: false,
            loader: Fixture.loader([
                inflation.id: Fixture.monthly(start: "2024-01-01", values: [3, 5, 7, 9, 11]),
                unemployment.id: Fixture.monthly(start: "2024-01-01", values: [1, 2, 3, 4, 5]),
                wages.id: Fixture.monthly(start: "2024-01-01", values: [11, 9, 7, 5, 3])
            ]),
            recessionLoader: { [] },
            relationsLoader: { SeriesRelations(seriesID: $0) }
        )
        await viewModel.loadData()

        // Defaults to the first comparison series: CPI = 2 * UNRATE + 1.
        #expect(viewModel.regressionPartner?.id == "UNRATE")
        #expect(viewModel.scatterPoints.count == 5)
        #expect(abs((viewModel.regression?.slope ?? 0) - 2) < 0.000_001)
        #expect(viewModel.scatterXUnitsLabel == "Percent")
        #expect(viewModel.scatterYUnitsLabel == "Percent")

        viewModel.selectRegressionPartner(id: wages.id)
        #expect(viewModel.regressionPartner?.id == "WAGES")
        #expect((viewModel.regression?.slope ?? 0) < 0)

        viewModel.removeSeries(id: wages.id)
        #expect(viewModel.regressionPartner?.id == "UNRATE")
        #expect(abs((viewModel.regression?.slope ?? 0) - 2) < 0.000_001)

        viewModel.removeSeries(id: unemployment.id)
        #expect(viewModel.scatterPoints.isEmpty)
        #expect(viewModel.regression == nil)
    }

    /// Scatter axes use each series' own units, since the interesting scatters are
    /// exactly the ones whose series are not unit-comparable.
    @Test func scatterAxesLabelEachSeriesIndependently() async {
        let gdp = Fixture.series(id: "GDP", units: "Billions of Dollars", frequency: "Quarterly", frequencyShort: "Q")
        let rate = Fixture.series(id: "UNRATE", units: "Percent", frequency: "Monthly")

        let viewModel = SeriesDetailViewModel(
            series: gdp,
            comparisonSeries: [rate],
            selectedRange: .all,
            calendar: Fixture.calendar,
            showsRecessionShading: false,
            loader: Fixture.loader([
                gdp.id: Fixture.monthly(start: "2024-01-01", values: [100, 110, 120]),
                rate.id: Fixture.monthly(start: "2024-01-01", values: [4, 3.8, 3.6])
            ]),
            recessionLoader: { [] },
            relationsLoader: { SeriesRelations(seriesID: $0) }
        )
        await viewModel.loadData()

        #expect(viewModel.scatterYUnitsLabel == "U.S. Dollars")
        #expect(viewModel.scatterXUnitsLabel == "Percent")

        // Under a growth transform both axes become percent.
        viewModel.updateTransform(.periodPercentChange)
        #expect(viewModel.scatterYUnitsLabel == "Percent")
        #expect(viewModel.scatterXUnitsLabel == "Percent")
    }

    @Test func recessionShadingCanBeToggled() async {
        let series = Fixture.series(id: "TEST", units: "Index", frequency: "Monthly")
        let recession = Fixture.monthly(start: "2019-11-01", values: [0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0])

        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            showsRecessionShading: true,
            loader: Fixture.loader([series.id: Fixture.monthly(start: "2019-11-01", values: (0..<12).map(Double.init))]),
            recessionLoader: { recession }
        )
        await viewModel.loadData()

        #expect(viewModel.recessionIntervals.count == 1)

        await viewModel.setRecessionShading(false)
        #expect(viewModel.recessionIntervals.isEmpty)

        await viewModel.setRecessionShading(true)
        #expect(viewModel.recessionIntervals.count == 1)
    }

    /// A missing indicator is a cosmetic loss, never a load failure.
    @Test func anUnavailableRecessionIndicatorIsNotAnError() async {
        let series = Fixture.series(id: "TEST", units: "Index", frequency: "Monthly")
        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            showsRecessionShading: true,
            loader: Fixture.loader([series.id: Fixture.monthly(start: "2024-01-01", values: [1, 2, 3])]),
            recessionLoader: { [] }
        )
        await viewModel.loadData()

        #expect(viewModel.recessionIntervals.isEmpty)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.warnings.isEmpty)
        #expect(viewModel.visibleObservationCount == 3)
    }

    /// Bands are clipped to the plotted span so a decades-old recession cannot stretch
    /// the x-axis of a short window.
    @Test func recessionBandsNeverExtendBeyondThePlottedData() async {
        let series = Fixture.series(id: "TEST", units: "Index", frequency: "Monthly")
        let recession = Fixture.monthly(start: "2019-11-01", values: [0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0])

        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            showsRecessionShading: true,
            loader: Fixture.loader([series.id: Fixture.monthly(start: "2020-04-01", values: [1, 2, 3, 4])]),
            recessionLoader: { recession }
        )
        await viewModel.loadData()

        // The series starts in April 2020; the March–April band survives only as its
        // overlapping tail.
        for interval in viewModel.recessionIntervals {
            #expect(interval.start >= Fixture.date("2020-04-01"))
            #expect(interval.end <= Fixture.date("2020-07-01"))
        }
    }

    @Test func nearestPointLookupFindsTheClosestObservation() async {
        let series = Fixture.series(id: "TEST", units: "Index", frequency: "Monthly")
        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            loader: Fixture.loader([series.id: Fixture.monthly(start: "2024-01-01", values: [10, 20, 30])])
        )
        await viewModel.loadData()

        #expect(viewModel.nearestPoints(to: Fixture.date("2024-02-05")).first?.value == 20)
        #expect(viewModel.nearestPoints(to: Fixture.date("1900-01-01")).first?.value == 10)
        #expect(viewModel.nearestPoints(to: Fixture.date("2100-01-01")).first?.value == 30)
    }

    /// The chart is drawn in scaled units while the table and exports stay in published
    /// units; both labels must describe what their own surface actually shows.
    @Test func chartAndTableUnitLabelsDiffer() async {
        let series = Fixture.series(id: "GDP", units: "Billions of Dollars", frequency: "Quarterly", frequencyShort: "Q")
        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            loader: Fixture.loader([series.id: Fixture.points([("2024-01-01", 29_016.714)])])
        )
        await viewModel.loadData()

        #expect(viewModel.displayUnitsLabel == "U.S. Dollars")
        #expect(viewModel.publishedUnitsLabel == "Billions of Dollars")
        #expect(viewModel.chartSectionTitle == "Series Chart — U.S. Dollars")

        let row = try? #require(viewModel.tableRows.first)
        #expect(row?.formattedValue.contains("29,016.714") == true)

        // The export carries the published figure, matching the table exactly.
        let exported = ExportService.makeCSV(viewModel.makeExportPayload())
        #expect(exported.contains("29016.714"))
    }

    @Test func latestVisibleDateAvoidsBuildingTheTable() async {
        let series = Fixture.series(id: "TEST", units: "Index", frequency: "Monthly")
        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            loader: Fixture.loader([series.id: Fixture.monthly(start: "2024-01-01", values: [1, 2, 3])])
        )
        await viewModel.loadData()

        #expect(viewModel.latestVisibleDate == viewModel.tableRows.first?.date)
        #expect(viewModel.exportRowCount == 3)
    }

    @Test func tableRowsAreNewestFirstWithChanges() async {
        let series = Fixture.series(id: "TEST", units: "Index", frequency: "Monthly")
        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            loader: Fixture.loader([series.id: Fixture.monthly(start: "2024-01-01", values: [10, 20, 15])])
        )
        await viewModel.loadData()

        let rows = viewModel.tableRows
        #expect(rows.count == 3)
        #expect(rows[0].value == 15)
        #expect(rows[0].changeFromPrevious == -5)
        #expect(rows[0].formattedChange.hasPrefix("-"))
        #expect(rows[2].changeFromPrevious == nil)
        #expect(rows[2].formattedChange == "—")
    }

    @Test func exportPayloadMirrorsTheVisibleWindow() async {
        let series = Fixture.series(id: "TEST", units: "Index", frequency: "Monthly")
        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            loader: Fixture.loader([series.id: Fixture.monthly(start: "2024-01-01", values: [10, 20, 30])])
        )
        await viewModel.loadData()
        viewModel.updateTransform(.periodChange)

        let payload = viewModel.makeExportPayload()

        #expect(payload.transform == .periodChange)
        #expect(payload.rangeLabel == "All Time")
        #expect(payload.columns.count == 1)
        #expect(payload.columns[0].points.map(\.value) == [10, 10])
        #expect(payload.isEmpty == false)
    }

    @Test func chartIsDownsampledOnlyWhenItExceedsTheBudget() async {
        let series = Fixture.series(id: "BIG", units: "Index", frequency: "Daily", frequencyShort: "D")
        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            chartPointBudget: 200,
            loader: Fixture.loader([series.id: Fixture.monthly(start: "1900-01-01", values: (0..<2_000).map { Double($0 % 53) })])
        )
        await viewModel.loadData()

        #expect(viewModel.isChartDownsampled)
        #expect(viewModel.chartPoints.count <= 200)
        // Everything else still reports the full dataset.
        #expect(viewModel.visibleObservationCount == 2_000)
        #expect(viewModel.tableRows.count == 2_000)
        #expect(viewModel.makeExportPayload().columns[0].points.count == 2_000)
    }
}

// MARK: - Series Relations

@MainActor
struct SeriesRelationsTests {

    private func relations(
        seriesID: String = "GDP",
        related: [FREDSeries] = []
    ) -> SeriesRelations {
        SeriesRelations(
            seriesID: seriesID,
            categories: [FREDCategory(id: 106, name: "GDP/GNP", parentId: 18)],
            release: FREDRelease(id: 53, name: "Gross Domestic Product", pressRelease: true, link: "https://www.bea.gov/data/gdp/gross-domestic-product"),
            tags: [
                FREDTag(name: "usa", groupId: "geo", popularity: 100),
                FREDTag(name: "public domain: citation requested", groupId: "cc", popularity: 99),
                FREDTag(name: "gdp", groupId: "gen", popularity: 82)
            ],
            relatedSeries: related
        )
    }

    @Test func categoriesAndReleasesDecodeFromFREDShapes() throws {
        let categoryJSON = #"{"categories":[{"id":106,"name":"GDP/GNP","parent_id":18}]}"#
        let categories = try JSONDecoder().decode(FREDCategoriesResponse.self, from: Data(categoryJSON.utf8))
        #expect(categories.categories.first?.id == 106)
        #expect(categories.categories.first?.parentId == 18)

        let releaseJSON = #"{"releases":[{"id":53,"name":"Gross Domestic Product","press_release":true,"link":"https://www.bea.gov/data/gdp"}]}"#
        let releases = try JSONDecoder().decode(FREDReleasesResponse.self, from: Data(releaseJSON.utf8))
        #expect(releases.releases.first?.name == "Gross Domestic Product")
        #expect(releases.releases.first?.url != nil)

        let tagJSON = #"{"tags":[{"name":"usa","group_id":"geo","popularity":100}]}"#
        let tags = try JSONDecoder().decode(FREDTagsResponse.self, from: Data(tagJSON.utf8))
        #expect(tags.tags.first?.groupLabel == "Geography")
    }

    /// Licence and citation tags are noise in a research UI.
    @Test func onlyDescriptiveTagsAreSurfaced() {
        let descriptive = relations().descriptiveTags
        #expect(descriptive.map(\.name) == ["usa", "gdp"])
        #expect(descriptive.contains { $0.name.contains("citation") } == false)
    }

    /// Suggestions that can share an axis are worth more than merely popular ones.
    @Test func relatedSeriesRankComparableUnitsFirst() {
        let gdp = Fixture.series(id: "GDP", units: "Billions of Dollars", frequency: "Quarterly", frequencyShort: "Q")
        let popularButIncomparable = Fixture.series(id: "A191RL1Q225SBEA", units: "Percent Change from Preceding Period")
        let comparable = Fixture.series(id: "GNP", units: "Billions of Dollars", frequency: "Quarterly", frequencyShort: "Q")

        let ranked = relations(related: [popularButIncomparable, comparable]).relatedSeriesRanked(comparableWith: gdp)

        #expect(ranked.map(\.id) == ["GNP", "A191RL1Q225SBEA"])
    }

    @Test func relationsLoadLazilyAndOnlyOnce() async {
        let counter = CallCounter()
        let series = Fixture.series(id: "GDP", units: "Billions of Dollars", frequency: "Quarterly", frequencyShort: "Q")
        let sibling = Fixture.series(id: "GNP", units: "Billions of Dollars", frequency: "Quarterly", frequencyShort: "Q")

        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            showsRecessionShading: false,
            loader: Fixture.loader([series.id: Fixture.monthly(start: "2024-01-01", values: [1, 2, 3])]),
            recessionLoader: { [] },
            relationsLoader: { id in
                counter.increment()
                return SeriesRelations(seriesID: id, relatedSeries: [sibling])
            }
        )

        await viewModel.loadData()
        // Loading the series must not pay for the relations lookup.
        #expect(counter.count == 0)
        #expect(viewModel.relations == nil)

        await viewModel.loadRelationsIfNeeded()
        #expect(counter.count == 1)
        #expect(viewModel.suggestedRelatedSeries.map(\.id) == ["GNP"])

        await viewModel.loadRelationsIfNeeded()
        #expect(counter.count == 1)
    }

    /// A series already on the chart is not a useful suggestion.
    @Test func seriesAlreadyChartedAreNotSuggested() async {
        let series = Fixture.series(id: "GDP", units: "Billions of Dollars", frequency: "Quarterly", frequencyShort: "Q")
        let sibling = Fixture.series(id: "GNP", units: "Billions of Dollars", frequency: "Quarterly", frequencyShort: "Q")

        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            showsRecessionShading: false,
            loader: Fixture.loader([
                series.id: Fixture.monthly(start: "2024-01-01", values: [1, 2, 3]),
                sibling.id: Fixture.monthly(start: "2024-01-01", values: [4, 5, 6])
            ]),
            recessionLoader: { [] },
            relationsLoader: { id in SeriesRelations(seriesID: id, relatedSeries: [sibling]) }
        )

        await viewModel.loadData()
        await viewModel.loadRelationsIfNeeded()
        #expect(viewModel.suggestedRelatedSeries.count == 1)

        await viewModel.addSeries(sibling)
        #expect(viewModel.suggestedRelatedSeries.isEmpty)
    }

    /// Missing context is not an error; the section simply does not appear.
    @Test func absentRelationsAreEmptyRatherThanFatal() async {
        let series = Fixture.series(id: "OBSCURE")
        let viewModel = SeriesDetailViewModel(
            series: series,
            selectedRange: .all,
            calendar: Fixture.calendar,
            showsRecessionShading: false,
            loader: Fixture.loader([series.id: Fixture.monthly(start: "2024-01-01", values: [1, 2])]),
            recessionLoader: { [] },
            relationsLoader: { id in SeriesRelations(seriesID: id) }
        )

        await viewModel.loadData()
        await viewModel.loadRelationsIfNeeded()

        #expect(viewModel.relations?.isEmpty == true)
        #expect(viewModel.suggestedRelatedSeries.isEmpty)
        #expect(viewModel.errorMessage == nil)
    }
}

// MARK: - Settings

@MainActor
struct SettingsManagerTests {

    private func makeManager() -> (SettingsManager, UserDefaults, String) {
        let suiteName = "FRED-Ultra.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let account = "FRED_API_KEY_TEST_\(UUID().uuidString)"
        return (SettingsManager(defaults: defaults, keychainAccount: account), defaults, suiteName)
    }

    @Test func favoritesRoundTripThroughStorage() {
        let (manager, defaults, suite) = makeManager()
        defer { defaults.removePersistentDomain(forName: suite) }

        let series = Fixture.series(id: "GDP", title: "Gross Domestic Product")
        manager.addFavorite(series)

        #expect(manager.isFavorite("GDP"))
        #expect(manager.favorites.count == 1)

        // Adding twice must not duplicate.
        manager.addFavorite(series)
        #expect(manager.favorites.count == 1)

        manager.toggleFavorite(series)
        #expect(manager.isFavorite("GDP") == false)

        manager.addFavorite(series)
        let reloaded = SettingsManager(defaults: defaults, keychainAccount: "unused-\(UUID().uuidString)")
        #expect(reloaded.favorites.map(\.id) == ["GDP"])
    }

    @Test func recentSearchesDeduplicateAndCap() {
        let (manager, defaults, suite) = makeManager()
        defer { defaults.removePersistentDomain(forName: suite) }

        manager.addRecentSearch("gdp")
        manager.addRecentSearch("  unrate ")
        manager.addRecentSearch("GDP")

        #expect(manager.recentSearches == ["GDP", "unrate"])

        for index in 0..<20 {
            manager.addRecentSearch("query-\(index)")
        }
        #expect(manager.recentSearches.count == SettingsManager.maximumRecentSearches)
        #expect(manager.recentSearches.first == "query-19")

        manager.clearRecentSearches()
        #expect(manager.recentSearches.isEmpty)
    }

    @Test func blankQueriesAreIgnored() {
        let (manager, defaults, suite) = makeManager()
        defer { defaults.removePersistentDomain(forName: suite) }

        manager.addRecentSearch("   ")
        #expect(manager.recentSearches.isEmpty)
    }

    /// Migration is only meaningful if a preferences-stored key is still usable when the
    /// Keychain refuses the write, so the key must survive construction either way.
    @Test func aLegacyPreferencesKeyIsAdopted() {
        let suiteName = "FRED-Ultra.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("legacy-key-value", forKey: "FRED_API_KEY")
        let account = "FRED_API_KEY_TEST_\(UUID().uuidString)"
        let manager = SettingsManager(defaults: defaults, keychainAccount: account)

        #expect(manager.apiKey == "legacy-key-value")
        #expect(manager.hasValidAPIKey)
        #expect(manager.apiKeyStorage != .none)

        manager.clearAPIKey()
        #expect(manager.hasValidAPIKey == false)
        #expect(manager.apiKeyStorage == .none)
        #expect(defaults.string(forKey: "FRED_API_KEY") == nil)
    }
}

// MARK: - Display Models

struct DisplayModelTests {

    @Test func transformsDeclareTheirResultUnits() {
        #expect(SeriesTransform.level.resultUnits(baseUnits: "Percent") == "Percent")
        #expect(SeriesTransform.periodChange.resultUnits(baseUnits: "Index") == "Index")
        #expect(SeriesTransform.periodPercentChange.resultUnits(baseUnits: "Index") == "Percent")
        #expect(SeriesTransform.yearOverYear.resultUnits(baseUnits: "Billions of Dollars") == "Percent")
        #expect(SeriesTransform.indexed.resultUnits(baseUnits: "Percent") == "Index")

        #expect(SeriesTransform.level.isUnitNeutral == false)
        #expect(SeriesTransform.periodChange.isUnitNeutral == false)
        #expect(SeriesTransform.indexed.isUnitNeutral)
    }

    @Test func movingAverageWindowsScaleWithCadence() {
        #expect(MovingAverageOption.off.window(for: .monthly) == nil)
        #expect(MovingAverageOption.medium.window(for: .monthly) == 3)
        #expect(MovingAverageOption.long.window(for: .monthly) == 12)
        #expect(MovingAverageOption.medium.window(for: .daily) == 63)
        #expect(MovingAverageOption.short.window(for: .annual) == 2)
    }

    @Test func frequencyParsingPrefersTheShortCode() {
        #expect(SeriesFrequency.parse(short: "Q", long: "anything") == .quarterly)
        #expect(SeriesFrequency.parse(short: nil, long: "Monthly") == .monthly)
        #expect(SeriesFrequency.parse(short: nil, long: "Not stated") == .unknown)
        #expect(SeriesFrequency.quarterly.periodsPerYear == 4)
        #expect(SeriesFrequency.unknown.periodsPerYear == nil)
    }

    @Test func chartPointIdentityDistinguishesRoles() {
        let date = Fixture.date("2024-01-01")
        let observed = ChartDataPoint(seriesId: "A", seriesTitle: "A", date: date, value: 1)
        let averaged = ChartDataPoint(seriesId: "A", seriesTitle: "A", date: date, value: 1, role: .movingAverage)

        #expect(observed.id != averaged.id)
        #expect(observed.plotKey == "A")
        #expect(averaged.plotKey == "A (avg)")
    }

    /// Searching an exact identifier must surface that series first; popularity ranking
    /// otherwise buries a niche ID under its better-known relatives.
    @Test func exactIdentifierMatchesAreDetectedAndPromoted() {
        #expect(SearchQuery.looksLikeSeriesID("GDPC1"))
        #expect(SearchQuery.looksLikeSeriesID("MKTGDPCNA646NWDB"))
        #expect(SearchQuery.looksLikeSeriesID("DGS10"))
        #expect(SearchQuery.looksLikeSeriesID("gdp") == false)
        #expect(SearchQuery.looksLikeSeriesID("Real GDP") == false)
        #expect(SearchQuery.looksLikeSeriesID("2024") == false)
        #expect(SearchQuery.looksLikeSeriesID("") == false)

        let results = [
            Fixture.series(id: "GDP"),
            Fixture.series(id: "GDPC1"),
            Fixture.series(id: "GDPPOT")
        ]

        #expect(SearchQuery.promotingExactMatch(in: results, for: "GDPC1").map(\.id) == ["GDPC1", "GDP", "GDPPOT"])
        #expect(SearchQuery.promotingExactMatch(in: results, for: "gdpc1").map(\.id) == ["GDPC1", "GDP", "GDPPOT"])
        #expect(SearchQuery.promotingExactMatch(in: results, for: "GDP").map(\.id) == ["GDP", "GDPC1", "GDPPOT"])
        #expect(SearchQuery.promotingExactMatch(in: results, for: "unemployment").map(\.id) == ["GDP", "GDPC1", "GDPPOT"])
        #expect(SearchQuery.promotingExactMatch(in: [], for: "GDP").isEmpty)
    }

    /// `Table` needs a total order, and the oldest visible row has no prior observation.
    @Test func observationRowsExposeASortableChange() {
        let base = ObservationRow(
            date: Fixture.date("2024-01-01"), rawDate: "2024-01-01", formattedDate: "Jan 1, 2024",
            value: 10, formattedValue: "10", changeFromPrevious: nil, formattedChange: "—"
        )
        let next = ObservationRow(
            date: Fixture.date("2024-02-01"), rawDate: "2024-02-01", formattedDate: "Feb 1, 2024",
            value: 12, formattedValue: "12", changeFromPrevious: 2, formattedChange: "+2"
        )

        #expect(base.sortableChange == 0)
        #expect(next.sortableChange == 2)
    }

    @Test func comparisonSummaryExplainsWeakEvidence() {
        let sparse = ComparisonSummary(id: "A", seriesTitle: "A", overlappingObservations: 1, correlation: nil)
        #expect(sparse.formattedCorrelation == "n/a")
        #expect(sparse.interpretation.contains("Not enough"))

        let strong = ComparisonSummary(id: "B", seriesTitle: "B", overlappingObservations: 40, correlation: 0.92)
        #expect(strong.formattedCorrelation == "0.92")
        #expect(strong.interpretation.contains("Very strong positive"))
    }
}
