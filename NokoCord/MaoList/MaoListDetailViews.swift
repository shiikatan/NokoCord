import SwiftUI
import Observation

struct MLMediaDetailView: View {
    @Environment(MLRuntime.self) private var runtime
    let id: Int
    @State private var media: MLMedia?
    @State private var hasDetails = false
    @State private var canEdit = false
    init(id: Int, preview: MLMedia? = nil) {
        self.id = id
        _media = State(initialValue: preview?.id == id ? preview : nil)
    }
    @State private var error: String?
    @State private var stale: Date?
    @State private var partial = false
    @State private var editor = false
    @State private var favoriteBusy = false
    @State private var detailsExpanded = false
    @State private var external: URL?
    @State private var browserConfirmation = false
    @State private var reads = MLReadActions()
    @Environment(\.mlPalette) private var palette
    private var scoreFormat: MLScoreFormat { MLScoreFormat(rawValue: runtime.viewer?.mediaListOptions?.scoreFormat ?? "") ?? .hundred }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if let error { MLErrorBanner(message: error) }
                    MLStaleBanner(date: stale, partial: partial)
                    if let media {
                        hero(media, compact: geometry.size.width < 620)
                        if hasDetails {
                            overview(media, wide: geometry.size.width >= 860)
                            relations(media)
                            VStack(alignment: .leading, spacing: 18) {
                                Text("Explore this title").font(.title3.weight(.semibold))
                                MLMediaSectionsView(mediaID: id).id(id)
                            }.padding(20).modifier(MLPanel())
                            resources(media)
                        } else if error == nil {
                            ProgressView("Loading additional details…").controlSize(.small)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if error == nil {
                        ProgressView("Loading details…").frame(maxWidth: .infinity, minHeight: 200)
                    }
                    if error != nil || stale != nil || partial {
                        Button(error != nil ? "Retry" : "Refresh details") { reads.run { await load(refresh: true) } }
                    }
                }.padding(24).frame(maxWidth: 1140, alignment: .leading).frame(maxWidth: .infinity)
            }
        }.mlTask(id: "media/\(id)") { await load() }
            .mlReadActions(reads, id: "\(id)")
            .sheet(isPresented: $editor) { if let media { MLListEditor(media: media) { self.media = $0 }.environment(runtime) } }
    }
    private func hero(_ media: MLMedia, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let banner = media.bannerImage {
                GeometryReader { geometry in
                    MLArtwork(url: banner, width: geometry.size.width, height: 176, radius: 0)
                        .overlay(LinearGradient(colors: [.clear, palette.surface.opacity(0.3), palette.surface], startPoint: .top, endPoint: .bottom))
                }.frame(height: 176).padding(.bottom, -52)
            }
            HStack(alignment: .center, spacing: compact ? 16 : 24) {
                MLArtwork(url: media.coverImage?.large, width: compact ? 96 : 136, height: compact ? 144 : 204, radius: 12)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.surface, lineWidth: 3))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
                VStack(alignment: .leading, spacing: 12) {
                    Text([media.summary, media.status?.mlWords].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(media.name).font(.system(size: compact ? 21 : 28, weight: .bold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if let score = media.averageScore {
                        HStack(spacing: 7) {
                            Image(systemName: "star.fill").foregroundStyle(palette.accent)
                            Text("\(score)%").fontWeight(.semibold).monospacedDigit()
                            Text("AniList average").foregroundStyle(.secondary)
                        }.font(.callout).accessibilityElement(children: .ignore)
                            .accessibilityLabel("AniList average: \(score)%")
                    }
                    if let episode = media.nextAiringEpisode {
                        Label("Episode \(episode.episode) · \(Date(timeIntervalSince1970: Double(episode.airingAt)).formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar")
                            .font(.caption).foregroundStyle(palette.accent).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 6)
            }.padding(24)
        }.modifier(MLPanel()).clipShape(.rect(cornerRadius: 16))
    }
    @ViewBuilder private func overview(_ media: MLMedia, wide: Bool) -> some View {
        if wide {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) { synopsis(media); classification(media) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 20) { trackingPanel(media); metadata(media) }.frame(width: 290)
            }
        } else {
            trackingPanel(media)
            synopsis(media)
            metadata(media)
            classification(media)
        }
    }
    private func trackingPanel(_ media: MLMedia) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your list", systemImage: "bookmark").font(.headline)
            if let entry = media.mediaListEntry {
                HStack {
                    trackingStatus(entry, type: media.type ?? .anime)
                    Spacer()
                    if let score = entry.score {
                        Text(scoreFormat.label(score)).font(.callout).monospacedDigit()
                            .accessibilityLabel("Your score: \(scoreFormat.label(score))")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(trackingProgress(entry, media: media)).font(.callout).foregroundStyle(.secondary)
                    if let total = media.length, total > 0 {
                        ProgressView(value: Double(min(entry.progress ?? 0, total)), total: Double(total))
                            .accessibilityLabel("Your progress")
                    }
                }
            } else {
                Text("Keep your progress and rating in one place.").font(.callout).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { entryActions(media) }
                VStack(alignment: .leading, spacing: 8) { entryActions(media) }
            }.controlSize(.regular)
            if runtime.viewer == nil {
                Button("Connect AniList") { runtime.connect() }.buttonStyle(.borderless)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).modifier(MLPanel())
    }
    @ViewBuilder private func synopsis(_ media: MLMedia) -> some View {
        if let description = media.description, !description.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Label("Synopsis", systemImage: "text.alignleft").font(.headline).accessibilityAddTraits(.isHeader)
                MLRichText(text: description, fallbackURL: URL(string: "https://anilist.co/\(media.type == .manga ? "manga" : "anime")/\(id)"))
                    .lineLimit(detailsExpanded ? nil : 9).fixedSize(horizontal: false, vertical: true)
                Button { detailsExpanded.toggle() } label: {
                    Label(detailsExpanded ? "Show less" : "Read full synopsis", systemImage: detailsExpanded ? "chevron.up" : "chevron.down")
                }.buttonStyle(.borderless).font(.callout)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).modifier(MLPanel())
        }
    }
    @ViewBuilder private func classification(_ media: MLMedia) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let genres = media.genres, !genres.isEmpty {
                Text("Genres & themes").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading, spacing: 8) {
                    ForEach(genres, id: \.self) { genre in
                        Text(genre).font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7)
                            .frame(maxWidth: .infinity).background(palette.accent.opacity(0.09), in: Capsule())
                    }
                }
            }
            if let tags = media.tags?.compactMap({ $0 }), !tags.isEmpty { MLTagList(tags: tags) }
            if let titles = media.title {
                DisclosureGroup("Alternative titles") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(Set([titles.romaji, titles.english, titles.native].compactMap { $0 }.filter { !$0.isEmpty })).sorted(), id: \.self) { title in
                            Text(title).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.padding(.top, 8)
                }.font(.callout)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).modifier(MLPanel())
    }
    @ViewBuilder private func relations(_ media: MLMedia) -> some View {
        if let edges = media.relations?.edges?.compactMap({ $0 }), !edges.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Related titles").font(.title3.weight(.semibold))
                    Text("\(edges.count)").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(edges.indices, id: \.self) { index in
                            if let related = edges[index].node {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(edges[index].relationType?.mlWords ?? "Related")
                                        .font(.caption.weight(.medium)).foregroundStyle(palette.accent)
                                    MLMediaCard(media: related)
                                }
                            }
                        }
                    }.padding(.bottom, 4)
                }.scrollIndicators(.hidden)
            }
        }
    }
    @ViewBuilder private func resources(_ media: MLMedia) -> some View {
        if let links = media.externalLinks?.compactMap({ $0 }), !links.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Label("Watch, read & resources", systemImage: "arrow.up.right.square").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], alignment: .leading, spacing: 10) {
                    ForEach(links) { link in
                        if let url = link.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                            Link(destination: url) { HStack { Text(link.site ?? "Open resource"); Spacer(); Image(systemName: "arrow.up.right").font(.caption) } }
                                .font(.callout).padding(12).background(palette.background, in: .rect(cornerRadius: 10))
                        }
                    }
                }
            }.padding(20).modifier(MLPanel())
        }
    }
    private func trackingStatus(_ entry: MLListState, type: MLMediaType) -> some View {
        Text(entry.status?.title(for: type) ?? "On your list").font(.caption.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 5).background(.tint.opacity(0.12), in: .capsule)
    }
    private func trackingProgress(_ entry: MLListState, media: MLMedia) -> String {
        let total = media.length.map { " of \($0)" } ?? ""
        return "\(entry.progress ?? 0)\(total) \(media.type == .manga ? "chapters" : "episodes")"
    }
    @ViewBuilder private func entryActions(_ media: MLMedia) -> some View {
        Button { editor = true } label: { Label(media.mediaListEntry == nil ? "Add to list" : "Edit entry", systemImage: media.mediaListEntry == nil ? "plus" : "slider.horizontal.3") }
            .buttonStyle(.borderedProminent).disabled(runtime.viewer == nil || !canEdit)
        Button { toggleFavorite() } label: { Label(media.isFavourite == true ? "Favorited" : "Favorite", systemImage: media.isFavourite == true ? "heart.fill" : "heart") }
            .buttonStyle(.bordered).disabled(runtime.viewer == nil || favoriteBusy || !canEdit)
    }
    private func metadata(_ media: MLMedia) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("At a glance", systemImage: "info.circle").font(.headline)
            VStack(spacing: 12) {
                if let length = media.length { fact(media.type == .manga ? "Chapters" : "Episodes", value: "\(length)") }
                if let volumes = media.volumes { fact("Volumes", value: "\(volumes)") }
                if let duration = media.duration { fact("Duration", value: "\(duration) min") }
                if let source = media.source { fact("Source", value: source.mlWords) }
                if let popularity = media.popularity { fact("Popularity", value: popularity.formatted()) }
                if let start = media.startDate, !start.label.isEmpty { fact("Released", value: start.label) }
            }
            if let studios = media.studios?.items, !studios.isEmpty {
                Divider()
                ForEach(studios) { studio in
                    Button(studio.name ?? "Studio") { runtime.routes.append(.studio(studio.id)) }.buttonStyle(.borderless).font(.callout)
                }
            }
            if let ranks = media.rankings?.compactMap({ $0 }), !ranks.isEmpty {
                Divider()
                ForEach(ranks) { rank in
                    if let value = rank.rank {
                        Label("#\(value) \(rank.context ?? rank.type?.mlWords ?? "ranking")", systemImage: "chart.bar")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).modifier(MLPanel())
    }
    private func fact(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.callout)
    }
    private func load(refresh: Bool = false) async {
        error = nil
        do {
            if !hasDetails, let saved = try? await runtime.repository.savedMedia(id), let loaded = saved.value.Media {
                try Task.checkCancellation()
                media = loaded; hasDetails = true; stale = saved.cachedAt; partial = saved.isPartial
            }
            let result = try await runtime.repository.media(id, refresh: refresh)
            try Task.checkCancellation()
            media = result.value.Media; stale = result.cachedAt; partial = result.isPartial
            hasDetails = media != nil; canEdit = !result.isPartial && !result.isStale
            if let media { runtime.rememberMedia(media) }
            if media == nil { error = "This title isn’t available on AniList." }
        } catch { runtime.handle(error); if !(error is CancellationError) { self.error = (error as? MLError)?.localizedDescription ?? MLError.offline.localizedDescription } }
    }
    private func toggleFavorite() {
        guard let media, !favoriteBusy else { return }
        favoriteBusy = true
        Task {
            defer { favoriteBusy = false }
            do { try await runtime.repository.toggleFavorite(id, kind: media.type == .manga ? "manga" : "anime"); guard !runtime.stopped else { return }; self.media?.isFavourite = !(media.isFavourite ?? false); runtime.didMutate() }
            catch { runtime.handle(error); self.error = (error as? MLError)?.localizedDescription ?? MLError.rejected.localizedDescription }
        }
    }
}

struct MLRichText: View {
    private let text: String
    @State private var presentation = MLTextPresentation()
    private let fallbackURL: URL?
    private let fallbackLabel: String
    private let notice: String
    @State private var browserConfirmation = false
    init(text: String, fallbackURL: URL? = nil, fallbackLabel: String = "View full content on AniList", notice: String = "Some images or formatting are available on AniList.") {
        self.text = text
        self.fallbackURL = fallbackURL?.scheme == "https" && fallbackURL?.host == "anilist.co" && fallbackURL?.user == nil && fallbackURL?.password == nil ? fallbackURL : nil
        self.fallbackLabel = fallbackLabel; self.notice = notice
    }
    var body: some View {
        let parsed = presentation.resolve(text)
        let content = parsed.content
        let attributed = parsed.attributed
        VStack(alignment: .leading, spacing: 10) {
            if !content.text.isEmpty { Text(attributed).textSelection(.enabled).font(.body).lineSpacing(4) }
            if content.hasUnsupportedContent {
                VStack(alignment: .leading, spacing: 6) {
                    Label(notice, systemImage: "photo").font(.caption).foregroundStyle(.secondary).lineLimit(nil)
                    if fallbackURL != nil { Button(fallbackLabel) { browserConfirmation = true }.buttonStyle(.borderless).font(.caption).lineLimit(nil) }
                }
            }
        }.alert("Open this content in your browser?", isPresented: $browserConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Open") { if let fallbackURL { NSWorkspace.shared.open(fallbackURL) } }
        } message: { Text("MaoList can’t accurately display this content natively. Open it in your browser?") }
    }
}
struct MLTagList: View {
    let tags: [MLTag]
    @State private var spoilers = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tags.filter { spoilers || !($0.isMediaSpoiler == true || $0.isGeneralSpoiler == true) }.compactMap { $0.name }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            if tags.contains(where: { $0.isMediaSpoiler == true || $0.isGeneralSpoiler == true }) { Button(spoilers ? "Hide spoiler tags" : "Reveal spoiler tags") { spoilers.toggle() }.buttonStyle(.borderless).font(.caption) }
        }
    }
}

private struct MLMediaSectionsView: View {
    @Environment(\.mlPalette) private var palette
    let mediaID: Int
    @State private var selected: MLRepository.MediaSection?
    @State private var states = Dictionary(uniqueKeysWithValues: MLRepository.MediaSection.allCases.map { ($0, MLMediaSectionState()) })
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(MLRepository.MediaSection.allCases, id: \.rawValue) { section in
                        let active = selected == section
                        Button { selected = active ? nil : section } label: {
                            Label(section.rawValue.capitalized, systemImage: symbol(section))
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(active ? palette.accent : Color.secondary)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(active ? palette.accent.opacity(0.14) : palette.surface, in: .capsule)
                                .overlay(Capsule().strokeBorder(active ? palette.accent.opacity(0.35) : Color.primary.opacity(0.08)))
                                .contentShape(Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
                            .accessibilityHint(active ? "Hide this section" : "Show this section")
                            .help("\(active ? "Hide" : "Show") \(section.rawValue)")
                    }
                }
            }.scrollIndicators(.hidden)
            if let selected, let state = states[selected] {
                MLMediaSectionView(mediaID: mediaID, section: selected, state: state).id(selected)
            } else {
                Text("Choose a section to explore.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            }
        }
    }
    private func symbol(_ section: MLRepository.MediaSection) -> String {
        switch section {
        case .characters: "person.2"
        case .staff: "person.crop.rectangle"
        case .recommendations: "sparkles"
        case .reviews: "text.bubble"
        }
    }
}

private struct MLMediaSectionView: View {
    @Environment(MLRuntime.self) private var runtime
    let mediaID: Int
    let section: MLRepository.MediaSection
    let state: MLMediaSectionState
    @State private var reads = MLReadActions()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = state.error { Text(error).font(.callout).foregroundStyle(.secondary) }
            MLStaleBanner(date: state.stale, partial: state.partial)
            content
            MLPageWindowNotice(released: state.earlierPagesReleased)
            if state.loading { ProgressView("Loading \(section.rawValue)…").controlSize(.small) }
            if state.next || state.error != nil {
                Button(state.error == nil ? "Load more" : "Retry") { reads.run { await load() } }.disabled(state.loading)
            }
            if state.page > 0 && !state.next && empty { Text("No \(section.rawValue) available.").font(.callout).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .mlTask(id: "\(mediaID)/\(section)") { if state.page == 0 { await load(replacing: true) } }
            .mlReadActions(reads, id: "\(mediaID)/\(section)")
    }
    private var empty: Bool {
        switch section {
        case .characters: state.media?.characters?.items.isEmpty ?? true
        case .staff: state.media?.staff?.items.isEmpty ?? true
        case .recommendations: state.media?.recommendations?.items.isEmpty ?? true
        case .reviews: state.media?.reviews?.items.isEmpty ?? true
        }
    }
    @ViewBuilder private var content: some View {
        switch section {
        case .characters, .staff:
            let people = section == .staff ? state.media?.staff?.items : state.media?.characters?.items
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 14) {
                ForEach(people ?? []) { person in MLPersonButton(person: person, staff: section == .staff) }
            }
        case .recommendations: MLMediaGrid(media: state.media?.recommendations?.items.compactMap(\.mediaRecommendation) ?? [])
        case .reviews:
            ForEach(state.media?.reviews?.items ?? []) { review in
                MLReviewRow(review: review)
            }
        }
    }
    private func load(replacing: Bool = false) async {
        await state.load(repository: runtime.repository, mediaID: mediaID, section: section, replacing: replacing)
    }
}

struct MLPersonButton: View {
    @Environment(MLRuntime.self) private var runtime
    let person: MLPerson
    let staff: Bool
    var body: some View {
        Button { runtime.routes.append(staff ? .staff(person.id) : .character(person.id)) } label: {
            HStack(spacing: 10) { MLArtwork(url: person.image?.medium ?? person.image?.large, width: 44, height: 58); Text(person.name?.full ?? "Unknown").font(.callout).lineLimit(2); Spacer(minLength: 0) }
        }.buttonStyle(.plain)
    }
}
struct MLReviewRow: View {
    @Environment(MLRuntime.self) private var runtime
    let review: MLReview
    var body: some View {
        Button { runtime.routes.append(.review(review.id)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(review.summary ?? "Review").font(.headline)
                Text(review.user?.name ?? "AniList member").font(.caption).foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).modifier(MLPanel())
        }.buttonStyle(.plain)
    }
}
