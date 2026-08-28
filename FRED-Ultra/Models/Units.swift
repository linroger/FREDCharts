import Foundation

// MARK: - Unit Family

/// Broad category a FRED `units` string belongs to. The family decides how a value
/// is formatted and whether two series can be charted on a shared absolute axis.
enum UnitFamily: String, Equatable, Sendable {
    case currency
    case percent
    case index
    case persons
    case generic
}

/// Price basis for currency series. Nominal ("Billions of Dollars") and chained
/// ("Billions of Chained 2017 Dollars") values are *not* interchangeable, so the
/// basis participates in comparability checks.
enum CurrencyBasis: Equatable, Sendable {
    case nominal
    case chained(year: Int?)
    case real(year: Int?)
}

// MARK: - Unit Descriptor

/// Parsed interpretation of a FRED `units` string.
///
/// Parsing is pure and deterministic, so descriptors are cached by raw unit string
/// (`UnitDescriptor.cached(units:)`). Formatting and charting call this on every
/// value, and re-parsing per call was previously a measurable hot spot.
struct UnitDescriptor: Equatable, Sendable {
    let rawUnits: String
    let family: UnitFamily
    /// Multiplier that converts a raw observation into base units
    /// (e.g. 1_000_000_000 for "Billions of Dollars").
    let scale: Double
    let canonicalUnits: String
    let currencyBasis: CurrencyBasis?

    init(units: String) {
        rawUnits = units

        let normalized = Self.normalize(units)
        let parsedScale = Self.parseScale(from: normalized)

        if normalized.contains("percent") || normalized.contains("basis point") {
            family = .percent
            scale = 1
            canonicalUnits = "Percent"
            currencyBasis = nil
            return
        }

        if normalized.contains("index") {
            family = .index
            scale = 1
            canonicalUnits = "Index"
            currencyBasis = nil
            return
        }

        if normalized.contains("person") || normalized.contains("people") || normalized.contains("employee") {
            family = .persons
            scale = parsedScale
            canonicalUnits = "Persons"
            currencyBasis = nil
            return
        }

        if normalized.contains("dollar") {
            let basis = Self.parseCurrencyBasis(from: normalized)
            family = .currency
            scale = parsedScale
            currencyBasis = basis
            canonicalUnits = Self.canonicalCurrencyUnits(for: basis)
            return
        }

        family = .generic
        scale = parsedScale
        canonicalUnits = Self.canonicalGenericUnits(from: normalized, fallback: units)
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
    func isComparable(to other: UnitDescriptor) -> Bool {
        guard family == other.family else { return false }

        switch family {
        case .currency, .generic:
            return canonicalUnits == other.canonicalUnits
        case .percent, .index, .persons:
            return true
        }
    }

    // MARK: Parsing helpers

    private static func normalize(_ units: String) -> String {
        units
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ",", with: " ")
    }

    private static func parseScale(from normalized: String) -> Double {
        if normalized.contains("trillion") { return 1_000_000_000_000 }
        if normalized.contains("billion") { return 1_000_000_000 }
        if normalized.contains("million") { return 1_000_000 }
        if normalized.contains("thousand") { return 1_000 }
        return 1
    }

    private static func parseCurrencyBasis(from normalized: String) -> CurrencyBasis {
        if normalized.contains("chained") {
            return .chained(year: extractYear(from: normalized))
        }

        if normalized.contains("real") || normalized.contains("constant") {
            return .real(year: extractYear(from: normalized))
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

    private static func extractYear(from normalized: String) -> Int? {
        normalized
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { token -> Int? in
                guard token.count == 4, let year = Int(token), (1900...2100).contains(year) else { return nil }
                return year
            }
            .first
    }

    private static let magnitudeWords: Set<String> = [
        "thousand", "thousands", "million", "millions",
        "billion", "billions", "trillion", "trillions", "of"
    ]

    private static func canonicalGenericUnits(from normalized: String, fallback: String) -> String {
        let filtered = normalized
            .split(separator: " ")
            .filter { !magnitudeWords.contains(String($0)) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !filtered.isEmpty else { return fallback }

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
            return fixed(value, fractionDigits: compact ? 1 : 2) + "%"
        case .index:
            return fixed(value, fractionDigits: compact ? 1 : 2)
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
            return fixed(value, fractionDigits: 1) + "%"
        case .index:
            return fixed(value, fractionDigits: 1)
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
            return fixed(abs(value), fractionDigits: compact ? 1 : 2) + " pp"
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

        guard descriptor.family == .percent else { return signed }
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
