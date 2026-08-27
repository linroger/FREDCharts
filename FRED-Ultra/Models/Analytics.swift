import Foundation

// MARK: - Series Analytics

/// Pure, testable maths over parsed observations.
///
/// Everything here is deterministic and free of UI or networking concerns so the
/// numbers the app shows can be verified directly in unit tests.
enum SeriesAnalytics {

    // MARK: Transforms

    /// Applies a period-over-period transform.
    ///
    /// Called on the **full** history before windowing, so the first visible point of a
    /// growth-rate chart has a real predecessor instead of being silently dropped.
    /// `.level` and `.indexed` are returned unchanged — `.indexed` is rebased after
    /// windowing by `rebasedToOneHundred(_:)`.
    static func applyTransform(
        _ points: [SeriesDataPoint],
        transform: SeriesTransform,
        calendar: Calendar = .current
    ) -> [SeriesDataPoint] {
        switch transform {
        case .level, .indexed:
            return points
        case .periodChange:
            return periodDifference(points, asPercent: false)
        case .periodPercentChange:
            return periodDifference(points, asPercent: true)
        case .yearOverYear:
            return yearOverYearPercentChange(points, calendar: calendar)
        }
    }

    /// Difference against the immediately preceding observation.
    ///
    /// Percent changes divide by `abs(previous)` so a series crossing zero keeps the
    /// sign of the actual movement instead of flipping it.
    static func periodDifference(_ points: [SeriesDataPoint], asPercent: Bool) -> [SeriesDataPoint] {
        guard points.count > 1 else { return [] }

        var result: [SeriesDataPoint] = []
        result.reserveCapacity(points.count - 1)

        for index in 1..<points.count {
            let previous = points[index - 1].value
            let current = points[index].value
            let delta = current - previous

            if asPercent {
                guard previous != 0 else { continue }
                let percent = (delta / abs(previous)) * 100
                guard percent.isFinite else { continue }
                result.append(SeriesDataPoint(date: points[index].date, value: percent))
            } else {
                result.append(SeriesDataPoint(date: points[index].date, value: delta))
            }
        }

        return result
    }

    /// Percent change against the observation closest to exactly one year earlier.
    ///
    /// Matching by date rather than by a fixed index offset keeps the result correct for
    /// business-daily series, series with gaps, and series whose cadence changed.
    static func yearOverYearPercentChange(
        _ points: [SeriesDataPoint],
        calendar: Calendar = .current
    ) -> [SeriesDataPoint] {
        guard points.count > 1 else { return [] }

        // Half a reporting period keeps the match unambiguous: a wider window let an
        // annual series match its own observation 365 days away and report 0% growth.
        // The four-day floor absorbs weekends and holidays in business-daily series.
        let spacing = medianSpacing(points) ?? (365.25 * 86_400)
        let tolerance = Swift.max(spacing * 0.5, 4 * 86_400)

        var result: [SeriesDataPoint] = []
        result.reserveCapacity(points.count)

        // `searchIndex` only ever moves forward: targets increase monotonically with
        // the point being evaluated, so the whole pass stays O(n).
        var searchIndex = 0

        for point in points {
            guard let target = calendar.date(byAdding: .year, value: -1, to: point.date) else { continue }

            while searchIndex + 1 < points.count, points[searchIndex + 1].date <= target {
                searchIndex += 1
            }

            var bestIndex = searchIndex
            var bestDistance = abs(points[searchIndex].date.timeIntervalSince(target))

            if searchIndex + 1 < points.count {
                let distance = abs(points[searchIndex + 1].date.timeIntervalSince(target))
                if distance < bestDistance {
                    bestIndex = searchIndex + 1
                    bestDistance = distance
                }
            }

            guard bestDistance <= tolerance else { continue }

            let base = points[bestIndex].value
            guard base != 0 else { continue }

            let percent = ((point.value - base) / abs(base)) * 100
            guard percent.isFinite else { continue }

            result.append(SeriesDataPoint(date: point.date, value: percent))
        }

        return result
    }

    /// Rebases a windowed series so its first visible observation equals 100.
    static func rebasedToOneHundred(_ points: [SeriesDataPoint]) -> [SeriesDataPoint] {
        guard let base = points.first?.value, base != 0 else { return points }

        return points.compactMap { point in
            let value = (point.value / base) * 100
            guard value.isFinite else { return nil }
            return SeriesDataPoint(date: point.date, value: value)
        }
    }

    // MARK: Smoothing

    /// Trailing simple moving average. The first `window - 1` points have no full
    /// window and are omitted rather than averaged over a partial period.
    static func movingAverage(_ points: [SeriesDataPoint], window: Int) -> [SeriesDataPoint] {
        guard window > 1, points.count >= window else { return [] }

        var result: [SeriesDataPoint] = []
        result.reserveCapacity(points.count - window + 1)

        var runningSum = points.prefix(window).reduce(0.0) { $0 + $1.value }
        result.append(SeriesDataPoint(date: points[window - 1].date, value: runningSum / Double(window)))

        for index in window..<points.count {
            runningSum += points[index].value - points[index - window].value
            result.append(SeriesDataPoint(date: points[index].date, value: runningSum / Double(window)))
        }

        return result
    }

    // MARK: Downsampling

    /// Largest-Triangle-Three-Buckets downsampling.
    ///
    /// Swift Charts renders every mark it is given; a 60-year daily series is ~16k marks
    /// per redraw and drags the whole window. LTTB keeps peaks, troughs, and inflections
    /// that uniform sampling destroys, so the plotted shape stays faithful.
    static func downsample(_ points: [SeriesDataPoint], threshold: Int) -> [SeriesDataPoint] {
        guard threshold > 2, points.count > threshold else { return points }

        let bucketSize = Double(points.count - 2) / Double(threshold - 2)
        var sampled: [SeriesDataPoint] = [points[0]]
        sampled.reserveCapacity(threshold)

        var previousIndex = 0

        for bucket in 0..<(threshold - 2) {
            let nextRangeStart = Int((Double(bucket + 1) * bucketSize).rounded(.down)) + 1
            let nextRangeEnd = Swift.min(Int((Double(bucket + 2) * bucketSize).rounded(.down)) + 1, points.count - 1)

            // Average of the following bucket forms the third triangle vertex.
            var averageX = 0.0
            var averageY = 0.0
            var averageCount = 0
            var scanIndex = nextRangeStart
            while scanIndex < nextRangeEnd, scanIndex < points.count {
                averageX += points[scanIndex].date.timeIntervalSinceReferenceDate
                averageY += points[scanIndex].value
                averageCount += 1
                scanIndex += 1
            }

            if averageCount > 0 {
                averageX /= Double(averageCount)
                averageY /= Double(averageCount)
            } else {
                let fallback = points[Swift.min(nextRangeStart, points.count - 1)]
                averageX = fallback.date.timeIntervalSinceReferenceDate
                averageY = fallback.value
            }

            let rangeStart = Int((Double(bucket) * bucketSize).rounded(.down)) + 1
            let rangeEnd = Swift.min(Int((Double(bucket + 1) * bucketSize).rounded(.down)) + 1, points.count - 1)
            guard rangeStart < rangeEnd else { continue }

            let anchorX = points[previousIndex].date.timeIntervalSinceReferenceDate
            let anchorY = points[previousIndex].value

            var bestArea = -1.0
            var bestIndex = rangeStart

            for index in rangeStart..<rangeEnd {
                let pointX = points[index].date.timeIntervalSinceReferenceDate
                let pointY = points[index].value
                let area = abs((anchorX - averageX) * (pointY - anchorY) - (anchorX - pointX) * (averageY - anchorY)) / 2

                if area > bestArea {
                    bestArea = area
                    bestIndex = index
                }
            }

            sampled.append(points[bestIndex])
            previousIndex = bestIndex
        }

        sampled.append(points[points.count - 1])
        return sampled
    }

    // MARK: Windowing

    static func filter(_ points: [SeriesDataPoint], from startDate: Date?) -> [SeriesDataPoint] {
        guard let startDate else { return points }
        // Points are sorted, so the window is a suffix.
        guard let firstIndex = points.firstIndex(where: { $0.date >= startDate }) else { return [] }
        return Array(points[firstIndex...])
    }

    // MARK: Alignment & Correlation

    static func medianSpacing(_ points: [SeriesDataPoint]) -> TimeInterval? {
        guard points.count > 1 else { return nil }

        var gaps: [TimeInterval] = []
        gaps.reserveCapacity(points.count - 1)
        for index in 1..<points.count {
            gaps.append(points[index].date.timeIntervalSince(points[index - 1].date))
        }

        gaps.sort()
        let middle = gaps.count / 2
        if gaps.count.isMultiple(of: 2) {
            return (gaps[middle - 1] + gaps[middle]) / 2
        }
        return gaps[middle]
    }

    /// Pairs two series by nearest observation date.
    ///
    /// Economic series rarely share a calendar (monthly CPI vs quarterly GDP), so exact
    /// date joins would report "no overlap" for most real comparisons.
    static func alignedPairs(_ lhs: [SeriesDataPoint], _ rhs: [SeriesDataPoint]) -> [(Double, Double)] {
        guard !lhs.isEmpty, !rhs.isEmpty else { return [] }

        let lhsSpacing = medianSpacing(lhs) ?? 86_400
        let rhsSpacing = medianSpacing(rhs) ?? 86_400
        let tolerance = Swift.max(Swift.max(lhsSpacing, rhsSpacing) * 0.6, 86_400)

        // Drive the join from the sparser series so each of its points is used at most once.
        let driving = lhs.count <= rhs.count ? lhs : rhs
        let lookup = lhs.count <= rhs.count ? rhs : lhs
        let drivingIsLeft = lhs.count <= rhs.count

        var pairs: [(Double, Double)] = []
        pairs.reserveCapacity(driving.count)
        var searchIndex = 0

        for point in driving {
            while searchIndex + 1 < lookup.count,
                  abs(lookup[searchIndex + 1].date.timeIntervalSince(point.date))
                    <= abs(lookup[searchIndex].date.timeIntervalSince(point.date)) {
                searchIndex += 1
            }

            let candidate = lookup[searchIndex]
            guard abs(candidate.date.timeIntervalSince(point.date)) <= tolerance else { continue }

            pairs.append(drivingIsLeft ? (point.value, candidate.value) : (candidate.value, point.value))
        }

        return pairs
    }

    /// Pearson correlation of two aligned samples. `nil` when either sample is constant.
    static func pearsonCorrelation(_ pairs: [(Double, Double)]) -> Double? {
        guard pairs.count >= 3 else { return nil }

        let count = Double(pairs.count)
        let meanX = pairs.reduce(0.0) { $0 + $1.0 } / count
        let meanY = pairs.reduce(0.0) { $0 + $1.1 } / count

        var covariance = 0.0
        var varianceX = 0.0
        var varianceY = 0.0

        for (x, y) in pairs {
            let deltaX = x - meanX
            let deltaY = y - meanY
            covariance += deltaX * deltaY
            varianceX += deltaX * deltaX
            varianceY += deltaY * deltaY
        }

        guard varianceX > 0, varianceY > 0 else { return nil }

        let coefficient = covariance / (varianceX.squareRoot() * varianceY.squareRoot())
        return coefficient.isFinite ? Swift.min(Swift.max(coefficient, -1), 1) : nil
    }
}

// MARK: - Statistics

/// Descriptive statistics for the visible window of the primary series.
///
/// Optional fields are genuinely optional: a single-observation window has no change to
/// report, and a series that touches zero has no defined compound growth rate. Reporting
/// `nil` keeps the UI honest instead of substituting a placeholder that reads as data.
struct SeriesStatistics: Equatable, Sendable {
    let count: Int
    let minimum: Double
    let maximum: Double
    let mean: Double
    let median: Double
    let standardDeviation: Double
    let firstValue: Double
    let latestValue: Double
    let previousValue: Double?
    let spanYears: Double
    let annualizedChange: Double?
    let maxDrawdown: Double?
    let units: String

    init(
        count: Int,
        minimum: Double,
        maximum: Double,
        mean: Double,
        median: Double,
        standardDeviation: Double,
        firstValue: Double,
        latestValue: Double,
        previousValue: Double?,
        spanYears: Double,
        annualizedChange: Double?,
        maxDrawdown: Double?,
        units: String
    ) {
        self.count = count
        self.minimum = minimum
        self.maximum = maximum
        self.mean = mean
        self.median = median
        self.standardDeviation = standardDeviation
        self.firstValue = firstValue
        self.latestValue = latestValue
        self.previousValue = previousValue
        self.spanYears = spanYears
        self.annualizedChange = annualizedChange
        self.maxDrawdown = maxDrawdown
        self.units = units
    }

    /// Builds statistics from an already-windowed, already-transformed series.
    static func make(points: [SeriesDataPoint], units: String) -> SeriesStatistics? {
        guard let first = points.first, let last = points.last else { return nil }

        let values = points.map(\.value)
        let sorted = values.sorted()
        let count = values.count
        let mean = values.reduce(0, +) / Double(count)
        let variance = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(count)

        let median: Double
        if count.isMultiple(of: 2) {
            median = (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        } else {
            median = sorted[count / 2]
        }

        let spanYears = last.date.timeIntervalSince(first.date) / (365.25 * 86_400)

        // Compound annual growth only makes sense across a meaningful span between two
        // positive endpoints. Annualising a three-week move turns ordinary noise into a
        // triple-digit "growth rate", so short windows report no rate at all.
        var annualized: Double?
        if spanYears >= Self.minimumSpanYearsForCompounding, first.value > 0, last.value > 0 {
            let ratio = last.value / first.value
            let compounded = (pow(ratio, 1 / spanYears) - 1) * 100
            annualized = compounded.isFinite ? compounded : nil
        }

        return SeriesStatistics(
            count: count,
            minimum: sorted[0],
            maximum: sorted[count - 1],
            mean: mean,
            median: median,
            standardDeviation: variance.squareRoot(),
            firstValue: first.value,
            latestValue: last.value,
            previousValue: count >= 2 ? values[count - 2] : nil,
            spanYears: spanYears,
            annualizedChange: annualized,
            maxDrawdown: Self.maxDrawdown(values),
            units: units
        )
    }

    /// Shortest window over which annualising a total change is defensible.
    static let minimumSpanYearsForCompounding = 0.5

    /// Deepest peak-to-trough decline, in percent. Defined only for strictly positive
    /// series, where a percentage drawdown has a meaningful denominator.
    static func maxDrawdown(_ values: [Double]) -> Double? {
        guard values.count >= 2, values.allSatisfy({ $0 > 0 }) else { return nil }

        var peak = values[0]
        var worst = 0.0

        for value in values.dropFirst() {
            peak = Swift.max(peak, value)
            worst = Swift.max(worst, (peak - value) / peak * 100)
        }

        return worst > 0 ? worst : nil
    }

    // MARK: Derived values

    var range: Double { maximum - minimum }
    var totalChange: Double { latestValue - firstValue }

    var latestChange: Double? {
        guard let previousValue else { return nil }
        return latestValue - previousValue
    }

    var latestPercentChange: Double? {
        guard let previousValue, previousValue != 0 else { return nil }
        let percent = ((latestValue - previousValue) / abs(previousValue)) * 100
        return percent.isFinite ? percent : nil
    }

    /// Where the latest reading sits between the window's low and high, 0–100.
    var rangePosition: Double? {
        guard range > 0 else { return nil }
        return ((latestValue - minimum) / range) * 100
    }

    var latestZScore: Double? {
        guard standardDeviation > 0 else { return nil }
        return (latestValue - mean) / standardDeviation
    }

    // MARK: Formatting

    private var formatter: ValueFormatter { ValueFormatter(units: units) }

    var formattedLatestValue: String { formatter.formatValue(latestValue, compact: true) }
    var formattedFirstValue: String { formatter.formatValue(firstValue, compact: true) }
    var formattedMin: String { formatter.formatValue(minimum, compact: true) }
    var formattedMax: String { formatter.formatValue(maximum, compact: true) }
    var formattedMean: String { formatter.formatValue(mean, compact: true) }
    var formattedMedian: String { formatter.formatValue(median, compact: true) }
    var formattedStdDev: String { formatter.formatMagnitude(standardDeviation, compact: true) }
    var formattedRange: String { formatter.formatMagnitude(range, compact: true) }
    var formattedTotalChange: String { formatter.formatChange(totalChange, compact: true) }

    var formattedLatestChange: String {
        guard let latestChange else { return "n/a" }
        return formatter.formatChange(latestChange, compact: true)
    }

    var formattedPercentChange: String {
        guard let latestPercentChange else { return "n/a" }
        return ValueFormatter.formatPercent(latestPercentChange, signed: true)
    }

    var formattedAnnualizedChange: String {
        guard let annualizedChange else { return "n/a" }
        return ValueFormatter.formatPercent(annualizedChange, signed: true) + " / yr"
    }

    var formattedMaxDrawdown: String {
        guard let maxDrawdown else { return "n/a" }
        return "-" + ValueFormatter.formatPercent(maxDrawdown, fractionDigits: 1)
    }

    var formattedRangePosition: String {
        guard let rangePosition else { return "n/a" }
        return ValueFormatter.formatPercent(rangePosition, fractionDigits: 0)
    }

    var formattedZScore: String {
        guard let latestZScore else { return "n/a" }
        return String(format: "%+.2fσ", latestZScore)
    }

    var formattedSpan: String {
        guard spanYears > 0 else { return "single observation" }
        if spanYears < 1 {
            return String(format: "%.0f months", spanYears * 12)
        }
        return String(format: "%.1f years", spanYears)
    }
}
