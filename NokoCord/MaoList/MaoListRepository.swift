import Foundation

struct MLSearchFilters: Equatable, Sendable {
    var type: MLMediaType = .anime
    var term = ""
    var sort = "TRENDING_DESC"
    var season = ""
    var year: Int?
    var format = ""
    var status = ""
    var genre = ""
    var tag = ""
    var source = ""
    var minimumScore: Int?
    var minimumPopularity: Int?
    var hasFilters: Bool { !season.isEmpty || year != nil || !format.isEmpty || !status.isEmpty || !genre.isEmpty || !tag.isEmpty || !source.isEmpty || minimumScore != nil || minimumPopularity != nil }
    static func discovery(type: MLMediaType, sort: String, seasonOffset: Int? = nil) -> Self {
        var filters = Self(); filters.type = type; filters.sort = sort
        if let seasonOffset {
            let calendar = Calendar.current
            let year = calendar.component(.year, from: Date())
            let quarter = (calendar.component(.month, from: Date()) - 1) / 3 + seasonOffset
            filters.season = ["WINTER", "SPRING", "SUMMER", "FALL"][quarter % 4]
            filters.year = year + quarter / 4
        }
        return filters
    }
    var variables: [String: MLValue] {
        var values: [String: MLValue] = ["type": .string(type.rawValue), "sort": .strings([sort])]
        for (key, value) in [("search", term.trimmingCharacters(in: .whitespacesAndNewlines)), ("season", season), ("format", format), ("status", status), ("genre", genre), ("tag", tag), ("source", source)] where !value.isEmpty { values[key] = .string(value) }
        if let year {
            if season.isEmpty {
                values["start"] = .int(year * 10000)
                values["end"] = .int((year + 1) * 10000)
            } else { values["year"] = .int(year) }
        }
        if let minimumScore { values["score"] = .int(minimumScore - 1) }
        if let minimumPopularity { values["popularity"] = .int(minimumPopularity - 1) }
        return values
    }
}

struct MLListDraft: Sendable {
    var mediaID: Int
    var entryID: Int?
    var status: MLListStatus = .planning
    var progress = 0
    var volumes = 0
    // Set only when the owner edits these controls. Progress-only changes must
    // not rewrite scores or advanced dimensions.
    var displayedScore: Double?
    var editedAdvancedScores: [Double]?
    var advancedScores: [String: Double] = [:]
    var repeats = 0
    var priority = 0
    var notes = ""
    var customLists: [String] = []
    var isPrivate = false
    var hiddenFromStatusLists = false
    var start = MLFuzzyDate()
    var finish = MLFuzzyDate()
    init(media: MLMedia) {
        mediaID = media.id
        if let entry = media.mediaListEntry {
            entryID = entry.id; status = entry.status ?? .planning; progress = entry.progress ?? 0
            volumes = entry.progressVolumes ?? 0; repeats = entry.repeat ?? 0
            priority = entry.priority ?? 0; notes = entry.notes ?? ""; isPrivate = entry.privateEntry ?? false
            hiddenFromStatusLists = entry.hiddenFromStatusLists ?? false
            advancedScores = entry.advancedScores ?? [:]
            customLists = entry.customLists?.filter { $0.value }.map(\.key).sorted() ?? []
            start = entry.startedAt ?? MLFuzzyDate(); finish = entry.completedAt ?? MLFuzzyDate()
        }
    }
}

/// Screen-sized queries and all supported mutations live here, never in views.
struct MLRepository: Sendable {
    let client: MLGraphQLClient
    static let card = "id title { userPreferred romaji english native } type coverImage { large medium color } format status episodes chapters volumes seasonYear averageScore nextAiringEpisode { episode airingAt }"
    static let user = "id name avatar { large medium }"
    static let listState = "id status score progress progressVolumes repeat priority private hiddenFromStatusLists notes customLists advancedScores startedAt { year month day } completedAt { year month day }"
    static let typeListOptions = "customLists advancedScoring advancedScoringEnabled sectionOrder splitCompletedSectionByFormat"
    static let listOptions = "scoreFormat animeList { \(typeListOptions) } mangaList { \(typeListOptions) }"
    static let viewerFields = "\(user) unreadNotificationCount mediaListOptions { \(listOptions) } statistics { anime { count statuses { status count } } manga { count statuses { status count } } }"
    static let libraryItem = "id status score progress progressVolumes updatedAt media { \(card) mediaListEntry { \(listState) } }"
    static let pageInfo = "pageInfo { currentPage hasNextPage total }"
    static let activity = """
        ... on TextActivity { id type user { \(user) } text(asHtml: false) createdAt likeCount isLiked replyCount siteUrl }
        ... on ListActivity { id type user { \(user) } status progress media { \(card) } createdAt likeCount isLiked replyCount siteUrl }
        ... on MessageActivity { id type user: messenger { \(user) } text: message(asHtml: false) createdAt likeCount isLiked replyCount siteUrl }
        """

    func viewer(refresh: Bool = false) async throws -> MLResult<MLViewerData> {
        try await client.execute("{ Viewer { \(Self.viewerFields) } }", as: MLViewerData.self, refresh: refresh, requiresAuth: true)
    }
    func home(userID: Int, refresh: Bool = false) async throws -> MLResult<MLHomeData> {
        let result = try await client.execute("""
            query ($user: Int!) {
                Viewer { \(Self.viewerFields) }
                watching: Page(page: 1, perPage: 6) { mediaList(userId: $user, type: ANIME, status: CURRENT, sort: UPDATED_TIME_DESC) { \(Self.libraryItem) } }
                reading: Page(page: 1, perPage: 6) { mediaList(userId: $user, type: MANGA, status: CURRENT, sort: UPDATED_TIME_DESC) { \(Self.libraryItem) } }
                discovery: Page(page: 1, perPage: 12) { media(type: ANIME, sort: TRENDING_DESC) { \(Self.card) } }
            }
            """, variables: ["user": .int(userID)], as: MLHomeData.self, refresh: refresh, requiresAuth: true)
        if !result.isPartial {
            guard result.value.Viewer?.id == userID, result.value.watching?.mediaList != nil,
                  result.value.reading?.mediaList != nil, result.value.discovery?.media != nil else { throw MLError.invalidResponse }
        }
        return result
    }
    static let searchQuery = """
            query ($type: MediaType, $search: String, $sort: [MediaSort], $page: Int, $season: MediaSeason, $year: Int, $start: FuzzyDateInt, $end: FuzzyDateInt, $format: MediaFormat, $status: MediaStatus, $genre: String, $tag: String, $source: MediaSource, $score: Int, $popularity: Int) {
                Page(page: $page, perPage: 24) { \(Self.pageInfo)
                    media(type: $type, search: $search, sort: $sort, season: $season, seasonYear: $year, startDate_greater: $start, startDate_lesser: $end, format: $format, status: $status, genre: $genre, tag: $tag, source: $source, averageScore_greater: $score, popularity_greater: $popularity) { \(Self.card) }
                }
            }
            """
    func search(_ filters: MLSearchFilters, page: Int, refresh: Bool = false, notBefore: ContinuousClock.Instant? = nil) async throws -> MLResult<MLPageData> {
        var variables = filters.variables
        variables["page"] = .int(page)
        return try await client.execute(Self.searchQuery, variables: variables, as: MLPageData.self, refresh: refresh, notBefore: notBefore)
    }
    static let libraryQuery = "query ($user: Int, $type: MediaType, $status: MediaListStatus, $page: Int) { Page(page: $page, perPage: 40) { \(Self.pageInfo) mediaList(userId: $user, type: $type, status: $status, sort: UPDATED_TIME_DESC) { \(Self.libraryItem) } } }"
    func library(userID: Int, type: MLMediaType, status: MLListStatus?, page: Int, refresh: Bool = false) async throws -> MLResult<MLPageData> {
        var variables: [String: MLValue] = ["user": .int(userID), "type": .string(type.rawValue), "page": .int(page)]
        if let status { variables["status"] = .string(status.rawValue) }
        return try await client.execute(Self.libraryQuery, variables: variables, as: MLPageData.self, refresh: refresh, requiresAuth: true)
    }
    func media(_ id: Int, refresh: Bool = false) async throws -> MLResult<MLMediaData> {
        try await client.execute("""
            query ($id: Int) { Media(id: $id) {
                \(Self.card) bannerImage description(asHtml: false) synonyms duration season source popularity genres isFavourite
                startDate { year month day } endDate { year month day }
                tags { id name rank isMediaSpoiler isGeneralSpoiler }
                rankings { id rank type context allTime }
                externalLinks { id site url type }
                mediaListEntry { \(Self.listState) }
                studios(isMain: true) { nodes { id name isAnimationStudio isFavourite } }
                relations { edges { relationType node { \(Self.card) } } }
            } }
            """, variables: ["id": .int(id)], as: MLMediaData.self, refresh: refresh)
    }
    enum MediaSection: String, CaseIterable { case characters, staff, recommendations, reviews }
    func mediaSection(_ id: Int, section: MediaSection, page: Int, refresh: Bool = false) async throws -> MLResult<MLMediaData> {
        let fields: String
        switch section {
        case .characters, .staff: fields = "nodes { id name { full native } image { large medium } }"
        case .recommendations: fields = "nodes { id rating mediaRecommendation { \(Self.card) } }"
        case .reviews: fields = "nodes { id summary rating user { \(Self.user) } siteUrl }"
        }
        return try await client.execute("query ($id: Int, $page: Int) { Media(id: $id) { id \(section.rawValue)(page: $page, perPage: 12) { \(Self.pageInfo) \(fields) } } }", variables: ["id": .int(id), "page": .int(page)], as: MLMediaData.self, refresh: refresh)
    }
    func taxonomy() async throws -> MLResult<MLTaxonomyData> {
        try await client.execute("{ GenreCollection MediaTagCollection { id name isGeneralSpoiler } }", as: MLTaxonomyData.self)
    }
    func profile(_ id: Int, refresh: Bool = false) async throws -> MLResult<MLUserData> {
        try await client.execute("query ($id: Int) { User(id: $id) { \(Self.user) bannerImage about(asHtml: false) isFollowing isFollower siteUrl statistics { anime { count meanScore minutesWatched episodesWatched statuses { status count } } manga { count meanScore chaptersRead volumesRead statuses { status count } } } } }", variables: ["id": .int(id)], as: MLUserData.self, refresh: refresh)
    }
    func favorites(_ id: Int, page: Int) async throws -> MLResult<MLUserData> {
        try await client.execute("query ($id: Int, $page: Int) { User(id: $id) { id favourites { anime(page: $page, perPage: 12) { \(Self.pageInfo) nodes { \(Self.card) } } manga(page: $page, perPage: 12) { \(Self.pageInfo) nodes { \(Self.card) } } characters(page: $page, perPage: 12) { \(Self.pageInfo) nodes { id name { full } image { large } } } staff(page: $page, perPage: 12) { \(Self.pageInfo) nodes { id name { full } image { large } } } studios(page: $page, perPage: 12) { \(Self.pageInfo) nodes { id name } } } } }", variables: ["id": .int(id), "page": .int(page)], as: MLUserData.self)
    }
    func person(_ id: Int, staff: Bool, page: Int) async throws -> MLResult<MLPerson?> {
        let fields = "id name { full native } image { large } description(asHtml: false) isFavourite gender \(staff ? "primaryOccupations" : "age") \(staff ? "media: staffMedia" : "media")(page: $page, perPage: 24, sort: POPULARITY_DESC) { \(Self.pageInfo) nodes { \(Self.card) } }"
        let query = "query ($id: Int, $page: Int) { \(staff ? "Staff" : "Character")(id: $id) { \(fields) } }"
        if staff { return try await client.execute(query, variables: ["id": .int(id), "page": .int(page)], as: MLStaffData.self).map { $0.Staff } }
        return try await client.execute(query, variables: ["id": .int(id), "page": .int(page)], as: MLCharacterData.self).map { $0.Character }
    }
    func studio(_ id: Int, page: Int) async throws -> MLResult<MLStudio?> {
        try await client.execute("query ($id: Int, $page: Int) { Studio(id: $id) { id name isFavourite isAnimationStudio media(page: $page, perPage: 24, sort: POPULARITY_DESC) { \(Self.pageInfo) nodes { \(Self.card) } } } }", variables: ["id": .int(id), "page": .int(page)], as: MLStudioData.self).map { $0.Studio }
    }
    static let feedQuery = "query ($page: Int, $user: Int, $following: Boolean) { Page(page: $page, perPage: 20) { \(Self.pageInfo) activities(userId: $user, isFollowing: $following, sort: ID_DESC) { \(Self.activity) } } }"
    func feed(userID: Int? = nil, following: Bool = false, page: Int, refresh: Bool = false) async throws -> MLResult<MLPageData> {
        var variables: [String: MLValue] = ["page": .int(page)]
        if let userID { variables["user"] = .int(userID) }
        if following { variables["following"] = .bool(true) }
        return try await client.execute(Self.feedQuery, variables: variables, as: MLPageData.self, refresh: refresh, requiresAuth: following)
    }
    func replies(_ id: Int, page: Int, refresh: Bool = false) async throws -> MLResult<MLPageData> {
        try await client.execute("query ($id: Int, $page: Int) { Page(page: $page, perPage: 20) { \(Self.pageInfo) activityReplies(activityId: $id) { id text(asHtml: false) user { \(Self.user) } createdAt likeCount isLiked } } }", variables: ["id": .int(id), "page": .int(page)], as: MLPageData.self, refresh: refresh)
    }
    func follows(_ id: Int, following: Bool, page: Int) async throws -> MLResult<MLPageData> {
        try await client.execute("query ($id: Int!, $page: Int) { Page(page: $page, perPage: 30) { \(Self.pageInfo) \(following ? "following" : "followers")(userId: $id, sort: USERNAME) { \(Self.user) isFollowing } } }", variables: ["id": .int(id), "page": .int(page)], as: MLPageData.self)
    }
    func saveList(_ draft: MLListDraft) async throws -> MLListState {
        guard draft.progress >= 0, draft.volumes >= 0,
              (0...1000).contains(draft.repeats), (0...255).contains(draft.priority), draft.notes.count <= 6000,
              draft.start.isValid, draft.finish.isValid,
              draft.displayedScore.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
              draft.editedAdvancedScores?.allSatisfy({ $0.isFinite && (0...100).contains($0) }) ?? true else { throw MLError.rejected }
        func date(_ value: MLFuzzyDate) -> MLValue {
            .object(["year": value.year.map(MLValue.int) ?? .null, "month": value.month.map(MLValue.int) ?? .null, "day": value.day.map(MLValue.int) ?? .null])
        }
        var variables: [String: MLValue] = ["media": .int(draft.mediaID), "status": .string(draft.status.rawValue), "progress": .int(draft.progress), "volumes": .int(draft.volumes), "repeat": .int(draft.repeats), "priority": .int(draft.priority), "notes": .string(draft.notes), "lists": .strings(draft.customLists), "private": .bool(draft.isPrivate), "hidden": .bool(draft.hiddenFromStatusLists), "start": date(draft.start), "finish": date(draft.finish)]
        if let entryID = draft.entryID { variables["id"] = .int(entryID) }
        if let displayedScore = draft.displayedScore { variables["scoreValue"] = .number(displayedScore) }
        if let advanced = draft.editedAdvancedScores { variables["advanced"] = .numbers(advanced) }
        let query = """
            mutation ($id: Int, $media: Int, $status: MediaListStatus, $progress: Int, $volumes: Int, $scoreValue: Float, $advanced: [Float], $repeat: Int, $priority: Int, $notes: String, $lists: [String], $private: Boolean, $hidden: Boolean, $start: FuzzyDateInput, $finish: FuzzyDateInput) {
                SaveMediaListEntry(id: $id, mediaId: $media, status: $status, progress: $progress, progressVolumes: $volumes, score: $scoreValue, advancedScores: $advanced, repeat: $repeat, priority: $priority, notes: $notes, customLists: $lists, private: $private, hiddenFromStatusLists: $hidden, startedAt: $start, completedAt: $finish) { \(Self.listState) }
            }
            """
        guard let saved = try await client.execute(query, variables: variables, as: MLSaveListData.self, mutation: true, requiresAuth: true).value.SaveMediaListEntry else { throw MLError.rejected }
        return saved
    }
    struct Acknowledgement: Decodable, Sendable {
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            guard !container.allKeys.isEmpty else { throw MLError.rejected }
            for key in container.allKeys {
                if try container.decodeNil(forKey: key) { throw MLError.rejected }
                if key.stringValue.hasPrefix("Delete") {
                    struct Deleted: Decodable { let deleted: Bool }
                    guard try container.decode(Deleted.self, forKey: key).deleted else { throw MLError.rejected }
                }
            }
        }
        struct Key: CodingKey { let stringValue: String; let intValue: Int? = nil; init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil } }
    }
    func deleteList(_ id: Int) async throws {
        _ = try await client.execute("mutation ($id: Int) { DeleteMediaListEntry(id: $id) { deleted } }", variables: ["id": .int(id)], as: Acknowledgement.self, mutation: true, requiresAuth: true)
    }
    func entryScore(_ id: Int) async throws -> MLResult<Double> {
        // Refresh only the editable score without reloading all media details.
        // Omitting format preserves AniList's account scoring system.
        let result = try await client.execute("query ($id: Int) { MediaList(id: $id) { id score } }", variables: ["id": .int(id)], as: MLListEntryData.self, requiresAuth: true)
        guard let score = result.value.MediaList?.score, score.isFinite else { throw MLError.invalidResponse }
        return result.map { _ in score }
    }
    func incrementProgress(mediaID: Int, entryID: Int?, progress: Int) async throws -> MLListState {
        guard progress >= 0 else { throw MLError.rejected }
        var variables: [String: MLValue] = ["media": .int(mediaID), "progress": .int(progress)]
        if let entryID { variables["id"] = .int(entryID) }
        guard let entry = try await client.execute("mutation ($id: Int, $media: Int, $progress: Int) { SaveMediaListEntry(id: $id, mediaId: $media, progress: $progress) { \(Self.listState) } }", variables: variables, as: MLSaveListData.self, mutation: true, requiresAuth: true).value.SaveMediaListEntry else { throw MLError.rejected }
        return entry
    }
    func deleteCustomList(_ name: String, type: MLMediaType) async throws {
        _ = try await client.execute("mutation ($name: String, $type: MediaType) { DeleteCustomList(customList: $name, type: $type) { deleted } }", variables: ["name": .string(name), "type": .string(type.rawValue)], as: Acknowledgement.self, mutation: true, requiresAuth: true)
    }
    func saveListPreferences(_ draft: MLListPreferencesDraft) async throws -> MLUser {
        let variables = try draft.variables()
        guard !variables.isEmpty else { throw MLError.rejected }
        guard let user = try await client.execute("mutation ($score: ScoreFormat, $anime: MediaListOptionsInput, $manga: MediaListOptionsInput) { UpdateUser(scoreFormat: $score, animeListOptions: $anime, mangaListOptions: $manga) { id mediaListOptions { \(Self.listOptions) } } }", variables: variables, as: MLUpdateUserData.self, mutation: true, requiresAuth: true).value.UpdateUser,
              user.mediaListOptions != nil else { throw MLError.rejected }
        return user
    }
    func toggleFavorite(_ id: Int, kind: String) async throws {
        guard ["anime", "manga", "character", "staff", "studio"].contains(kind) else { throw MLError.rejected }
        _ = try await client.execute("mutation ($id: Int) { ToggleFavourite(\(kind)Id: $id) { anime { nodes { id } } } }", variables: ["id": .int(id)], as: Acknowledgement.self, mutation: true, requiresAuth: true)
    }
    func toggleFollow(_ id: Int) async throws {
        _ = try await client.execute("mutation ($id: Int) { ToggleFollow(userId: $id) { id isFollowing } }", variables: ["id": .int(id)], as: Acknowledgement.self, mutation: true, requiresAuth: true)
    }
    func toggleLike(_ id: Int, reply: Bool = false) async throws {
        _ = try await client.execute("mutation ($id: Int, $type: LikeableType) { ToggleLikeV2(id: $id, type: $type) { ... on TextActivity { id } ... on ListActivity { id } ... on MessageActivity { id } ... on ActivityReply { id } } }", variables: ["id": .int(id), "type": .string(reply ? "ACTIVITY_REPLY" : "ACTIVITY")], as: Acknowledgement.self, mutation: true, requiresAuth: true)
    }
    func postActivity(_ text: String) async throws {
        guard MLPostTextKind.activity.accepts(text) else { throw MLError.rejected }
        _ = try await client.execute("mutation ($text: String) { SaveTextActivity(text: $text) { id } }", variables: ["text": .string(text)], as: Acknowledgement.self, mutation: true, requiresAuth: true)
    }
    func postReply(_ text: String, activityID: Int) async throws {
        guard MLPostTextKind.reply.accepts(text) else { throw MLError.rejected }
        _ = try await client.execute("mutation ($text: String, $id: Int) { SaveActivityReply(text: $text, activityId: $id) { id } }", variables: ["text": .string(text), "id": .int(activityID)], as: Acknowledgement.self, mutation: true, requiresAuth: true)
    }
    func updateBio(_ text: String) async throws {
        _ = try await client.execute("mutation ($about: String) { UpdateUser(about: $about) { id } }", variables: ["about": .string(text)], as: Acknowledgement.self, mutation: true, requiresAuth: true)
    }
    func notifications(page: Int, refresh: Bool = false) async throws -> MLResult<MLPageData> {
        try await client.execute("""
            query ($page: Int) { Page(page: $page, perPage: 20) { \(Self.pageInfo) notifications(resetNotificationCount: true) {
            ... on AiringNotification { id type createdAt contexts episode media { id title { userPreferred } type coverImage { medium } } }
            ... on FollowingNotification { id type createdAt context user { id name avatar { medium } } }
            ... on ActivityMessageNotification { id type createdAt context activityId user { id name avatar { medium } } }
            ... on ActivityMentionNotification { id type createdAt context activityId user { id name avatar { medium } } }
            ... on ActivityReplyNotification { id type createdAt context activityId user { id name avatar { medium } } }
            ... on ActivityReplySubscribedNotification { id type createdAt context activityId user { id name avatar { medium } } }
            ... on ActivityLikeNotification { id type createdAt context activityId user { id name avatar { medium } } }
            ... on ActivityReplyLikeNotification { id type createdAt context activityId user { id name avatar { medium } } }
            ... on ThreadCommentMentionNotification { id type createdAt context user { id name avatar { medium } } thread { siteUrl } }
            ... on ThreadCommentReplyNotification { id type createdAt context user { id name avatar { medium } } thread { siteUrl } }
            ... on ThreadCommentSubscribedNotification { id type createdAt context user { id name avatar { medium } } thread { siteUrl } }
            ... on ThreadCommentLikeNotification { id type createdAt context user { id name avatar { medium } } thread { siteUrl } }
            ... on ThreadLikeNotification { id type createdAt context user { id name avatar { medium } } thread { siteUrl } }
            ... on RelatedMediaAdditionNotification { id type createdAt context media { id title { userPreferred } type coverImage { medium } } }
            ... on MediaDataChangeNotification { id type createdAt context media { id title { userPreferred } type coverImage { medium } } }
            ... on MediaMergeNotification { id type createdAt context media { id title { userPreferred } type coverImage { medium } } }
            ... on MediaDeletionNotification { id type createdAt context }
            ... on MediaSubmissionUpdateNotification { id type createdAt contexts media { id title { userPreferred } type coverImage { medium } } }
            ... on StaffSubmissionUpdateNotification { id type createdAt contexts }
            ... on CharacterSubmissionUpdateNotification { id type createdAt contexts }
            } } }
            """, variables: ["page": .int(page)], as: MLPageData.self, refresh: refresh, requiresAuth: true)
    }
    func activity(_ id: Int, refresh: Bool = false) async throws -> MLResult<MLActivity?> {
        try await client.execute("query ($id: Int) { Activity(id: $id) { \(Self.activity) } }", variables: ["id": .int(id)], as: MLActivityData.self, refresh: refresh).map { $0.Activity }
    }
    func review(_ id: Int, refresh: Bool = false) async throws -> MLResult<MLReview?> {
        try await client.execute("query ($id: Int) { Review(id: $id) { id summary body(asHtml: false) rating user { \(Self.user) } } }", variables: ["id": .int(id)], as: MLReviewData.self, refresh: refresh).map { $0.Review }
    }

}


/// Trusted first-page selections for opt-in preparation. Keep cache keys shared
/// with the ordinary repository calls; batches contain at most four roots.
struct MLPreparationEntry: Sendable {
    enum Kind: Sendable {
        case library(MLMediaType, MLListStatus?)
        case discovery(MLSearchFilters)
        case activity(Bool)
    }
    let kind: Kind
    var selection: String {
        switch kind {
        case .library(let type, let status):
            let statusArgument = status.map { ", status: \($0.rawValue)" } ?? ""
            return "Page(page: 1, perPage: 40) { \(MLRepository.pageInfo) mediaList(userId: $user, type: \(type.rawValue)\(statusArgument), sort: UPDATED_TIME_DESC) { \(MLRepository.libraryItem) } }"
        case .discovery(let filters):
            let season = filters.season.isEmpty ? "" : ", season: \(filters.season), seasonYear: \(filters.year ?? 0)"
            return "Page(page: 1, perPage: 24) { \(MLRepository.pageInfo) media(type: \(filters.type.rawValue), sort: [\(filters.sort)]\(season)) { \(MLRepository.card) } }"
        case .activity(let following):
            return "Page(page: 1, perPage: 20) { \(MLRepository.pageInfo) activities(\(following ? "isFollowing: true, " : "")sort: ID_DESC) { \(MLRepository.activity) } }"
        }
    }
    func request(userID: Int) -> (String, [String: MLValue]) {
        switch kind {
        case .library(let type, let status):
            var variables: [String: MLValue] = ["user": .int(userID), "type": .string(type.rawValue), "page": .int(1)]
            if let status { variables["status"] = .string(status.rawValue) }
            return (MLRepository.libraryQuery, variables)
        case .discovery(let filters):
            var variables = filters.variables; variables["page"] = .int(1)
            return (MLRepository.searchQuery, variables)
        case .activity(let following):
            var variables: [String: MLValue] = ["page": .int(1)]
            if following { variables["following"] = .bool(true) }
            return (MLRepository.feedQuery, variables)
        }
    }
    static var all: [Self] {
        var entries: [Self] = [.init(kind: .library(.anime, .current)), .init(kind: .library(.manga, .current)),
                               .init(kind: .discovery(.discovery(type: .anime, sort: "POPULARITY_DESC", seasonOffset: 0))),
                               .init(kind: .activity(true))]
        for type in MLMediaType.allCases {
            for status in [Optional<MLListStatus>.none] + MLListStatus.allCases.filter({ $0 != .current }).map({ Optional($0) }) {
                entries.append(.init(kind: .library(type, status)))
            }
            for sort in ["TRENDING_DESC", "POPULARITY_DESC", "SCORE_DESC"] {
                entries.append(.init(kind: .discovery(.discovery(type: type, sort: sort))))
            }
        }
        entries.append(.init(kind: .discovery(.discovery(type: .anime, sort: "POPULARITY_DESC", seasonOffset: 1))))
        entries.append(.init(kind: .activity(false)))
        return entries
    }
}
extension MLRepository {
    func prepareFirstPages(_ entries: [MLPreparationEntry], userID: Int) async throws -> [MLPage] {
        guard !entries.isEmpty, entries.count <= 4 else { throw MLError.invalidResponse }
        let epoch = await client.preparationEpoch()
        let selections = entries.enumerated().map { "prepared\($0.offset): \($0.element.selection)" }.joined(separator: "\n")
        // Public-only batches (e.g. Discover/Activity) need no user variable.
        let usesUser = entries.contains { if case .library = $0.kind { return true }; return false }
        let query = (usesUser ? "query ($user: Int!)" : "query") + " { \(selections) }"
        let result = try await client.execute(query, variables: usesUser ? ["user": .int(userID)] : [:],
                                              as: [String: MLPage?].self, refresh: true, requiresAuth: true, cacheResponse: false)
        guard !result.isPartial, !result.isStale else { throw MLError.unavailable }
        var pages: [MLPage] = []
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            guard let page = result.value["prepared\(index)"] ?? nil, page.pageInfo != nil else { throw MLError.invalidResponse }
            switch entry.kind {
            case .library: guard page.mediaList != nil else { throw MLError.invalidResponse }
            case .discovery: guard page.media != nil else { throw MLError.invalidResponse }
            case .activity: guard page.activities != nil else { throw MLError.invalidResponse }
            }
            let (query, variables) = entry.request(userID: userID)
            try await client.cachePrepared(query, variables: variables, value: MLPageData(Page: page), epoch: epoch)
            pages.append(page)
        }
        return pages
    }
    func cachedLibrary(userID: Int, type: MLMediaType, status: MLListStatus?, page: Int) async throws -> MLResult<MLPageData>? {
        var variables: [String: MLValue] = ["user": .int(userID), "type": .string(type.rawValue), "page": .int(page)]
        if let status { variables["status"] = .string(status.rawValue) }
        return try await client.cached(Self.libraryQuery, variables: variables, as: MLPageData.self)
    }
}
