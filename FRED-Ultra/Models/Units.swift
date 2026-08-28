import Foundation

// MARK: - Unit Family

/// Broad category a FRED `units` string belongs to. The family decides how a value
/// is formatted and whether two series can be charted on a shared absolute axis.
enum UnitFamily: String, Equatable, Sendable {
    case currency
    case percent
    case index
    case persons
    /// Dimensionless ratios and proportions, which need more decimal places than a
    /// general count: a ratio of 0.0234 rounded to two places reads as 0.02.
    case ratio
    case generic
}

/// Price basis for currency series. Nominal ("Billions of Dollars") and deflated
/// ("Billions of Chained 2017 Dollars", "1982-84 CPI Adjusted Dollars") values are not
/// interchangeable, so the basis participates in comparability checks.
enum CurrencyBasis: Equatable, Sendable {
    case nominal
    case chained(year: Int?)
    case real(year: Int?)
}

// MARK: - Magnitude Parsing

/// Reads the magnitude prefix of a unit string and reduces it to a single multiplier.
///
/// FRED writes magnitudes in several forms — "Billions of Dollars", "Thousands",
/// "Hundreds of Millions", and occasionally a literal "1,000,000". Normalising all of
/// them to one base multiplier is what lets a series published in billions share an axis
/// with one published in dollars.
enum MagnitudeParser {
    private static let words: [String: Double] = [
        "ten": 10, "tens": 10,
        "hundred": 100, "hundreds": 100,
        "thousand": 1_000, "thousands": 1_000,
        "million": 1_000_000, "millions": 1_000_000,
        "billion": 1_000_000_000, "billions": 1_000_000_000,
        "trillion": 1_000_000_000_000, "trillions": 1_000_000_000_000
    ]

    /// Multiplier for a normalised token list.
    ///
    /// Handles chained words ("hundreds of millions" = 1e8), an explicit factor
    /// ("0.4 billion", "100 billions"), and a bare literal ("1000000 dollars"). Four-digit
    /// years are never treated as factors, so "2010 U.S. Dollars" keeps a scale of 1.
    static func scale(forTokens tokens: [String]) -> Double {
        var scale = 1.0
        var pendingFactor: Double?

        func flushPendingLiteral() {
            // A number with no magnitude word after it is only a scale if it is large
            // enough to be one: "1000000 dollars" yes, "2 dollars" no.
            if let pending = pendingFactor, pending >= 1_000 {
                scale *= pending
            }
            pendingFactor = nil
        }

        for token in tokens {
            if let magnitude = words[token] {
                scale *= (pendingFactor ?? 1) * magnitude
                pendingFactor = nil
                continue
            }

            if token == "of" { continue }

            if let number = numericValue(of: token) {
                flushPendingLiteral()
                pendingFactor = number
                continue
            }

            flushPendingLiteral()
        }

        flushPendingLiteral()
        return scale
    }

    /// Numeric value of a token, or `nil` when it is not a usable factor.
    /// Trailing plural "s" is accepted so "1,000,000s of Dollars" parses.
    static func numericValue(of token: String) -> Double? {
        var text = token
        if text.hasSuffix("s") { text.removeLast() }
        guard !text.isEmpty, text.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        guard let value = Double(text), value > 0, value.isFinite else { return nil }

        // A four-digit year is a price base, not a multiplier.
        if isYear(token) { return nil }
        return value
    }

    static func isYear(_ token: String) -> Bool {
        guard token.count == 4, let value = Int(token) else { return false }
        return (1900...2100).contains(value)
    }
}

// MARK: - Unit Descriptor

/// Parsed interpretation of a FRED `units` string.
///
/// Parsing is pure and deterministic, so descriptors are cached by raw unit string
/// (`UnitDescriptor.cached(units:)`). Formatting and charting call this on every value,
/// and re-parsing per call was previously a measurable hot spot.
struct UnitDescriptor: Equatable, Sendable {
    let rawUnits: String
    let family: UnitFamily
    /// Multiplier that converts a raw observation into base units
    /// (e.g. 1_000_000_000 for "Billions of Dollars").
    let scale: Double
    let canonicalUnits: String
    let currencyBasis: CurrencyBasis?
    /// The "per X" clause, if the unit is a rate. Two rates are only comparable when they
    /// are measured per the same thing.
    let denominator: String?

    init(units: String) {
        rawUnits = units

        // A rate's magnitude and family come from its numerator alone. Without this split
        // "Dollars per Million BTU" picks up "million" as a scale and renders $3.50 as
        // "$3.5M", and "Dollars per Hour" is judged interchangeable with "Billions of
        // Dollars".
        let (rawNumerator, rawDenominator) = Self.splitOnPer(units)
        denominator = rawDenominator

        let normalized = Self.normalize(rawNumerator)
        let tokens = normalized.split(separator: " ").map(String.init)
        let suffix = rawDenominator.map { " per \($0)" } ?? ""

        if normalized.contains("basis point") {
            // One basis point is a hundredth of a percent; normalising them onto the
            // percent base is what lets a 25bp move sit on an axis with a 0.25% move.
            family = .percent
            scale = 0.01
            canonicalUnits = "Percent" + suffix
            currencyBasis = nil
            return
        }

        if normalized.contains("percent") || normalized.contains("per cent") {
            family = .percent
            scale = 1
            canonicalUnits = "Percent" + suffix
            currencyBasis = nil
            return
        }

        // An index carries a base period ("Index 2017=100"); none of those digits is a
        // magnitude, so indexes never take a scale.
        if normalized.contains("index") {
            family = .index
            scale = 1
            canonicalUnits = "Index" + suffix
            currencyBasis = nil
            return
        }

        let parsedScale = MagnitudeParser.scale(forTokens: tokens)

        if normalized.contains("ratio") || normalized.contains("proportion") || normalized.contains("decimal") {
            family = .ratio
            scale = parsedScale
            canonicalUnits = "Ratio" + suffix
            currencyBasis = nil
            return
        }

        if normalized.contains("person") || normalized.contains("people") || normalized.contains("employee") {
            family = .persons
            scale = parsedScale
            canonicalUnits = "Persons" + suffix
            currencyBasis = nil
            return
        }

        if normalized.contains("dollar") || normalized.contains("cent") {
            let basis = Self.parseCurrencyBasis(from: normalized, tokens: tokens)
            family = .currency
            scale = parsedScale
            currencyBasis = basis
            canonicalUnits = Self.canonicalCurrencyUnits(for: basis) + suffix
            return
        }

        family = .generic
        scale = parsedScale
        canonicalUnits = Self.canonicalGenericUnits(
            from: normalized,
            fallback: rawNumerator,
            hasScale: parsedScale != 1
        ) + suffix
        currencyBasis = nil
    }

    /// True when `scale` actually changes a value, i.e. the raw units are abbreviated
    /// ("Millions of Dollars") rather than already expressed in base units.
    var appliesScaleConversion: Bool {
        abs(scale - 1) > 0.000_000_1
    }

    /// Units that describe a *scaled* value.
    ///
    /// `ValueFormatter` multiplies by `scale`, so a reading published in "Billions of
    /// Dollars" is rendered as "$29.0T" — dollars, not billions. Labelling that column
    /// with the raw units would overstate it by a factor of a billion. Where no scaling
    /// happens the raw string is kept because it carries more detail
    /// ("Index 1982-1984=100" rather than a bare "Index").
    var presentationUnits: String {
        appliesScaleConversion ? canonicalUnits : rawUnits
    }

    func convertedValue(_ rawValue: Double) -> Double {
        rawValue * scale
    }

    /// Two descriptors are comparable when their values can honestly share one axis.
    ///
    /// Rates must agree on their denominator: dollars per hour and dollars per gallon are
    /// both "dollars", and plotting them together would be meaningless.
    func isComparable(to other: UnitDescriptor) -> Bool {
        guard family == other.family else { return false }
        guard normalizedDenominator == other.normalizedDenominator else { return false }

        switch family {
        case .currency, .generic:
            return canonicalUnits == other.canonicalUnits
        case .percent, .index, .persons, .ratio:
            return true
        }
    }

    private var normalizedDenominator: String? {
        denominator.map { Self.normalize($0) }
    }

    // MARK: Parsing helpers

    /// Splits a unit string on its first " per " into numerator and denominator, using
    /// the original casing for the denominator so the label keeps FRED's own wording.
    static func splitOnPer(_ units: String) -> (numerator: String, denominator: String?) {
        guard let range = units.range(of: " per ", options: [.caseInsensitive]) else {
            return (units, nil)
        }

        let numerator = String(units[units.startIndex..<range.lowerBound])
        let denominator = String(units[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (numerator, denominator.isEmpty ? nil : denominator)
    }

    private static func normalize(_ units: String) -> String {
        // Digit-group separators are removed rather than replaced so "1,000,000" survives
        // as a single parsable token.
        let withoutGroupSeparators = units.replacingOccurrences(
            of: "(?<=\\d),(?=\\d)",
            with: "",
            options: .regularExpression
        )

        // Periods are dropped from abbreviations ("U.S." -> "us") but kept between digits,
        // or "0.4 Billion" would parse as 4 billion — an order of magnitude out.
        return withoutGroupSeparators
            .lowercased()
            .replacingOccurrences(
                of: "(?<![0-9])\\.|\\.(?![0-9])",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func parseCurrencyBasis(from normalized: String, tokens: [String]) -> CurrencyBasis {
        if normalized.contains("chained") {
            return .chained(year: extractYear(from: tokens))
        }

        // "1982-84 CPI Adjusted Dollars" and "2010 U.S. Dollars" are constant-dollar
        // series; treating them as nominal would put deflated and current values on one
        // axis.
        if normalized.contains("real") || normalized.contains("constant") || normalized.contains("adjusted") {
            return .real(year: extractYear(from: tokens))
        }

        if !normalized.contains("current"), let year = extractYear(from: tokens) {
            return .real(year: year)
        }

        return .nominal
    }

    private static func canonicalCurrencyUnits(for basis: CurrencyBasis) -> String {
        switch basis {
        case .nominal:
            return "U.S. Dollars"
        case .chained(let year):
            return year.map { "Chained \($0) Dollars" } ?? "Chained Dollars"
        case .real(let year):
            return year.map { "Real \($0) Dollars" } ?? "Real Dollars"
        }
    }

    private static func extractYear(from tokens: [String]) -> Int? {
        tokens.compactMap { token in
            MagnitudeParser.isYear(token) ? Int(token) : nil
        }.first
    }

    private static let magnitudeWords: Set<String> = [
        "ten", "tens", "hundred", "hundreds",
        "thousand", "thousands", "million", "millions",
        "billion", "billions", "trillion", "trillions", "of"
    ]

    private static func canonicalGenericUnits(from normalized: String, fallback: String, hasScale: Bool) -> String {
        let filtered = normalized
            .split(separator: " ")
            .filter { !magnitudeWords.contains(String($0)) && MagnitudeParser.numericValue(of: String($0)) == nil }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !filtered.isEmpty else {
            // A bare "Thousands" is a count with nothing left once the magnitude is
            // stripped. Keeping the raw string would label a scaled value "Thousands".
            return hasScale ? "Units" : fallback
        }

        return filtered
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - Descriptor Cache

/// Small thread-safe memo table for unit parsing. FRED exposes a bounded set of unit
/// strings, so an unbounded-but-reset dictionary is sufficient and avoids `NSCache`
/// object boxing.
private final class UnitDescriptorCache: @unchecked Sendable {
    static let shared = UnitDescriptorCache()

    private let lock = NSLock()
    private var storage: [String: UnitDescriptor] = [:]
    private static let capacity = 256

    func descriptor(for units: String) -> UnitDescriptor {
        lock.lock()
        defer { lock.unlock() }

        if let cached = storage[units] {
            return cached
        }

        let descriptor = UnitDescriptor(units: units)
        if storage.count >= Self.capacity {
            storage.removeAll(keepingCapacity: true)
        }
        storage[units] = descriptor
        return descriptor
    }
}

extension UnitDescriptor {
    static func cached(units: String) -> UnitDescriptor {
        UnitDescriptorCache.shared.descriptor(for: units)
    }
}

// MARK: - Value Formatting

/// Formats observation values for a single unit family.
///
/// Uses `FormatStyle` rather than `NumberFormatter` so instances are cheap, `Sendable`,
/// and safe to build per view update. `locale` is injectable so tests are deterministic.
struct ValueFormatter: Sendable {
    let descriptor: UnitDescriptor
    let locale: Locale
    /// True when every value being formatted is a difference rather than a level, as in
    /// spread mode. Differences between percentages are percentage points, and a level
    /// formatter would label them "%" — understating them by a factor of the base.
    let representsDifference: Bool

    init(units: String, locale: Locale = .autoupdatingCurrent, representsDifference: Bool = false) {
        self.descriptor = .cached(units: units)
        self.locale = locale
        self.representsDifference = representsDifference
    }

    init(descriptor: UnitDescriptor, locale: Locale = .autoupdatingCurrent, representsDifference: Bool = false) {
        self.descriptor = descriptor
        self.locale = locale
        self.representsDifference = representsDifference
    }

    /// Unit label used when a value represents a *difference* or a dispersion rather
    /// than a level. Differences between percentages are percentage points, and
    /// labelling them "%" would misstate the quantity by an order of magnitude.
    var deltaUnitLabel: String {
        descriptor.family == .percent ? "pp" : descriptor.canonicalUnits
    }

    func formatValue(_ value: Double, compact: Bool) -> String {
        guard value.isFinite else { return "—" }

        if representsDifference {
            return Self.sign(for: value) + formatMagnitude(value, compact: compact)
        }

        switch descriptor.family {
        case .percent:
            // Scaled so a basis-point series reads on the percent base: 25bp -> 0.25%.
            return fixed(descriptor.convertedValue(value), fractionDigits: compact ? 1 : 2) + "%"
        case .index:
            return fixed(value, fractionDigits: compact ? 1 : 2)
        case .ratio:
            return grouped(descriptor.convertedValue(value), fractionDigits: compact ? 2 : 4)
        case .currency:
            return formatCurrency(descriptor.convertedValue(value), compact: compact)
        case .persons, .generic:
            return formatCount(descriptor.convertedValue(value), compact: compact)
        }
    }

    func formatAxisValue(_ value: Double) -> String {
        guard value.isFinite else { return "" }

        // Axis labels stay unsigned for positives; a column of "+" reads as noise.
        if representsDifference {
            return Self.negativePrefix(value) + formatMagnitude(value, compact: true)
        }

        switch descriptor.family {
        case .percent:
            return fixed(descriptor.convertedValue(value), fractionDigits: 1) + "%"
        case .index:
            return fixed(value, fractionDigits: 1)
        case .ratio:
            return grouped(descriptor.convertedValue(value), fractionDigits: 2)
        case .currency:
            return formatCurrency(descriptor.convertedValue(value), compact: true)
        case .persons, .generic:
            return formatCount(descriptor.convertedValue(value), compact: true)
        }
    }

    /// Unsigned magnitude of a difference or dispersion, in delta units.
    func formatMagnitude(_ value: Double, compact: Bool) -> String {
        guard value.isFinite else { return "—" }

        if descriptor.family == .percent {
            return fixed(abs(descriptor.convertedValue(value)), fractionDigits: compact ? 1 : 2) + " pp"
        }

        return formatValue(abs(value), compact: compact)
    }

    /// Formats a delta with an explicit sign, in delta units.
    func formatChange(_ value: Double, compact: Bool) -> String {
        guard value.isFinite else { return "—" }
        return Self.sign(for: value) + formatMagnitude(value, compact: compact)
    }

    /// The value exactly as published, without magnitude scaling.
    ///
    /// Used by the Data tab and matched by every export, so a figure copied out of the
    /// table is the same figure FRED publishes and the same figure the CSV contains.
    func formatPrecise(_ value: Double) -> String {
        guard value.isFinite else { return "—" }

        let text = grouped(abs(value), fractionDigits: 6)
        let signed = Self.negativePrefix(value) + text

        // Published values are never rescaled here, so a basis-point series shows basis
        // points under a "Basis Points" header rather than a converted percentage.
        guard descriptor.family == .percent, !descriptor.appliesScaleConversion else { return signed }
        return representsDifference ? signed + " pp" : signed + "%"
    }

    /// Signed published-scale difference, matching `formatPrecise`.
    func formatPreciseChange(_ value: Double) -> String {
        guard value.isFinite else { return "—" }

        let magnitude = grouped(abs(value), fractionDigits: 6)
        let suffix = descriptor.family == .percent ? " pp" : ""
        return Self.sign(for: value) + magnitude + suffix
    }

    /// Human label for values produced by `formatValue` / `formatAxisValue`.
    var presentationUnits: String {
        guard representsDifference, descriptor.family == .percent else {
            return descriptor.presentationUnits
        }
        return "Percentage Points"
    }

    static func sign(for value: Double) -> String {
        if value > 0 { return "+" }
        if value < 0 { return "-" }
        return ""
    }

    /// Percent values always render through `String(format:)`, which is locale
    /// independent — the app shows economic percentages with a `.` decimal separator
    /// everywhere so figures stay copy-pasteable into spreadsheets and notes.
    static func formatPercent(_ value: Double, fractionDigits: Int = 2, signed: Bool = false) -> String {
        guard value.isFinite else { return "—" }
        let magnitude = String(format: "%.\(fractionDigits)f%%", signed ? abs(value) : value)
        return signed ? sign(for: value) + magnitude : magnitude
    }

    // MARK: Private

    private func fixed(_ value: Double, fractionDigits: Int) -> String {
        String(format: "%.\(fractionDigits)f", value)
    }

    /// Grouped decimal with *up to* `fractionDigits` decimals.
    private func grouped(_ value: Double, fractionDigits: Int) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(0...fractionDigits))
                .locale(locale)
        )
    }

    /// Grouped decimal with *exactly* `fractionDigits` decimals, so a compact magnitude
    /// reads "29.0T" rather than collapsing to "29T".
    private func groupedExact(_ value: Double, fractionDigits: Int) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(fractionDigits))
                .locale(locale)
        )
    }

    /// Only negatives are signed here. A level is not a delta, and prefixing "+" to
    /// every positive reading made ordinary values look like changes.
    private static func negativePrefix(_ value: Double) -> String {
        value < 0 ? "-" : ""
    }

    private func formatCurrency(_ value: Double, compact: Bool) -> String {
        let magnitude = abs(value)

        if compact || magnitude >= 1_000_000 {
            let (scaled, suffix) = Self.compactMagnitude(magnitude)
            if !suffix.isEmpty {
                return Self.negativePrefix(value) + "$" + groupedExact(scaled, fractionDigits: 1) + suffix
            }
        }

        return Self.negativePrefix(value) + "$" + grouped(magnitude, fractionDigits: compact ? 1 : 2)
    }

    private func formatCount(_ value: Double, compact: Bool) -> String {
        let magnitude = abs(value)

        if compact, magnitude >= 1_000_000 {
            let (scaled, suffix) = Self.compactMagnitude(magnitude)
            if !suffix.isEmpty {
                return Self.negativePrefix(value) + groupedExact(scaled, fractionDigits: 1) + suffix
            }
        }

        return Self.negativePrefix(value) + grouped(magnitude, fractionDigits: compact ? 1 : 2)
    }

    private static func compactMagnitude(_ value: Double) -> (value: Double, suffix: String) {
        switch abs(value) {
        case 1_000_000_000_000...:
            return (value / 1_000_000_000_000, "T")
        case 1_000_000_000...:
            return (value / 1_000_000_000, "B")
        case 1_000_000...:
            return (value / 1_000_000, "M")
        case 1_000...:
            return (value / 1_000, "K")
        default:
            return (value, "")
        }
    }
}
