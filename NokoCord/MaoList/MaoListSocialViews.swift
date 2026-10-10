import SwiftUI

struct MLProfileView: View {
    @Environment(MLRuntime.self) private var runtime
    let id: Int
    @State private var user: MLUser?
    @State private var tab = "Overview"
    @State private var error: String?
    @State private var stale: Date?
    @State private var partial = false
    @State private var favoritesPage = 0
    @State private var favoriteItems = MLFavorites()
    @State private var favoritesRequest = MLReadRequest()
    private var favoritesBusy: Bool { favoritesRequest.loading }
    @State private var favoritesError: String?
    @State private var favoritesStale: Date?
    @State private var favoritesPartial = false
    @State private var favoritesReleased = false
    @State private var followingBusy = false
    @State private var editingBio = false
    @State private var bioExpanded = false
    @State private var reads = MLReadActions()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error { MLErrorBanner(message: error) }
                MLStaleBanner(date: stale, partial: partial)
                if let user {
                    if let banner = user.bannerImage { GeometryReader { geo in MLArtwork(url: banner, width: geo.size.width, height: 130, radius: 14) }.frame(height: 130) }
                    HStack(alignment: .top, spacing: 20) {
                        MLArtwork(url: user.avatar?.large, width: 84, height: 84, radius: 20)
                        VStack(alignment: .leading, spacing: 8) { Text(user.name ?? "AniList member").font(.largeTitle.bold()); if user.isFollower == true { Text("Follows you").font(.caption).foregroundStyle(.secondary) } }
                        Spacer()
                        if id == runtime.viewer?.id { Button("Edit bio") { editingBio = true } }
                        else if runtime.viewer != nil { Button(user.isFollowing == true ? "Unfollow" : "Follow") { follow() }.disabled(followingBusy) }
                    }
                    ViewThatFits(in: .horizontal) {
                        Picker("Profile section", selection: $tab) { ForEach(["Overview", "Favorites", "Activity", "Following", "Followers"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                        Picker("Profile section", selection: $tab) { ForEach(["Overview", "Favorites", "Activity", "Following", "Followers"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu).labelsHidden()
                    }
                    switch tab {
                    case "Favorites": favorites
                    case "Activity": MLActivityView(userID: id)
                    case "Following": MLFollowersView(userID: id, following: true)
                    case "Followers": MLFollowersView(userID: id, following: false)
                    default:
                        if let about = user.about, !about.isEmpty {
                            MLRichText(text: about, fallbackURL: user.siteUrl ?? URL(string: "https://anilist.co/user/\(id)"), fallbackLabel: "View full bio on AniList", notice: "This bio includes images or formatting MaoList can’t display.")
                                .lineLimit(bioExpanded ? nil : 6).frame(maxWidth: 760, alignment: .leading)
                            let readable = MLReadableText(about).text
                            if readable.count > 360 || readable.components(separatedBy: .newlines).count > 6 { Button(bioExpanded ? "Show less" : "Show more") { bioExpanded.toggle() }.buttonStyle(.borderless).font(.caption) }
                        }
                        if let stats = user.statistics {
                            Text("AniList statistics").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                            Text("Account totals reported by AniList.").font(.caption).foregroundStyle(.secondary)
                            HStack(alignment: .top, spacing: 18) { MLStatisticsPanel(title: "Anime", stats: stats.anime, type: .anime); MLStatisticsPanel(title: "Manga", stats: stats.manga, type: .manga) }
                        }
                    }
                } else if error == nil { ProgressView("Loading profile…") }
                if error != nil { Button("Retry") { reads.run { await load(refresh: true) } } }
            }.padding(26).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.mlTask(id: "profile/\(id)") { await load() }
            .mlReadActions(reads, id: "\(id)/\(tab)")
            .mlTask(id: "favorites/\(id)/\(tab)") { if tab == "Favorites" && favoritesPage == 0 { await loadFavorites(replacing: true) } }
            .sheet(isPresented: $editingBio) { MLBioEditor(text: user?.about ?? "") { text in user?.about = text }.environment(runtime) }
    }
    @ViewBuilder private var favorites: some View {
        MLStaleBanner(date: favoritesStale, partial: favoritesPartial)
        MLPageWindowNotice(released: favoritesReleased)
        if let favoritesError {
            MLErrorBanner(message: favoritesError)
            Button("Retry favorites") { reads.run { await loadFavorites() } }.disabled(favoritesBusy)
        }
        if favoritesPage > 0 {
            let favorites = favoriteItems
            if !(favorites.anime?.items ?? []).isEmpty { Text("Favorite anime").font(.title3.bold()); MLMediaGrid(media: favorites.anime?.items ?? []) }
            if !(favorites.manga?.items ?? []).isEmpty { Text("Favorite manga").font(.title3.bold()); MLMediaGrid(media: favorites.manga?.items ?? []) }
            if !(favorites.characters?.items ?? []).isEmpty { Text("Favorite characters").font(.title3.bold()); LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))]) { ForEach(favorites.characters?.items ?? []) { MLPersonButton(person: $0, staff: false) } } }
            if !(favorites.staff?.items ?? []).isEmpty { Text("Favorite staff").font(.title3.bold()); LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))]) { ForEach(favorites.staff?.items ?? []) { MLPersonButton(person: $0, staff: true) } } }
            if let studios = favorites.studios?.items, !studios.isEmpty { Text("Favorite studios").font(.title3.bold()); ForEach(studios) { studio in Button(studio.name ?? "Studio") { runtime.routes.append(.studio(studio.id)) } } }
            if [favorites.anime?.pageInfo?.hasNextPage, favorites.manga?.pageInfo?.hasNextPage, favorites.characters?.pageInfo?.hasNextPage, favorites.staff?.pageInfo?.hasNextPage, favorites.studios?.pageInfo?.hasNextPage].contains(true) { Button("Load more favorites") { reads.run { await loadFavorites() } }.disabled(favoritesBusy) }
            if (favorites.anime?.items.isEmpty ?? true) && (favorites.manga?.items.isEmpty ?? true) && (favorites.characters?.items.isEmpty ?? true) && (favorites.staff?.items.isEmpty ?? true) && (favorites.studios?.items.isEmpty ?? true) {
                Text("No favorites to show yet.").foregroundStyle(.secondary)
            }
        }
        if favoritesBusy { ProgressView().controlSize(.small) }
    }
    private func load(refresh: Bool = false) async {
        error = nil
        do { let result = try await runtime.repository.profile(id, refresh: refresh); try Task.checkCancellation(); user = result.value.User; stale = result.cachedAt; partial = result.isPartial; if user == nil { error = "This profile isn’t available." } }
        catch { runtime.handle(error); if !(error is CancellationError) { self.error = (error as? MLError)?.localizedDescription ?? MLError.offline.localizedDescription } }
    }
    private func loadFavorites(replacing: Bool = false) async {
        guard let lease = favoritesRequest.begin(replacing: replacing) else { return }; favoritesError = nil
        defer { favoritesRequest.finish(lease) }
        do {
            let result = try await runtime.repository.favorites(id, page: favoritesPage + 1)
            try Task.checkCancellation()
            guard favoritesRequest.owns(lease) else { return }
            guard let incoming = result.value.User?.favourites else { throw MLError.invalidResponse }
            var previous = favoriteItems
            previous.anime = merge(previous.anime, incoming.anime); previous.manga = merge(previous.manga, incoming.manga)
            previous.characters = merge(previous.characters, incoming.characters); previous.staff = merge(previous.staff, incoming.staff); previous.studios = merge(previous.studios, incoming.studios)
            favoriteItems = previous
            favoritesPartial = favoritesPartial || result.isPartial
            if let date = result.cachedAt { favoritesStale = min(favoritesStale ?? date, date) }
            favoritesPage += 1
        } catch { if favoritesRequest.owns(lease), !Task.isCancelled, !(error is CancellationError) { runtime.handle(error); favoritesError = (error as? MLError)?.localizedDescription ?? MLError.offline.localizedDescription } }
    }
    private func merge<T: Codable & Sendable & Identifiable>(_ old: MLConnection<T>?, _ new: MLConnection<T>?) -> MLConnection<T>? {
        let result = MLPageWindow.merge(old, new)
        favoritesReleased = favoritesReleased || result.released
        return result.connection
    }
    private func follow() {
        guard !followingBusy else { return }; followingBusy = true
        Task { defer { followingBusy = false }; do { try await runtime.repository.toggleFollow(id); guard !runtime.stopped else { return }; user?.isFollowing.toggleOptional(); runtime.didMutate() } catch { runtime.handle(error); self.error = (error as? MLError)?.localizedDescription ?? MLError.rejected.localizedDescription } }
    }
}
private extension Optional where Wrapped == Bool { mutating func toggleOptional() { self = !(self ?? false) } }

struct MLStatisticsPanel: View {
    let title: String
    let stats: MLStats?
    let type: MLMediaType
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            if let stats {
                Text("\(stats.libraryCount) library titles").font(.title2.weight(.semibold)).monospacedDigit()
                if let mean = stats.meanScore { Text("\(mean.formatted(.number.precision(.fractionLength(1)))) mean score").foregroundStyle(.secondary) }
                if let minutes = stats.minutesWatched { Text("\((Double(minutes) / 60).formatted(.number.precision(.fractionLength(1)))) hours watched").foregroundStyle(.secondary) }
                if let chapters = stats.chaptersRead { Text("\(chapters.formatted()) chapters read").foregroundStyle(.secondary) }
                if let volumes = stats.volumesRead { Text("\(volumes.formatted()) volumes read").foregroundStyle(.secondary) }
                ForEach(stats.statuses?.compactMap { $0 }.indices.map { $0 } ?? [], id: \.self) { index in
                    if let status = stats.statuses?.compactMap({ $0 })[index] {
                        HStack { Text(status.status?.title(for: type) ?? "Other"); Spacer(); Text("\(status.count ?? 0)").monospacedDigit() }.font(.caption)
                        ProgressView(value: Double(status.count ?? 0), total: Double(max(stats.statuses?.compactMap { $0?.count }.reduce(0, +) ?? 0, 1))).accessibilityLabel(status.status?.title(for: type) ?? "List status")
                    }
                }
            } else { Text("Statistics aren’t available.").foregroundStyle(.secondary) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading).modifier(MLPanel())
    }
}
struct MLBioEditor: View {
    @Environment(MLRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    @State var text: String
    let saved: (String) -> Void
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your AniList bio").font(.title2.bold())
            TextEditor(text: $text).frame(height: 200).accessibilityLabel("Profile biography")
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy); Spacer(); if busy { ProgressView().controlSize(.small) }; Button("Save") { busy = true; Task { defer { busy = false }; do { try await runtime.repository.updateBio(text); saved(text); dismiss() } catch { self.error = (error as? MLError)?.localizedDescription ?? MLError.rejected.localizedDescription } } }.buttonStyle(.borderedProminent).disabled(busy) }
        }.padding(24).frame(width: 560)
    }
}

struct MLFollowersView: View {
    @Environment(MLRuntime.self) private var runtime
    let userID: Int
    let following: Bool
    @State private var store = MLPageStore()
    private var users: [MLUser] { (following ? store.data.following : store.data.followers)?.compactMap { $0 } ?? [] }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            if let error = store.error { Text(error).foregroundStyle(.secondary) }
            MLStaleBanner(date: store.staleDate, partial: store.partial)
            ForEach(users) { MLUserButton(user: $0) }
            if store.page > 0 && users.isEmpty { Text("No \(following ? "following" : "followers") to show.").foregroundStyle(.secondary) }
            MLLoadMoreView(store: store) { await load() }
        }.mlTask(id: "follows/\(userID)/\(following)") {
            await store.loadInitial(key: "follows/\(userID)/\(following)") {
                try await runtime.repository.follows(userID, following: following, page: $0)
            }
        }
    }
    private func load(reset: Bool = false) async { await store.load(reset: reset) { try await runtime.repository.follows(userID, following: following, page: $0) } }
}
struct MLUserButton: View {
    @Environment(MLRuntime.self) private var runtime
    let user: MLUser
    var body: some View {
        Button { runtime.routes.append(.profile(user.id)) } label: { HStack { MLArtwork(url: user.avatar?.medium, width: 34, height: 34, radius: 17); Text(user.name ?? "AniList member").font(.headline) } }.buttonStyle(.plain)
    }
}

struct MLActivityView: View {
    @Environment(MLRuntime.self) private var runtime
    let userID: Int?
    @State private var following = true
    @State private var draft = ""
    @State private var posting = false
    @State private var error: String?
    @State private var store = MLPageStore()
    @State private var reads = MLReadActions()
    private var feedKey: String { "feed/\(userID ?? 0)/\(following)/\(runtime.viewer?.id ?? 0)/\(runtime.mutationRevision)" }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(userID == nil ? "Activity" : "Recent activity").font(.title2.bold())
                    Spacer()
                    if userID == nil { Picker("Feed", selection: Binding(get: { runtime.viewer != nil && following }, set: { following = $0 })) { Text("Following").tag(true); Text("Global").tag(false) }.pickerStyle(.segmented).frame(width: 210).disabled(runtime.viewer == nil) }
                    Button("Refresh", systemImage: "arrow.clockwise") { reads.run { await load(reset: true, refresh: true) } }.labelStyle(.iconOnly).disabled(store.loading)
                }
                if userID == nil && runtime.viewer == nil { Text("Connect AniList to see activity from people you follow.").font(.caption).foregroundStyle(.secondary) }
                if runtime.viewer != nil && (userID == nil || userID == runtime.viewer?.id) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextEditor(text: $draft).frame(height: 65).accessibilityLabel("New AniList activity")
                        HStack {
                            Text(draft.isEmpty || MLPostTextKind.activity.accepts(draft) ? "Share an update with AniList." : "Use 5–10,000 characters.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Post") { post() }.disabled(posting || !MLPostTextKind.activity.accepts(draft))
                        }
                    }.padding(14).modifier(MLPanel())
                }
                MLStaleBanner(date: store.staleDate, partial: store.partial)
                if let error = error ?? store.error { Text(error).foregroundStyle(.orange).font(.callout) }
                ForEach(store.data.activities?.compactMap { $0 } ?? []) { MLActivityCard(activity: $0) }
                if store.page > 0 && (store.data.activities ?? []).isEmpty { ContentUnavailableView("No activity yet", systemImage: "text.bubble") }
                MLLoadMoreView(store: store) { await load() }
            }.padding(26).frame(maxWidth: 800).frame(maxWidth: .infinity)
        }.mlTask(id: feedKey) {
            await store.loadInitial(key: feedKey) {
                try await runtime.repository.feed(userID: userID, following: userID == nil && following && runtime.viewer != nil, page: $0)
            }
        }.mlReadActions(reads, id: feedKey)
    }
    private func load(reset: Bool = false, refresh: Bool = false) async {
        await store.load(reset: reset, preservingData: reset) { try await runtime.repository.feed(userID: userID, following: userID == nil && following && runtime.viewer != nil, page: $0, refresh: refresh) }
    }
    private func post() {
        guard !posting else { return }; posting = true; error = nil
        Task { defer { posting = false }; do { try await runtime.repository.postActivity(draft); guard !runtime.stopped else { return }; draft = ""; runtime.didMutate() } catch { runtime.handle(error); self.error = (error as? MLError)?.localizedDescription ?? MLError.rejected.localizedDescription } }
    }
}
struct MLActivityCard: View {
    @Environment(MLRuntime.self) private var runtime
    let activity: MLActivity
    @State private var liked: Bool?
    @State private var busy = false
    @State private var expanded = false
    @State private var reply = ""
    @State private var error: String?
    @State private var replies = MLPageStore()
    private var isLiked: Bool { liked ?? activity.isLiked ?? false }
    private var likeCount: Int { max(0, (activity.likeCount ?? 0) + (isLiked == (activity.isLiked ?? false) ? 0 : (isLiked ? 1 : -1))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { if let user = activity.user { MLUserButton(user: user) }; Spacer(); if let created = activity.createdAt { Text(Date(timeIntervalSince1970: Double(created)), format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) } }
            if let text = activity.text { MLRichText(text: text, fallbackURL: activity.siteUrl ?? URL(string: "https://anilist.co/activity/\(activity.id)")) }
            if let media = activity.media {
                HStack { MLArtwork(url: media.coverImage?.medium, width: 44, height: 66); VStack(alignment: .leading, spacing: 6) { Text([activity.status, activity.progress].compactMap { $0 }.joined(separator: " ")).font(.callout).foregroundStyle(.secondary); Button(media.name) { runtime.routes.append(.media(media.id)) }.buttonStyle(.plain).font(.headline) } }
            }
            HStack {
                Button { like() } label: { Label("\(likeCount)", systemImage: isLiked ? "heart.fill" : "heart") }
                    .disabled(busy || runtime.viewer == nil)
                    .help(isLiked ? "Unlike activity" : "Like activity")
                    .accessibilityLabel(isLiked ? "Unlike activity" : "Like activity")
                    .accessibilityValue("\(likeCount) likes")
                Button("\(activity.replyCount ?? 0) replies", systemImage: "text.bubble") { expanded.toggle() }
                Spacer()
            }.buttonStyle(.borderless)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if expanded {
                Divider()
                MLStaleBanner(date: replies.staleDate, partial: replies.partial)
                ForEach(replies.data.activityReplies?.compactMap { $0 } ?? []) { MLReplyRow(reply: $0, activityID: activity.id) }
                MLLoadMoreView(store: replies) { await loadReplies() }
                if let error = replies.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                if runtime.viewer != nil {
                    HStack { TextField("Write a reply", text: $reply).textFieldStyle(.roundedBorder); Button("Reply") { sendReply() }.disabled(busy || !MLPostTextKind.reply.accepts(reply)) }
                    if !reply.isEmpty && !MLPostTextKind.reply.accepts(reply) { Text("Use 2–8,000 characters.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.padding(18).modifier(MLPanel())
            .mlTask(id: "replies/\(activity.id)/\(expanded)") {
                if expanded {
                    await replies.loadInitial(key: "replies/\(activity.id)") { try await runtime.repository.replies(activity.id, page: $0) }
                }
            }
    }
    private func loadReplies(reset: Bool = false) async { await replies.load(reset: reset) { try await runtime.repository.replies(activity.id, page: $0, refresh: reset) } }
    private func like() {
        busy = true; error = nil
        Task { defer { busy = false }; do { try await runtime.repository.toggleLike(activity.id); guard !runtime.stopped else { return }; liked = !(liked ?? activity.isLiked ?? false) } catch { runtime.handle(error); self.error = (error as? MLError)?.localizedDescription ?? MLError.rejected.localizedDescription } }
    }
    private func sendReply() {
        busy = true; error = nil
        Task { defer { busy = false }; do { try await runtime.repository.postReply(reply, activityID: activity.id); guard !runtime.stopped else { return }; reply = ""; await loadReplies(reset: true) } catch { runtime.handle(error); self.error = (error as? MLError)?.localizedDescription ?? MLError.rejected.localizedDescription } }
    }
}
struct MLReplyRow: View {
    @Environment(MLRuntime.self) private var runtime
    let reply: MLReply
    let activityID: Int
    @State private var liked: Bool?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let user = reply.user { MLUserButton(user: user) }
            MLRichText(text: reply.text ?? "Reply unavailable", fallbackURL: URL(string: "https://anilist.co/activity/\(activityID)"))
            Button { busy = true; Task { defer { busy = false }; do { try await runtime.repository.toggleLike(reply.id, reply: true); liked = !(liked ?? reply.isLiked ?? false) } catch { self.error = (error as? MLError)?.localizedDescription ?? MLError.rejected.localizedDescription } } } label: { Label((liked ?? reply.isLiked ?? false) ? "Unlike reply" : "Like reply", systemImage: (liked ?? reply.isLiked ?? false) ? "heart.fill" : "heart") }.buttonStyle(.borderless).disabled(busy || runtime.viewer == nil)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(12)
    }
}

struct MLEntityView: View {
    enum Kind: String { case character, staff, studio }
    @Environment(MLRuntime.self) private var runtime
    let id: Int
    let kind: Kind
    @State private var person: MLPerson?
    @State private var studio: MLStudio?
    @State private var works: [MLMedia] = []
    @State private var page = 0
    @State private var next = false
    @State private var request = MLReadRequest()
    private var busy: Bool { request.loading }
    @State private var error: String?
    @State private var favoriting = false
    @State private var earlierPagesReleased = false
    @State private var stale: Date?
    @State private var partial = false
    @State private var reads = MLReadActions()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error { MLErrorBanner(message: error) }
                MLStaleBanner(date: stale, partial: partial)
                HStack(alignment: .top, spacing: 22) {
                    if kind != .studio { MLArtwork(url: person?.image?.large, width: 120, height: 165) }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(person?.name?.full ?? studio?.name ?? "Loading…").font(.largeTitle.bold())
                        Text(kind.rawValue.capitalized).foregroundStyle(.secondary)
                        if let roles = person?.primaryOccupations { Text(roles.joined(separator: " · ")).font(.callout) }
                        if let native = person?.name?.native { Text(native).foregroundStyle(.secondary) }
                        Button { favorite() } label: { Label((person?.isFavourite ?? studio?.isFavourite ?? false) ? "Favorited" : "Favorite", systemImage: (person?.isFavourite ?? studio?.isFavourite ?? false) ? "heart.fill" : "heart") }.disabled(runtime.viewer == nil || favoriting || page == 0)
                            .accessibilityLabel((person?.isFavourite ?? studio?.isFavourite ?? false) ? "Remove from favorites" : "Add to favorites")
                    }
                }
                if let description = person?.description { MLRichText(text: description, fallbackURL: URL(string: "https://anilist.co/\(kind.rawValue)/\(id)")).frame(maxWidth: 760, alignment: .leading) }
                Text("Related works").font(.title3.bold())
                MLMediaGrid(media: works)
                MLPageWindowNotice(released: earlierPagesReleased)
                if busy { ProgressView().controlSize(.small) }
                if next || error != nil { Button(error == nil ? "Load more" : "Retry") { reads.run { await load() } }.disabled(busy) }
            }.padding(26).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.mlTask(id: "entity/\(kind)/\(id)") { if page == 0 { await load(replacing: true) } }
            .mlReadActions(reads, id: "\(kind)/\(id)")
    }
    private func load(replacing: Bool = false) async {
        guard let lease = request.begin(replacing: replacing) else { return }; error = nil
        defer { request.finish(lease) }
        do {
            let connection: MLConnection<MLMedia>?
            if kind == .studio { let value = try await runtime.repository.studio(id, page: page + 1); try Task.checkCancellation(); guard request.owns(lease) else { return }; studio = value.value; connection = value.value?.media; partial = partial || value.isPartial; if let date = value.cachedAt { stale = min(stale ?? date, date) }; if value.value == nil { throw MLError.invalidResponse } }
            else { let value = try await runtime.repository.person(id, staff: kind == .staff, page: page + 1); try Task.checkCancellation(); guard request.owns(lease) else { return }; person = value.value; connection = value.value?.media; partial = partial || value.isPartial; if let date = value.cachedAt { stale = min(stale ?? date, date) }; if value.value == nil { throw MLError.invalidResponse } }
            guard !runtime.stopped else { return }
            let new = connection?.items ?? []
            let merged = MLPageWindow.merge(works, new)
            works = merged.items; earlierPagesReleased = earlierPagesReleased || merged.released
            next = connection?.pageInfo?.hasNextPage ?? false; page += 1
        } catch { if request.owns(lease), !Task.isCancelled, !(error is CancellationError) { self.error = (error as? MLError)?.localizedDescription ?? MLError.offline.localizedDescription } }
    }
    private func favorite() {
        favoriting = true
        Task { defer { favoriting = false }; do { try await runtime.repository.toggleFavorite(id, kind: kind.rawValue); person?.isFavourite.toggleOptional(); studio?.isFavourite.toggleOptional(); runtime.didMutate() } catch { runtime.handle(error); self.error = (error as? MLError)?.localizedDescription ?? MLError.rejected.localizedDescription } }
    }
}
