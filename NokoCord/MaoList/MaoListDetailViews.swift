import SwiftUI
import Observation

struct MLMediaDetailView: View {
    @Environment(MLRuntime.self) private var runtime
    let id: Int
    @State private var media: MLMedia?
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if let error { MLErrorBanner(message: error) }
                MLStaleBanner(date: stale, partial: partial)
                if let media {
                    hero(media)
                    if let description = media.description, !description.isEmpty {
                        Text("Synopsis").font(.system(size: 20, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        MLRichText(text: description, fallbackURL: URL(string: "https://anilist.co/\(media.type == .manga ? "manga" : "anime")/\(id)")).lineLimit(detailsExpanded ? nil : 8).frame(maxWidth: 720, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        Button(detailsExpanded ? "Show less" : "Read more") { detailsExpanded.toggle() }.buttonStyle(.borderless)
                    }
                    metadata(media)
                    if let edges = media.relations?.edges?.compactMap({ $0 }), !edges.isEmpty {
                        Text("Relations").font(.title3.bold())
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 18) {
                                ForEach(edges.indices, id: \.self) { index in
                                    if let related = edges[index].node { VStack(alignment: .leading, spacing: 6) { Text(edges[index].relationType?.mlWords ?? "Related").font(.caption).foregroundStyle(.secondary); MLMediaCard(media: related) } }
                                }
                            }
                        }.scrollIndicators(.hidden)
                    }
                    MLMediaSectionsView(mediaID: id).id(id)
                    if let links = media.externalLinks?.compactMap({ $0 }), !links.isEmpty {
                        DisclosureGroup("Watch, read, and resources") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], alignment: .leading) {
                                ForEach(links) { link in
                                    if let url = link.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") { Link(link.site ?? "Open resource", destination: url) }
                                }
                            }.padding(.top, 12)
                        }
                    }
                } else if error == nil { ProgressView("Loading details…").frame(maxWidth: .infinity, minHeight: 200) }
                if error != nil { Button("Retry") { reads.run { await load(refresh: true) } } }
            }.padding(26).frame(maxWidth: 1200, alignment: .leading).frame(maxWidth: .infinity)
        }.mlTask(id: "media/\(id)") { await load() }
            .mlReadActions(reads, id: "\(id)")
            .sheet(isPresented: $editor) { if let media { MLListEditor(media: media) { self.media = $0 }.environment(runtime) } }
    }
    @ViewBuilder private func hero(_ media: MLMedia) -> some View {
        if let banner = media.bannerImage {
            VStack(alignment: .leading, spacing: -24) {
                GeometryReader { geometry in
                    MLArtwork(url: banner, width: geometry.size.width, height: 112, radius: 0)
                }.frame(height: 112)
                header(media, overlapsBanner: true).padding(.horizontal, 18).padding(.bottom, 18)
            }
            .modifier(MLPanel())
            .clipShape(.rect(cornerRadius: 16))
        } else { header(media) }
    }
    @ViewBuilder private func header(_ media: MLMedia, overlapsBanner: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 24) {
            MLArtwork(url: media.coverImage?.large, width: 156, height: 234)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(overlapsBanner ? palette.surface : .clear, lineWidth: 2))
            VStack(alignment: .leading, spacing: 12) {
                Text(media.name).font(.largeTitle.bold()).textSelection(.enabled)
                Text([media.summary, media.status?.mlWords].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
                if let score = media.averageScore {
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill").font(.caption).accessibilityHidden(true)
                        Text("\(score)%").font(.callout.weight(.semibold)).monospacedDigit()
                        Text("AniList average").font(.caption).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .ignore).accessibilityLabel("AniList average: \(score)%")
                }
                if let episode = media.nextAiringEpisode { Label("Episode \(episode.episode) airs \(Date(timeIntervalSince1970: Double(episode.airingAt)).formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar").font(.callout).foregroundStyle(.secondary) }
                if let entry = media.mediaListEntry {
                    VStack(alignment: .leading, spacing: 8) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { trackingStatus(entry, type: media.type ?? .anime); Text(trackingProgress(entry, media: media)).font(.callout).foregroundStyle(.secondary) }
                            VStack(alignment: .leading, spacing: 6) { trackingStatus(entry, type: media.type ?? .anime); Text(trackingProgress(entry, media: media)).font(.callout).foregroundStyle(.secondary) }
                        }
                        if let score = entry.score {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("Your score").font(.callout).foregroundStyle(.secondary)
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(scoreFormat.valueLabel(score)).font(.callout).monospacedDigit()
                                    if !scoreFormat.scaleLabel.isEmpty { Text(scoreFormat.scaleLabel).font(.callout).foregroundStyle(.secondary) }
                                }
                            }.accessibilityElement(children: .ignore).accessibilityLabel("Your score: \(scoreFormat.label(score))")
                        }
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { entryActions(media) }
                    VStack(alignment: .leading, spacing: 10) { entryActions(media) }
                }.controlSize(.large).padding(.top, 4)
                if runtime.viewer == nil { Button("Connect AniList to track this title") { runtime.connect() }.buttonStyle(.borderless).font(.caption) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, overlapsBanner ? 42 : 0)
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
            .buttonStyle(.borderedProminent).disabled(runtime.viewer == nil)
        Button { toggleFavorite() } label: { Label(media.isFavourite == true ? "Favorited" : "Favorite", systemImage: media.isFavourite == true ? "heart.fill" : "heart") }
            .buttonStyle(.bordered).disabled(runtime.viewer == nil || favoriteBusy)
    }
    @ViewBuilder private func metadata(_ media: MLMedia) -> some View {
        DisclosureGroup("Details, genres, and tags") {
            VStack(alignment: .leading, spacing: 12) {
                if let titles = media.title { Text([titles.romaji, titles.english, titles.native].compactMap { $0 }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    if let length = media.length { GridRow { Text(media.type == .manga ? "Chapters" : "Episodes").foregroundStyle(.secondary); Text("\(length)") } }
                    if let volumes = media.volumes { GridRow { Text("Volumes").foregroundStyle(.secondary); Text("\(volumes)") } }
                    if let duration = media.duration { GridRow { Text("Duration").foregroundStyle(.secondary); Text("\(duration) minutes") } }
                    if let source = media.source { GridRow { Text("Source").foregroundStyle(.secondary); Text(source.mlWords) } }
                    if let popularity = media.popularity { GridRow { Text("Popularity").foregroundStyle(.secondary); Text(popularity.formatted()) } }
                    if let start = media.startDate, !start.label.isEmpty { GridRow { Text("Released").foregroundStyle(.secondary); Text(start.label) } }
                }.font(.callout)
                if let genres = media.genres { Text(genres.joined(separator: " · ")).font(.callout.weight(.medium)) }
                if let studios = media.studios?.items { VStack(alignment: .leading, spacing: 8) { ForEach(studios) { studio in Button(studio.name ?? "Studio") { runtime.routes.append(.studio(studio.id)) }.buttonStyle(.borderless) } } }
                if let ranks = media.rankings?.compactMap({ $0 }) {
                    ForEach(ranks) { rank in if let value = rank.rank { Text("#\(value) \(rank.context ?? rank.type?.mlWords ?? "ranking")").font(.caption).foregroundStyle(.secondary) } }
                }
                if let tags = media.tags?.compactMap({ $0 }) { MLTagList(tags: tags) }
            }.padding(.top, 14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func load(refresh: Bool = false) async {
        error = nil
        do {
            let result = try await runtime.repository.media(id, refresh: refresh)
            try Task.checkCancellation()
            media = result.value.Media; stale = result.cachedAt; partial = result.isPartial
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
    private let content: MLReadableText
    private let attributed: AttributedString
    private let fallbackURL: URL?
    private let fallbackLabel: String
    private let notice: String
    @State private var browserConfirmation = false
    init(text: String, fallbackURL: URL? = nil, fallbackLabel: String = "View full content on AniList", notice: String = "Some images or formatting are available on AniList.") {
        let readable = MLReadableText(text)
        content = readable
        attributed = (try? AttributedString(markdown: readable.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(readable.text)
        self.fallbackURL = fallbackURL?.scheme == "https" && fallbackURL?.host == "anilist.co" && fallbackURL?.user == nil && fallbackURL?.password == nil ? fallbackURL : nil
        self.fallbackLabel = fallbackLabel; self.notice = notice
    }
    var body: some View {
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
