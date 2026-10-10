import Foundation

struct MLDiscordPalette: Sendable { let accent: String; let surface: String }

enum MLMediaType: String, Codable, CaseIterable, Identifiable, Sendable {
    case anime = "ANIME", manga = "MANGA"
    var id: String { rawValue }
    var title: String { self == .anime ? "Anime" : "Manga" }
}

enum MLListStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case current = "CURRENT", planning = "PLANNING", completed = "COMPLETED"
    case paused = "PAUSED", dropped = "DROPPED", repeating = "REPEATING"
    var id: String { rawValue }
    func title(for type: MLMediaType) -> String {
        if self == .current { return type == .anime ? "Watching" : "Reading" }
        return rawValue.capitalized
    }
}

struct MLTitle: Codable, Sendable {
    var userPreferred: String?
    var romaji: String?
    var english: String?
    var native: String?
    var display: String { userPreferred ?? english ?? romaji ?? native ?? "Untitled" }
}

struct MLImageURLs: Codable, Sendable { var large: URL?; var medium: URL?; var extraLarge: URL?; var color: String? }
struct MLFuzzyDate: Codable, Equatable, Sendable {
    var year: Int?; var month: Int?; var day: Int?
    var isValid: Bool {
        if let year, !(1...9999).contains(year) { return false }
        if let month, !(1...12).contains(month) { return false }
        if let day, !(1...31).contains(day) { return false }
        guard let month, let day else { return true }
        // Unknown years may include February 29; known years use Gregorian leap rules.
        let referenceYear = year ?? 2000
        let leap = referenceYear.isMultiple(of: 400) || (referenceYear.isMultiple(of: 4) && !referenceYear.isMultiple(of: 100))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= days[month - 1]
    }
    var label: String {
        [year.map(String.init), month.map { String(format: "%02d", $0) }, day.map { String(format: "%02d", $0) }]
            .compactMap { $0 }.joined(separator: "-")
    }
}

enum MLPostTextKind {
    case activity, reply
    var limits: ClosedRange<Int> { self == .activity ? 5...10000 : 2...8000 }
    func accepts(_ text: String) -> Bool {
        text.count <= limits.upperBound && text.trimmingCharacters(in: .whitespacesAndNewlines).count >= limits.lowerBound
    }
}

/// AniList embeds are not ordinary Markdown. Keep their resource URLs out of
/// native prose; the containing AniList page remains the explicit fallback.
struct MLReadableText {
    let text: String
    let hasUnsupportedContent: Bool
    init(_ source: String) {
        var value = source
        var unsupported = false
        func replace(_ pattern: String, with replacement: String) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(value.startIndex..., in: value)
            if expression.firstMatch(in: value, range: range) != nil {
                unsupported = true
                value = expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
            }
        }
        replace("(?s)~!.*?!~", with: "[Spoiler hidden]")
        replace("(?s)~!.*$", with: "[Spoiler hidden]")
        // Accept balanced parentheses in resource URLs, as commonly used in titles.
        replace("(?i)!?(?:img[0-9]*|youtube|webm)\\((?:[^()]|\\([^()]*\\))*\\)", with: "")
        replace("!\\[[^\\]\\n]*\\]\\((?:[^()]|\\([^()]*\\))*\\)", with: "")
        replace("(?is)<(?:img|iframe|video|audio|embed|object)\\b[^>]*>(?:.*?</(?:iframe|video|audio|object)>)?", with: "")
        value = value.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        let blank = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{3164}\u{200B}\u{FEFF}"))
        let lines = value.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: blank) }
        value = lines.joined(separator: "\n").replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression).trimmingCharacters(in: blank)
        text = value; hasUnsupportedContent = unsupported
    }
}
struct MLAiring: Codable, Sendable { let episode: Int; let airingAt: Int; var timeUntilAiring: Int? }
struct MLTag: Codable, Identifiable, Sendable {
    let id: Int; var name: String?; var rank: Int?; var isMediaSpoiler: Bool?; var isGeneralSpoiler: Bool?
}
struct MLRanking: Codable, Identifiable, Sendable {
    let id: Int; var rank: Int?; var type: String?; var context: String?; var allTime: Bool?
}
struct MLLink: Codable, Identifiable, Sendable { let id: Int; var site: String?; var url: URL?; var type: String? }
struct MLPageInfo: Codable, Sendable { var currentPage: Int?; var hasNextPage: Bool?; var total: Int? }
struct MLConnection<T: Codable & Sendable>: Codable, Sendable {
    var nodes: [T?]?
    var pageInfo: MLPageInfo?
    var items: [T] { nodes?.compactMap { $0 } ?? [] }
}

/// Each visible collection retains only a bounded window of unique entries.
enum MLPageWindow {
    static let limit = 400
    static func merge<T: Identifiable>(_ old: [T], _ incoming: [T], maximum: Int = MLPageWindow.limit) -> (items: [T], released: Bool) {
        var seen = Set<T.ID>()
        let unique = (old + incoming).filter { seen.insert($0.id).inserted }
        return (Array(unique.suffix(maximum)), unique.count > maximum)
    }
    static func merge<T: Codable & Sendable & Identifiable>(_ old: MLConnection<T>?, _ incoming: MLConnection<T>?) -> (connection: MLConnection<T>?, released: Bool) {
        guard let incoming else { return (old, false) }
        let merged = merge(old?.items ?? [], incoming.items)
        return (MLConnection(nodes: merged.items.map { Optional($0) }, pageInfo: incoming.pageInfo), merged.released)
    }
}

struct MLListState: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    var status: MLListStatus?
    var score: Double?
    var progress: Int?
    var progressVolumes: Int?
    var `repeat`: Int?
    var priority: Int?
    var privateEntry: Bool?
    var hiddenFromStatusLists: Bool?
    var notes: String?
    var customLists: [String: Bool]?
    var advancedScores: [String: Double]?
    var startedAt: MLFuzzyDate?
    var completedAt: MLFuzzyDate?
    enum CodingKeys: String, CodingKey {
        case id, status, score, progress, progressVolumes, `repeat`, priority, notes, customLists, advancedScores, startedAt, completedAt, hiddenFromStatusLists
        case privateEntry = "private"
    }
}

struct MLMedia: Codable, Identifiable, Sendable {
    let id: Int
    var title: MLTitle?
    var type: MLMediaType?
    var coverImage: MLImageURLs?
    var bannerImage: URL?
    var format: String?
    var status: String?
    var episodes: Int?
    var chapters: Int?
    var volumes: Int?
    var duration: Int?
    var season: String?
    var seasonYear: Int?
    var averageScore: Int?
    var popularity: Int?
    var description: String?
    var genres: [String]?
    var synonyms: [String]?
    var source: String?
    var isFavourite: Bool?
    var nextAiringEpisode: MLAiring?
    var startDate: MLFuzzyDate?
    var endDate: MLFuzzyDate?
    var tags: [MLTag?]?
    var rankings: [MLRanking?]?
    var externalLinks: [MLLink?]?
    var mediaListEntry: MLListState?
    var relations: MLRelations?
    var characters: MLConnection<MLPerson>?
    var staff: MLConnection<MLPerson>?
    var studios: MLConnection<MLStudio>?
    var recommendations: MLConnection<MLRecommendation>?
    var reviews: MLConnection<MLReview>?
    var name: String { title?.display ?? "Untitled" }
    var length: Int? { type == .manga ? chapters : episodes }
    var summary: String { [format?.replacingOccurrences(of: "_", with: " "), seasonYear.map(String.init)].compactMap { $0 }.joined(separator: " · ") }
}
struct MLRelations: Codable, Sendable {
    var edges: [MLEdge?]?
    struct MLEdge: Codable, Sendable { var relationType: String?; var node: MLMedia? }
}
struct MLRecommendation: Codable, Identifiable, Sendable { let id: Int; var rating: Int?; var mediaRecommendation: MLMedia? }
struct MLReview: Codable, Identifiable, Sendable { let id: Int; var summary: String?; var body: String?; var rating: Int?; var user: MLUser?; var siteUrl: URL? }
struct MLPerson: Codable, Identifiable, Sendable {
    let id: Int
    var name: MLPersonName?
    var image: MLImageURLs?
    var description: String?
    var isFavourite: Bool?
    var gender: String?
    var age: String?
    var primaryOccupations: [String]?
    var media: MLConnection<MLMedia>?
}
struct MLPersonName: Codable, Sendable { var full: String?; var native: String? }
struct MLStudio: Codable, Identifiable, Sendable { let id: Int; var name: String?; var isFavourite: Bool?; var isAnimationStudio: Bool?; var media: MLConnection<MLMedia>? }
struct MLLibraryEntry: Codable, Identifiable, Sendable {
    let id: Int
    var media: MLMedia?
    var status: MLListStatus?
    var score: Double?
    var progress: Int?
    var progressVolumes: Int?
    var updatedAt: Int?
}
struct MLStatistics: Codable, Sendable { var anime: MLStats?; var manga: MLStats? }
struct MLStats: Codable, Sendable {
    var count: Int?; var meanScore: Double?; var minutesWatched: Int?; var episodesWatched: Int?
    var chaptersRead: Int?; var volumesRead: Int?
    var statuses: [MLStatusCount?]?
    var libraryCount: Int { statuses?.compactMap { $0?.count }.reduce(0, +) ?? count ?? 0 }
}
struct MLStatusCount: Codable, Sendable { var status: MLListStatus?; var count: Int? }
struct MLListOptions: Codable, Sendable { var scoreFormat: String?; var animeList: MLTypeListOptions?; var mangaList: MLTypeListOptions? }
struct MLTypeListOptions: Codable, Equatable, Sendable {
    var customLists: [String]?
    var advancedScoring: [String]?
    var advancedScoringEnabled: Bool?
    var sectionOrder: [String]?
    var splitCompletedSectionByFormat: Bool?
}
struct MLFavorites: Codable, Sendable {
    var anime: MLConnection<MLMedia>?; var manga: MLConnection<MLMedia>?
    var characters: MLConnection<MLPerson>?; var staff: MLConnection<MLPerson>?; var studios: MLConnection<MLStudio>?
}
struct MLUser: Codable, Identifiable, Sendable {
    let id: Int
    var name: String?
    var avatar: MLImageURLs?
    var bannerImage: URL?
    var about: String?
    var isFollowing: Bool?
    var isFollower: Bool?
    var unreadNotificationCount: Int?
    var statistics: MLStatistics?
    var favourites: MLFavorites?
    var mediaListOptions: MLListOptions?
    var siteUrl: URL?
}
struct MLActivity: Codable, Identifiable, Sendable {
    let id: Int
    var type: String?
    var user: MLUser?
    var text: String?
    var status: String?
    var progress: String?
    var media: MLMedia?
    var createdAt: Int?
    var likeCount: Int?
    var isLiked: Bool?
    var replyCount: Int?
    var siteUrl: URL?
}
struct MLReply: Codable, Identifiable, Sendable { let id: Int; var text: String?; var user: MLUser?; var createdAt: Int?; var likeCount: Int?; var isLiked: Bool? }
struct MLNotification: Codable, Identifiable, Sendable {
    let id: Int; var type: String?; var createdAt: Int?; var context: String?; var contexts: [String]?
    var user: MLUser?; var media: MLMedia?; var activityId: Int?; var episode: Int?; var thread: MLThreadReference?
}
struct MLPage: Codable, Sendable {
    var pageInfo: MLPageInfo?
    var media: [MLMedia?]?
    var mediaList: [MLLibraryEntry?]?
    var activities: [MLActivity?]?
    var activityReplies: [MLReply?]?
    var followers: [MLUser?]?
    var following: [MLUser?]?
    var notifications: [MLNotification?]?
}
struct MLPageData: Codable, Sendable { var Page: MLPage? }
struct MLMediaData: Codable, Sendable { var Media: MLMedia? }
struct MLViewerData: Codable, Sendable { var Viewer: MLUser? }
struct MLHomeData: Codable, Sendable {
    var Viewer: MLUser?
    var watching: MLPage?
    var reading: MLPage?
    var discovery: MLPage?
}
struct MLUserData: Codable, Sendable { var User: MLUser? }
struct MLCharacterData: Codable, Sendable { var Character: MLPerson? }
struct MLStaffData: Codable, Sendable { var Staff: MLPerson? }
struct MLStudioData: Codable, Sendable { var Studio: MLStudio? }
struct MLSaveListData: Codable, Sendable { var SaveMediaListEntry: MLListState? }
struct MLListEntryData: Codable, Sendable { var MediaList: MLListState? }
struct MLUpdateUserData: Codable, Sendable { var UpdateUser: MLUser? }
struct MLTaxonomyData: Codable, Sendable { var GenreCollection: [String]?; var MediaTagCollection: [MLTag?]? }

enum MLError: LocalizedError, Equatable, Sendable {
    case offline, authentication, rateLimited(Date), unavailable, invalidResponse, rejected, keychain, configuration, stopped
    var errorDescription: String? {
        switch self {
        case .offline: "AniList couldn’t be reached. Check your connection and try again."
        case .authentication: "Your AniList connection needs to be renewed. Connect again to continue."
        case .rateLimited(let date): "AniList needs a short break. Try again after \(date.formatted(date: .omitted, time: .shortened))."
        case .unavailable: "AniList is temporarily unavailable. Your cached pages are still available."
        case .invalidResponse: "AniList returned information MaoList couldn’t read. Please try again."
        case .rejected: "AniList couldn’t save that change. Your previous values have been kept."
        case .keychain: "MaoList couldn’t access its saved connection in Keychain. Please try again."
        case .configuration: "AniList connection is not configured in this build yet. Public browsing is available."
        case .stopped: "MaoList is switched off."
        }
    }
}

struct MLThreadReference: Codable, Sendable { var siteUrl: URL? }
struct MLActivityData: Codable, Sendable { var Activity: MLActivity? }
struct MLReviewData: Codable, Sendable { var Review: MLReview? }
