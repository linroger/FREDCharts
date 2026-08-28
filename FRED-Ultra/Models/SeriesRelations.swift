import Foundation

// MARK: - Category

/// A node in FRED's category tree. Categories are how FRED groups series by subject —
/// "GDP/GNP", "Consumer Price Indexes" — and they are the most reliable source of
/// genuinely related series.
struct FREDCategory: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let parentId: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case parentId = "parent_id"
    }

    init(id: Int, name: String, parentId: Int? = nil) {
        self.id = id
        self.name = name
        self.parentId = parentId
    }
}

struct FREDCategoriesResponse: Codable, Sendable {
    let categories: [FREDCategory]
}

// MARK: - Release

/// The publication a series belongs to — "Gross Domestic Product", "Employment Situation".
/// Series from one release share a source, a schedule, and a revision cycle.
struct FREDRelease: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let pressRelease: Bool?
    let link: String?

    enum CodingKeys: String, CodingKey {
        case id, name, link
        case pressRelease = "press_release"
    }

    init(id: Int, name: String, pressRelease: Bool? = nil, link: String? = nil) {
        self.id = id
        self.name = name
        self.pressRelease = pressRelease
        self.link = link
    }

    var url: URL? {
        guard let link, let url = URL(string: link), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }
}

struct FREDReleasesResponse: Codable, Sendable {
    let releases: [FREDRelease]
}

// MARK: - Tag

/// A FRED tag. `groupId` distinguishes a source tag from a frequency or geography tag,
/// which is what makes tags readable rather than a flat keyword soup.
struct FREDTag: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }

    let name: String
    let groupId: String?
    let popularity: Int?

    enum CodingKeys: String, CodingKey {
        case name, popularity
        case groupId = "group_id"
    }

    init(name: String, groupId: String? = nil, popularity: Int? = nil) {
        self.name = name
        self.groupId = groupId
        self.popularity = popularity
    }

    /// Human label for the tag's group, or `nil` for groups not worth surfacing.
    var groupLabel: String? {
        switch groupId {
        case "src": return "Source"
        case "gen": return "Concept"
        case "geo": return "Geography"
        case "geot": return "Geography Type"
        case "rls": return "Release"
        case "seas": return "Seasonality"
        case "freq": return "Frequency"
        default: return nil
        }
    }

    /// Licence and citation tags are noise in a research UI.
    var isDescriptive: Bool {
        groupLabel != nil
    }
}

struct FREDTagsResponse: Codable, Sendable {
    let tags: [FREDTag]
}

// MARK: - Relations

/// Everything the app knows about how one series sits among the others.
struct SeriesRelations: Sendable, Equatable {
    let seriesID: String
    let categories: [FREDCategory]
    let release: FREDRelease?
    let tags: [FREDTag]
    /// Sibling series from the same category, most popular first, excluding the series
    /// itself.
    let relatedSeries: [FREDSeries]

    init(
        seriesID: String,
        categories: [FREDCategory] = [],
        release: FREDRelease? = nil,
        tags: [FREDTag] = [],
        relatedSeries: [FREDSeries] = []
    ) {
        self.seriesID = seriesID
        self.categories = categories
        self.release = release
        self.tags = tags
        self.relatedSeries = relatedSeries
    }

    static let none = SeriesRelations(seriesID: "")

    var isEmpty: Bool {
        categories.isEmpty && release == nil && tags.isEmpty && relatedSeries.isEmpty
    }

    var primaryCategory: FREDCategory? {
        categories.first
    }

    /// Tags worth showing, most popular first, with licence/citation noise removed.
    var descriptiveTags: [FREDTag] {
        tags
            .filter(\.isDescriptive)
            .sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
    }

    /// Related series whose units can share an axis with `series`, listed first, so the
    /// suggestions that are immediately chartable together come to the top.
    func relatedSeriesRanked(comparableWith series: FREDSeries) -> [FREDSeries] {
        let descriptor = series.unitDescriptor
        return relatedSeries.sorted { lhs, rhs in
            let lhsComparable = descriptor.isComparable(to: lhs.unitDescriptor)
            let rhsComparable = descriptor.isComparable(to: rhs.unitDescriptor)
            if lhsComparable != rhsComparable { return lhsComparable }
            return (lhs.popularity ?? 0) > (rhs.popularity ?? 0)
        }
    }
}
