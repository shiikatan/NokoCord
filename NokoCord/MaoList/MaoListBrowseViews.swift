import SwiftUI
import Observation

private struct MLActiveTask: ViewModifier {
    @Environment(\.controlActiveState) private var active
    @Environment(\.nokoWorkspaceVisible) private var visible
    let id: String
    let action: @MainActor () async -> Void
    func body(content: Content) -> some View {
        content.task(id: id + (active != .inactive && visible ? "/active" : "/inactive")) {
            guard active != .inactive && visible else { return }
            await action()
        }
    }
}
private struct MLReadActionsLifetime: ViewModifier {
    @Environment(\.controlActiveState) private var active
    @Environment(\.nokoWorkspaceVisible) private var visible
    let reads: MLReadActions
    let id: String
    func body(content: Content) -> some View {
        content
            .onAppear { reads.setActive(active != .inactive && visible) }
            .onChange(of: active != .inactive && visible) { _, value in reads.setActive(value) }
            .onChange(of: id) { _, _ in reads.cancel() }
            .onDisappear { reads.setActive(false) }
    }
}
extension View {
    func mlTask(id: String, _ action: @escaping @MainActor () async -> Void) -> some View { modifier(MLActiveTask(id: id, action: action)) }
    func mlReadActions(_ reads: MLReadActions, id: String = "") -> some View { modifier(MLReadActionsLifetime(reads: reads, id: id)) }
}

struct MLSearchView: View {
    @Environment(MLRuntime.self) private var runtime
    let filters: MLSearchFilters
    @State private var store = MLPageStore()
    @State private var reads = MLReadActions()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    MLSectionHeading(title: filters.term.isEmpty ? "Explore \(filters.type.title.lowercased())" : "Results for “\(filters.term)”", subtitle: filters.hasFilters ? "Filtered \(filters.type.title.lowercased()) results" : nil)
                    Picker("Media", selection: Binding(get: { runtime.search.type }, set: { runtime.search.type = $0; runtime.searchConfigured = true })) { ForEach(MLMediaType.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 110)
                    Button("Refresh", systemImage: "arrow.clockwise") { reads.run { await load(reset: true, refresh: true) } }.labelStyle(.iconOnly).disabled(store.loading)
                }
                MLStaleBanner(date: store.staleDate, partial: store.partial)
                if let error = store.error { MLErrorBanner(message: error) }
                if store.loading && store.page == 0 { ProgressView("Searching AniList…").frame(maxWidth: .infinity, minHeight: 120) }
                MLMediaGrid(media: store.data.media?.compactMap { $0 } ?? [])
                if store.page > 0 && (store.data.media ?? []).isEmpty { ContentUnavailableView("No matches", systemImage: "magnifyingglass", description: Text("Try another title or fewer filters.")) }
                MLLoadMoreView(store: store) { await load() }
            }.padding(26).frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }.mlTask(id: String(describing: filters) + "/\(runtime.searchSubmissionRevision)") {
            await store.loadInitial(key: String(describing: filters)) {
                try await runtime.repository.search(filters, page: $0, notBefore: runtime.searchTypingDeadline)
            }
        }.mlReadActions(reads, id: String(describing: filters))
    }
    private func load(reset: Bool = false, refresh: Bool = false) async {
        await store.load(reset: reset, preservingData: reset) { try await runtime.repository.search(filters, page: $0, refresh: refresh) }
    }
}

struct MLLoadMoreView: View {
    let store: MLPageStore
    let load: @MainActor () async -> Void
    @State private var reads = MLReadActions()
    var body: some View {
        VStack(spacing: 8) {
            if store.earlierPagesReleased { Text("Earlier pages were released to keep MaoList light. Refresh to return to the beginning.").font(.caption).foregroundStyle(.secondary) }
            HStack {
            Spacer()
            if store.loading { ProgressView().controlSize(.small) }
            else if store.error != nil { Button("Retry") { reads.run { await load() } } }
            else if store.hasNext { Button("Load more") { reads.run { await load() } } }
            Spacer()
            }
        }.padding(.vertical, 10).mlReadActions(reads, id: store.queryIdentity)
    }
}

struct MLSearchFilterView: View {
    @Environment(MLRuntime.self) private var runtime
    @Binding var filters: MLSearchFilters
    let apply: () -> Void
    @State private var draft = MLSearchFilters()
    @State private var validation: String?
    @State private var genres: [String] = []
    @State private var tags: [String] = []
    private let sorts = ["SEARCH_MATCH", "TRENDING_DESC", "POPULARITY_DESC", "SCORE_DESC", "START_DATE_DESC", "TITLE_ROMAJI"]
    @State private var moreFilters = false
    @Environment(\.mlPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Search filters").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 16) {
                field("Media") { Picker("Media", selection: $draft.type) { ForEach(MLMediaType.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden() }
                field("Sort") { Picker("Sort", selection: $draft.sort) { ForEach(sorts, id: \.self) { Text($0.mlWords).tag($0) } }.labelsHidden() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                groupHeading("Release")
                HStack(alignment: .top, spacing: 16) {
                    field("Season") { Picker("Season", selection: $draft.season) { Text("Any season").tag(""); ForEach(["WINTER", "SPRING", "SUMMER", "FALL"], id: \.self) { Text($0.capitalized).tag($0) } }.labelsHidden() }
                    field("Year") { TextField("Year", value: $draft.year, format: .number.grouping(.never), prompt: Text("Any year")).labelsHidden().accessibilityLabel("Release year") }
                }
                HStack(alignment: .top, spacing: 16) {
                    field("Format") { Picker("Format", selection: $draft.format) { Text("Any format").tag(""); ForEach(["TV", "TV_SHORT", "MOVIE", "SPECIAL", "OVA", "ONA", "MUSIC", "MANGA", "NOVEL", "ONE_SHOT"], id: \.self) { Text($0.mlWords).tag($0) } }.labelsHidden() }
                    field("Status") { Picker("Release status", selection: $draft.status) { Text("Any status").tag(""); ForEach(["FINISHED", "RELEASING", "NOT_YET_RELEASED", "CANCELLED", "HIATUS"], id: \.self) { Text($0.mlWords).tag($0) } }.labelsHidden() }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                groupHeading("Topics")
                HStack(alignment: .top, spacing: 16) {
                    field("Genre") { Picker("Genre", selection: $draft.genre) { Text("Any genre").tag(""); ForEach(genres, id: \.self) { Text($0).tag($0) } }.labelsHidden() }
                    field("Source") { Picker("Source", selection: $draft.source) { Text("Any source").tag(""); ForEach(["ORIGINAL", "MANGA", "LIGHT_NOVEL", "VISUAL_NOVEL", "VIDEO_GAME", "NOVEL", "OTHER"], id: \.self) { Text($0.mlWords).tag($0) } }.labelsHidden() }
                }
                field("Tag") {
                    TextField("AniList tag", text: $draft.tag, prompt: Text("Search tags")).labelsHidden().accessibilityLabel("AniList tag")
                    if !draft.tag.isEmpty {
                        let suggestions = tags.filter { $0.localizedStandardContains(draft.tag) }.prefix(3)
                        ForEach(Array(suggestions), id: \.self) { tag in Button(tag) { draft.tag = tag }.buttonStyle(.borderless).font(.callout) }
                        if suggestions.isEmpty && !tags.isEmpty { Text("No matching AniList tag.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Divider()
            DisclosureGroup("More filters", isExpanded: $moreFilters) {
                HStack(alignment: .top, spacing: 16) {
                    field("Minimum score (%)") { TextField("Minimum score", value: $draft.minimumScore, format: .number, prompt: Text("Any score")).labelsHidden().accessibilityLabel("Minimum score in percent") }
                    field("Minimum popularity") { TextField("Minimum popularity", value: $draft.minimumPopularity, format: .number, prompt: Text("Any popularity")).labelsHidden().accessibilityLabel("Minimum popularity") }
                }.padding(.top, 12)
            }
            if let validation { Text(validation).foregroundStyle(.orange).font(.caption) }
            HStack {
                Button("Clear filters") { let type = draft.type; let term = draft.term; draft = MLSearchFilters(); draft.type = type; draft.term = term; validation = nil }
                Spacer()
                Button("Apply") { submit() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(.top, 4)
        }.padding(20).frame(width: 440).textFieldStyle(.roundedBorder).pickerStyle(.menu)
            .background(palette.background)
            .onAppear { draft = filters; moreFilters = draft.minimumScore != nil || draft.minimumPopularity != nil }
            .mlTask(id: "taxonomy") {
                if let data = try? await runtime.repository.taxonomy().value {
                    genres = data.GenreCollection ?? []; tags = data.MediaTagCollection?.compactMap { $0?.name } ?? []
                }
            }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
    private func groupHeading(_ title: String) -> some View {
        Text(title).font(.callout.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }
    private func submit() {
        if !draft.tag.isEmpty && !tags.isEmpty {
            guard let exact = tags.first(where: { $0.caseInsensitiveCompare(draft.tag) == .orderedSame }) else { validation = "Choose a matching AniList tag from the suggestions."; return }
            draft.tag = exact
        }
        if let score = draft.minimumScore, !(1...100).contains(score) { validation = "Use a minimum score from 1 to 100."; return }
        if let year = draft.year, !(1900...2200).contains(year) { validation = "Use a year between 1900 and 2200."; return }
        if let popularity = draft.minimumPopularity, popularity < 0 { validation = "Popularity cannot be negative."; return }
        filters = draft; apply()
    }

}
extension String { var mlWords: String { replacingOccurrences(of: "_DESC", with: "").replacingOccurrences(of: "_", with: " ").capitalized } }

struct MLDiscoveryView: View {
    @State private var type: MLMediaType = .anime
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                HStack { MLSectionHeading(title: "Discover", subtitle: "A new season. A different world. Your next favorite."); Picker("Media", selection: $type) { ForEach(MLMediaType.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 180) }
                if type == .anime { MLDiscoveryShelf(title: "This season", type: type, sort: "POPULARITY_DESC", seasonOffset: 0) }
                MLDiscoveryShelf(title: "Trending", type: type, sort: "TRENDING_DESC")
                MLDiscoveryShelf(title: "Popular", type: type, sort: "POPULARITY_DESC")
                MLDiscoveryShelf(title: "Top rated", type: type, sort: "SCORE_DESC")
                if type == .anime { MLDiscoveryShelf(title: "Next season", type: type, sort: "POPULARITY_DESC", seasonOffset: 1) }
            }.padding(26).frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }
    }
}
struct MLDiscoveryShelf: View {
    @Environment(MLRuntime.self) private var runtime
    let title: String
    let type: MLMediaType
    let sort: String
    var seasonOffset: Int? = nil
    @State private var store = MLPageStore()
    private var filters: MLSearchFilters { .discovery(type: type, sort: sort, seasonOffset: seasonOffset) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(title).font(.title3.bold()); Spacer(); Button { runtime.searchTypingDeadline = nil; runtime.search = filters; runtime.searching = true } label: { Label("Explore", systemImage: "arrow.up.right").font(.caption.weight(.semibold)) }.buttonStyle(.borderless).accessibilityLabel("Explore \(title.lowercased()) \(title.localizedStandardContains(type.title) ? "" : type.title.lowercased())".trimmingCharacters(in: .whitespaces)) }
            if let error = store.error { Text(error).font(.callout).foregroundStyle(.secondary) }
            MLStaleBanner(date: store.staleDate, partial: store.partial)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18) { ForEach(store.data.media?.compactMap { $0 }.prefix(12).map { $0 } ?? []) { MLMediaCard(media: $0) } }
            }.scrollIndicators(.hidden)
            if store.loading { ProgressView().controlSize(.small) }
        }.mlTask(id: "\(type.rawValue)/\(sort)/\(seasonOffset ?? -1)") { await store.loadInitial(key: String(describing: filters)) { try await runtime.repository.search(filters, page: $0) } }
    }
}

struct MLHomeView: View {
    @Environment(MLRuntime.self) private var runtime
    @State private var reads = MLReadActions()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let viewer = runtime.viewer {
                    HStack {
                        MLSectionHeading(title: "Your next chapter", subtitle: "Welcome back, \(viewer.name ?? "friend"). Pick up where you left off.")
                        if let counts = viewer.statistics { VStack(alignment: .trailing, spacing: 4) { Text("\(counts.anime?.libraryCount ?? 0) anime"); Text("\(counts.manga?.libraryCount ?? 0) manga") }.font(.caption).foregroundStyle(.secondary) }
                        Button("Refresh", systemImage: "arrow.clockwise") { reads.run { await load(refresh: true) } }.labelStyle(.iconOnly).disabled(runtime.home.loading)
                    }
                    MLStaleBanner(date: runtime.home.stale, partial: runtime.home.partial)
                    if let error = runtime.home.error { MLErrorBanner(message: error); Button("Retry") { reads.run { await load(refresh: true) } } }
                    if runtime.home.loading && runtime.home.data == nil { ProgressView("Loading your home…").controlSize(.small) }
                    if runtime.home.data != nil {
                        MLContinueShelf(type: .anime, page: runtime.home.data?.watching, partial: runtime.home.partial)
                        MLContinueShelf(type: .manga, page: runtime.home.data?.reading, partial: runtime.home.partial)
                    }
                    if let media = runtime.home.data?.discovery?.media {
                        HStack {
                            Text("Explore something new").font(.title3.bold())
                            Spacer()
                            Button("Explore") { var filters = MLSearchFilters(); filters.sort = "TRENDING_DESC"; runtime.searchTypingDeadline = nil; runtime.search = filters; runtime.searching = true }
                                .accessibilityLabel("Explore trending anime")
                        }
                        ScrollView(.horizontal) { LazyHStack(alignment: .top, spacing: 18) { ForEach(media.compactMap { $0 }) { MLMediaCard(media: $0) } } }.scrollIndicators(.hidden)
                    }
                } else {
                    MLConnectionPrompt()
                    if !runtime.restoring { MLDiscoveryShelf(title: "Trending anime", type: .anime, sort: "TRENDING_DESC") }
                }
            }.padding(26).frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }.mlTask(id: "home/\(runtime.viewer?.id ?? 0)/\(runtime.mutationRevision)") { await load() }
            .mlReadActions(reads, id: "\(runtime.viewer?.id ?? 0)/\(runtime.mutationRevision)")
    }
    private func load(refresh: Bool = false) async {
        guard let id = runtime.viewer?.id else { return }
        await runtime.home.load(repository: runtime.repository, userID: id, revision: runtime.mutationRevision, refresh: refresh)
        if let user = runtime.home.data?.Viewer { runtime.applyViewer(user, partial: runtime.home.partial) }
    }
}
struct MLContinueShelf: View {
    @Environment(MLRuntime.self) private var runtime
    let type: MLMediaType
    let page: MLPage?
    let partial: Bool
    @AppStorage private var covers: Bool
    @State private var pendingEntries: Set<Int> = []
    @State private var savedEntries: [Int: (media: MLMedia, revision: Int)] = [:]
    init(type: MLMediaType, page: MLPage?, partial: Bool) {
        self.type = type
        self.page = page
        self.partial = partial
        _covers = AppStorage(wrappedValue: false, "maolistContinueCovers.\(type.rawValue)")
    }
    private var sourceEntries: [MLMedia] { page?.mediaList?.compactMap { $0?.media }.prefix(6).map { $0 } ?? [] }
    private var entries: [MLMedia] {
        sourceEntries.map { source in
            guard let saved = savedEntries[source.id]?.media, saved.mediaListEntry != source.mediaListEntry else { return source }
            var updated = source; updated.mediaListEntry = saved.mediaListEntry; return updated
        }
    }
    var body: some View {
        let media = entries
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { shelfHeading; Spacer(minLength: 12); shelfTools(hasEntries: !media.isEmpty) }
                VStack(alignment: .leading, spacing: 10) { shelfHeading; shelfTools(hasEntries: !media.isEmpty) }
            }
            if covers {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(media) { trackingItem($0, artworkCard: true) }
                    }
                }.scrollIndicators(.hidden)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                    ForEach(media) { trackingItem($0, artworkCard: false) }
                }
            }
            if page?.mediaList?.isEmpty == true && !partial { Text(type == .anime ? "Nothing in Watching yet. Discover an anime and add it to your list." : "Nothing in Reading yet. Your next manga is waiting in Discover.").font(.callout).foregroundStyle(.secondary) }
        }
        .onChange(of: sourceEntries.map(\.mediaListEntry)) { _, _ in
            let sources = Dictionary(uniqueKeysWithValues: sourceEntries.map { ($0.id, $0) })
            savedEntries = savedEntries.filter { id, saved in
                guard let source = sources[id] else { return false }
                return saved.media.mediaListEntry != source.mediaListEntry
            }
        }
        .onChange(of: runtime.home.freshRevision) { _, revision in
            // A fresh response requested after the save is authoritative, including server-normalized fields.
            savedEntries = savedEntries.filter { $0.value.revision > revision }
        }
    }
    private var shelfHeading: some View {
        Text(type == .anime ? "Continue Watching" : "Continue Reading").font(.title3.bold()).accessibilityAddTraits(.isHeader)
    }
    private func shelfTools(hasEntries: Bool) -> some View {
        HStack(spacing: 12) {
            if hasEntries {
                Picker("\(type.title) continue layout", selection: $covers) {
                    Image(systemName: "list.bullet").tag(false).help("Rows").accessibilityLabel("Rows")
                    Image(systemName: "square.grid.2x2").tag(true).help("Covers").accessibilityLabel("Covers")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 76).disabled(!pendingEntries.isEmpty)
            }
            Button("Your \(type.title.lowercased()) list") { runtime.section = type == .anime ? .anime : .manga }
        }
    }
    private func trackingItem(_ media: MLMedia, artworkCard: Bool) -> some View {
        MLTrackingRow(media: media, compact: true, artworkCard: artworkCard, onBusyChange: { busy in
            if busy { pendingEntries.insert(media.id) }
            else { pendingEntries.remove(media.id) }
        }, onSaved: { savedEntries[$0.id] = ($0, runtime.mutationRevision + 1) })
    }
}

struct MLLibraryView: View {
    @Environment(MLRuntime.self) private var runtime
    let type: MLMediaType
    private var status: MLListStatus? {
        get { type == .anime ? runtime.animeListStatus : runtime.mangaListStatus }
        nonmutating set {
            if type == .anime { runtime.animeListStatus = newValue }
            else { runtime.mangaListStatus = newValue }
        }
    }
    @State private var query = ""
    @State private var customList = ""
    @State private var sort = "Updated"
    @AppStorage("maolistLibraryGrid") private var grid = false
    @State private var preferencesPresented = false
    @State private var controlsHeight: CGFloat = 0
    @State private var store = MLPageStore()
    @State private var reads = MLReadActions()
    private var media: [MLMedia] {
        let items = store.data.mediaList?.compactMap { $0?.media }.filter {
            (query.isEmpty || $0.name.localizedStandardContains(query)) && (customList.isEmpty || $0.mediaListEntry?.customLists?[customList] == true)
        } ?? []
        if sort == "Title" { return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        if sort == "Score" { return items.sorted { ($0.mediaListEntry?.score ?? 0) > ($1.mediaListEntry?.score ?? 0) } }
        return items
    }
    private var customLists: [String] { (type == .anime ? runtime.viewer?.mediaListOptions?.animeList : runtime.viewer?.mediaListOptions?.mangaList)?.customLists ?? [] }
    var body: some View {
        let visibleMedia = media
        let groups = Dictionary(grouping: visibleMedia, by: { $0.mediaListEntry?.status })
        GeometryReader { viewport in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let viewer = runtime.viewer {
                    VStack(alignment: .leading, spacing: 24) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 20) {
                            libraryHeading(count: visibleMedia.count)
                            Spacer(minLength: 8)
                            librarySearch.frame(width: 200)
                            libraryTools(userID: viewer.id)
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            libraryHeading(count: visibleMedia.count)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) { librarySearch; libraryTools(userID: viewer.id) }
                                VStack(alignment: .leading, spacing: 12) {
                                    librarySearch
                                    libraryTools(userID: viewer.id)
                                }
                            }
                        }
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            statusTab(nil)
                            ForEach(MLListStatus.allCases) { statusTab($0) }
                        }
                    }.scrollIndicators(.hidden).frame(height: 42)
                    MLStaleBanner(date: store.staleDate, partial: store.partial)
                    if let error = store.error { MLErrorBanner(message: error) }
                    }.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                    if status == nil {
                        ForEach(MLListStatus.allCases) { group in
                            let entries = groups[group] ?? []
                            if !entries.isEmpty { librarySection(title: group.title(for: type), items: entries) }
                        }
                        let unknown = groups[nil] ?? []
                        if !unknown.isEmpty { librarySection(title: "Other", items: unknown) }
                    } else if !visibleMedia.isEmpty {
                        librarySection(title: status?.title(for: type) ?? "Library", items: visibleMedia)
                    }
                    if store.loading && store.page == 0 { ProgressView("Loading your list…").frame(maxWidth: .infinity).padding(24) }
                    if store.page == 0 && !store.loading && store.error == nil {
                        ContentUnavailableView("Your library is ready", systemImage: "books.vertical", description: Text("Select MaoList to load your titles."))
                    }
                    if store.page > 0 && visibleMedia.isEmpty {
                        libraryEmptyState
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: max(300, viewport.size.height - controlsHeight - 80))
                    }
                    if store.loading || store.hasNext || store.error != nil || store.earlierPagesReleased {
                        MLLoadMoreView(store: store) { await load(user: viewer.id) }
                    }
                } else { libraryHeading(count: visibleMedia.count); MLConnectionPrompt(type: type) }
            }.padding(28).frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }
        }.mlTask(id: "\(type)/\(status?.rawValue ?? "all")/\(runtime.viewer?.id ?? 0)/\(runtime.mutationRevision)/\(runtime.preparedPageCount(type: type, status: status))") {
            if let id = runtime.viewer?.id {
                await store.loadInitial(key: "\(type)/\(status?.rawValue ?? "all")/\(id)/\(runtime.mutationRevision)") {
                    try await runtime.repository.library(userID: id, type: type, status: status, page: $0)
                }
                await store.hydratePreparedPages(count: runtime.preparedPageCount(type: type, status: status)) {
                    try await runtime.repository.cachedLibrary(userID: id, type: type, status: status, page: $0)
                }
            }
        }
        .sheet(isPresented: $preferencesPresented) { MLListPreferencesView(type: type).environment(runtime) }
        .onChange(of: customLists) { _, names in if !names.contains(customList) { customList = "" } }
        .mlReadActions(reads, id: "\(type)/\(status?.rawValue ?? "all")/\(runtime.viewer?.id ?? 0)/\(runtime.mutationRevision)")
    }
    private var libraryEmptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical")
                .font(.system(size: 76, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("No entries here")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("Try another status or discover something new.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 560)
        .padding(28)
    }
    private func libraryHeading(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(type.title + " library").font(.system(size: 28, weight: .bold, design: .rounded)).tracking(-0.5)
                .accessibilityAddTraits(.isHeader)
            if store.page > 0 { Text("\(count) shown").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            if store.loading && store.page > 0 { ProgressView().controlSize(.small).accessibilityLabel("Updating library") }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var librarySearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search shown titles", text: $query).textFieldStyle(.plain)
            if !query.isEmpty { Button("Clear", systemImage: "xmark.circle.fill") { query = "" }.labelStyle(.iconOnly).buttonStyle(.plain) }
        }.padding(10).frame(minWidth: 170, maxWidth: .infinity).modifier(MLPanel())
    }
    private func libraryTools(userID: Int) -> some View {
        HStack(spacing: 10) {
            Button { preferencesPresented = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless).help("List preferences").accessibilityLabel("List preferences")
            if !customLists.isEmpty {
                Picker("Custom list", selection: $customList) { Text("All custom lists").tag(""); ForEach(customLists, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(maxWidth: 160)
            }
            Picker("Sort loaded entries", selection: $sort) { ForEach(["Updated", "Title", "Score"], id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 100)
            Picker("Library presentation", selection: $grid) {
                Image(systemName: "list.bullet").tag(false).accessibilityLabel("List")
                Image(systemName: "square.grid.2x2").tag(true).accessibilityLabel("Artwork grid")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 76)
            Button("Refresh", systemImage: "arrow.clockwise") { reads.run { await load(user: userID, reset: true, refresh: true) } }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(store.loading)
        }
    }
    private func statusTab(_ value: MLListStatus?) -> some View {
        MLStatusTab(title: value?.title(for: type) ?? "All", selected: status == value) { status = value }
    }
    private func librarySection(title: String, items: [MLMedia]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.title3.weight(.semibold))
                Text("\(items.count) shown").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            }.accessibilityElement(children: .combine)
            if items.isEmpty {
                Text(store.loading ? "Loading entries…" : "No matching entries loaded.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else if grid { MLMediaGrid(media: items) }
            else { LazyVStack(spacing: 8) { ForEach(items) { MLTrackingRow(media: $0) } } }
        }
    }
    private func load(user: Int, reset: Bool = false, refresh: Bool = false) async { await store.load(reset: reset, preservingData: reset) { try await runtime.repository.library(userID: user, type: type, status: status, page: $0, refresh: refresh) } }

}

private struct MLStatusTab: View {
    @Environment(\.mlPalette) private var palette
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(selected ? palette.accent.opacity(0.17) : Color.clear, in: .rect(cornerRadius: 12))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
