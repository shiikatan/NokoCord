import SwiftUI

struct MLTrackingRow: View {
    @Environment(MLRuntime.self) private var runtime
    let media: MLMedia
    var compact = false
    var artworkCard = false
    var onBusyChange: (Bool) -> Void = { _ in }
    var onSaved: (MLMedia) -> Void = { _ in }
    @State private var edited: MLMedia?
    @State private var showEditor = false
    @State private var busy = false
    @State private var error: String?
    private var current: MLMedia { edited ?? media }
    private var scoreFormat: MLScoreFormat { MLScoreFormat(rawValue: runtime.viewer?.mediaListOptions?.scoreFormat ?? "") ?? .hundred }
    @Environment(\.mlPalette) private var palette
    @State private var hovered = false
    var body: some View {
        Group {
            if artworkCard { coverCard }
            else { trackingRow }
        }
        .sheet(isPresented: $showEditor) { MLListEditor(media: current) { edited = $0; onSaved($0) }.environment(runtime) }
        .onHover { runtime.anticipateMedia(current, hovering: $0) }
        .onDisappear { runtime.anticipateMedia(current, hovering: false) }
        .onChange(of: media.mediaListEntry?.progress) { _, _ in edited = nil }
    }
    private var coverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            MLMediaCard(media: current)
            VStack(alignment: .leading, spacing: 8) {
                Text(progressLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    .help(progressLabel).accessibilityLabel(progressLabel)
                HStack(spacing: 8) {
                    if let total = media.length, total > 0 {
                        ProgressView(value: Double(min(current.mediaListEntry?.progress ?? 0, total)), total: Double(total))
                            .accessibilityLabel("Tracking progress for \(media.name)")
                    } else { Spacer(minLength: 0) }
                    incrementButton
                    editButton
                }.frame(height: 30)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.frame(width: 152, alignment: .leading)
    }
    private var trackingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Button { runtime.openMedia(current) } label: {
                    MLArtwork(url: media.coverImage?.medium ?? media.coverImage?.large, width: compact ? 52 : 48, height: compact ? 78 : 72, radius: 8)
                }.buttonStyle(.plain).accessibilityLabel("Open \(media.name)")
                VStack(alignment: .leading, spacing: 7) {
                    Button(media.name) { runtime.openMedia(current) }
                        .buttonStyle(.plain).font(.callout.weight(.semibold)).lineLimit(2).help(media.name)
                    HStack(spacing: 6) {
                        Text(media.summary).lineLimit(1)
                        if let episode = media.nextAiringEpisode {
                            let airingDate = Date(timeIntervalSince1970: Double(episode.airingAt))
                            Text("Ep. \(episode.episode) · \(airingDate.formatted(.dateTime.month(.abbreviated).day()))")
                                .lineLimit(1).layoutPriority(1)
                                .help("Episode \(episode.episode) · \(airingDate.formatted(date: .abbreviated, time: .shortened))")
                                .accessibilityLabel("Episode \(episode.episode) airs \(airingDate.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if let total = media.length, total > 0 {
                            ProgressView(value: Double(min(current.mediaListEntry?.progress ?? 0, total)), total: Double(total))
                                .frame(width: compact ? 48 : 70).accessibilityLabel("Tracking progress")
                        }
                        Text(progressLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !compact, let score = current.mediaListEntry?.score, score > 0 {
                    VStack(spacing: 3) {
                        Text(scoreFormat.valueLabel(score)).font(.title3.weight(.semibold)).monospacedDigit()
                        if !scoreFormat.scaleLabel.isEmpty { Text(scoreFormat.scaleLabel).font(.caption2).foregroundStyle(.secondary) }
                    }.frame(minWidth: 54).accessibilityElement(children: .ignore).accessibilityLabel("Your score: \(scoreFormat.label(score))")
                }
                VStack(spacing: 8) {
                    incrementButton
                    editButton
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(14).modifier(MLPanel())
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(hovered ? palette.accent.opacity(0.35) : Color.clear))
            .onHover { hovered = $0 }
    }
    private var incrementButton: some View {
        Button { increment() } label: {
            Image(systemName: "plus").font(.callout.weight(.semibold)).frame(width: artworkCard ? 20 : 28, height: artworkCard ? 20 : 28)
        }.buttonStyle(.bordered).buttonBorderShape(.circle)
            .help(media.type == .manga ? "Add one chapter" : "Add one episode")
            .accessibilityLabel(media.type == .manga ? "Add one chapter to \(media.name)" : "Add one episode to \(media.name)")
            .disabled(busy || runtime.viewer == nil || (media.length.map { (current.mediaListEntry?.progress ?? 0) >= $0 } ?? false))
    }
    private var editButton: some View {
        Button("Edit") { showEditor = true }.buttonStyle(.borderless).font(.caption).disabled(busy)
            .accessibilityLabel("Edit \(media.name)")
    }
    private var progressLabel: String {
        let unit = media.type == .manga ? "chapters" : "episodes"
        let total = media.length.map { " / \($0)" } ?? ""
        let volume = media.type == .manga ? " · \(current.mediaListEntry?.progressVolumes ?? 0) volumes" : ""
        return "\(current.mediaListEntry?.progress ?? 0)\(total) \(unit)\(volume)"
    }
    private func increment() {
        guard !busy else { return }
        busy = true; onBusyChange(true); error = nil
        Task {
            defer { busy = false; onBusyChange(false) }
            do {
                let saved = try await runtime.repository.incrementProgress(mediaID: current.id, entryID: current.mediaListEntry?.id, progress: (current.mediaListEntry?.progress ?? 0) + 1)
                guard !runtime.stopped else { return }
                var updated = current; updated.mediaListEntry = saved; edited = updated; onSaved(updated)
                runtime.didMutate()
            } catch {
                runtime.handle(error)
                if !(error is CancellationError) { self.error = (error as? MLError)?.localizedDescription ?? MLError.rejected.localizedDescription }
            }
        }
    }
}

struct MLListEditor: View {
    @Environment(MLRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    let media: MLMedia
    let saved: (MLMedia) -> Void
    @State private var draft: MLListDraft
    @State private var busy = false
    @State private var error: String?
    @State private var deleting = false
    @State private var savedScore: Double?
    @State private var scoreRequest = MLReadRequest()
    @State private var scoreError = false
    @State private var scoreStale: Date?
    @State private var scorePartial = false
    @State private var reads = MLReadActions()
    init(media: MLMedia, saved: @escaping (MLMedia) -> Void) {
        self.media = media; self.saved = saved; _draft = State(initialValue: MLListDraft(media: media))
    }
    private var type: MLMediaType { media.type ?? .anime }
    private var scoreFormat: MLScoreFormat { MLScoreFormat(rawValue: runtime.viewer?.mediaListOptions?.scoreFormat ?? "") ?? .hundred }
    private var advancedDimensions: [String] {
        let options = type == .anime ? runtime.viewer?.mediaListOptions?.animeList : runtime.viewer?.mediaListOptions?.mangaList
        return options?.advancedScoringEnabled == true ? options?.advancedScoring ?? [] : []
    }
    private var scoreBinding: Binding<Double> {
        Binding(get: { min(scoreFormat.maximum, max(0, draft.displayedScore ?? savedScore ?? 0)) }, set: { draft.displayedScore = $0 })
    }
    private var customLists: [String] {
        Array(Set(((type == .anime ? runtime.viewer?.mediaListOptions?.animeList : runtime.viewer?.mediaListOptions?.mangaList)?.customLists ?? []) + draft.customLists)).sorted()
    }
    @Environment(\.mlPalette) private var palette
    @FocusState private var focusedField: String?
    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusSection
                    HStack(alignment: .top, spacing: 14) {
                        progressSection
                        scoreSection
                    }
                    datesSection
                    additionalSection
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(24)
            }.scrollBounceBehavior(.basedOnSize).disabled(busy)
            editorFooter
        }
        .frame(width: 640, height: 720)
        .background(palette.background).tint(palette.accent)
        .mlTask(id: "entry-score/\(draft.entryID ?? 0)") { if savedScore == nil { await loadScore(replacing: true) } }
        .mlReadActions(reads, id: "\(draft.entryID ?? 0)")
        .confirmationDialog("Remove \(media.name) from your AniList list?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Remove from list", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        }
    }
    private var editorHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            MLArtwork(url: media.coverImage?.large ?? media.coverImage?.medium, width: 50, height: 74, radius: 10)
            VStack(alignment: .leading, spacing: 7) {
                Text(draft.entryID == nil ? "ADD TO YOUR LIST" : "EDIT LIST ENTRY")
                    .font(.caption2.weight(.semibold)).tracking(1.3).foregroundStyle(palette.accent)
                Text(media.name).font(.title3.weight(.semibold)).lineLimit(3).help(media.name)
                Text(media.summary).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.callout.weight(.semibold)).frame(width: 28, height: 28)
            }.buttonStyle(.bordered).buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction).disabled(busy).help("Cancel")
                .accessibilityLabel("Cancel editing")
        }.padding(24)
            .background(LinearGradient(colors: [palette.accent.opacity(0.10), palette.surface.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Status", symbol: "bookmark")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(MLListStatus.allCases) { status in
                    Button { draft.status = status } label: {
                        HStack(spacing: 7) {
                            Image(systemName: statusSymbol(status)).font(.caption)
                            Text(status.title(for: type)).font(.callout.weight(draft.status == status ? .semibold : .regular))
                            Spacer(minLength: 0)
                            if draft.status == status { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                        }.padding(.horizontal, 12).frame(height: 36)
                            .foregroundStyle(draft.status == status ? palette.accent : Color.primary.opacity(0.8))
                            .background(draft.status == status ? palette.accent.opacity(0.15) : palette.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(draft.status == status ? palette.accent.opacity(0.45) : Color.primary.opacity(0.06)))
                    }.buttonStyle(.plain).accessibilityAddTraits(draft.status == status ? .isSelected : [])
                }
            }
        }
    }
    private func statusSymbol(_ status: MLListStatus) -> String {
        switch status {
        case .current: type == .anime ? "play.fill" : "book.fill"
        case .planning: "bookmark"
        case .completed: "checkmark.circle"
        case .paused: "pause"
        case .dropped: "minus.circle"
        case .repeating: "repeat"
        }
    }
    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.callout.weight(.semibold))
    }
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Progress", symbol: type == .anime ? "play.rectangle" : "books.vertical")
            countControl(type == .anime ? "Episodes" : "Chapters", value: $draft.progress,
                         maximum: max(media.length ?? 100000, draft.progress))
            if let total = media.length, total > 0 {
                ProgressView(value: Double(min(draft.progress, total)), total: Double(total))
                    .accessibilityLabel("Tracking progress")
                Text("of \(total) \(type == .anime ? "episodes" : "chapters")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if type == .manga {
                Text("Volumes").font(.caption).foregroundStyle(.secondary)
                countControl("Volumes", value: $draft.volumes, maximum: max(media.volumes ?? 100000, draft.volumes))
            }
        }.frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading).padding(16).modifier(MLPanel())
    }
    private var scoreSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("Your score", symbol: "star")
                Spacer()
                if draft.entryID == nil || savedScore != nil {
                    Text(scoreFormat.label(scoreBinding.wrappedValue)).font(.callout.weight(.semibold)).monospacedDigit()
                }
            }
            if draft.entryID != nil && savedScore == nil {
                if scoreError {
                    Text("Saved score unavailable").font(.callout).foregroundStyle(.secondary)
                    Button("Retry") { reads.run { await loadScore() } }.buttonStyle(.bordered)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading saved score…").font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 32)
                }
                Text("Your saved score stays unchanged until you edit it.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Slider(value: scoreBinding, in: 0...scoreFormat.maximum, step: scoreFormat.step)
                    .accessibilityLabel("Overall score")
                HStack {
                    Text(scoreFormat.title).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { scoreBinding.wrappedValue = 0 }.buttonStyle(.borderless).font(.caption)
                        .disabled(scoreBinding.wrappedValue == 0).accessibilityLabel("Clear your score")
                }
            }
            MLStaleBanner(date: scoreStale, partial: scorePartial)
        }.frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading).padding(16).modifier(MLPanel())
    }
    private func countControl(_ title: String, value: Binding<Int>, maximum: Int) -> some View {
        HStack(spacing: 8) {
            Button { value.wrappedValue = max(0, value.wrappedValue - 1) } label: {
                Image(systemName: "minus").frame(width: 22, height: 24)
            }.disabled(value.wrappedValue <= 0).accessibilityLabel("Decrease \(title.lowercased())")
            TextField(title, value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(maximum, max(0, $0)) }), format: .number.grouping(.never))
                .textFieldStyle(.plain).multilineTextAlignment(.center).font(.title3.weight(.semibold)).monospacedDigit()
                .focused($focusedField, equals: title).accessibilityLabel(title)
                .frame(minWidth: 44, maxWidth: .infinity)
            Button { value.wrappedValue = min(maximum, value.wrappedValue + 1) } label: {
                Image(systemName: "plus").frame(width: 22, height: 24)
            }.disabled(value.wrappedValue >= maximum).accessibilityLabel("Increase \(title.lowercased())")
        }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 8))
    }
    private var datesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Dates", symbol: "calendar")
            HStack(alignment: .top, spacing: 20) {
                MLFuzzyDateFields(title: "Started", date: $draft.start)
                Spacer(minLength: 0)
                MLFuzzyDateFields(title: "Finished", date: $draft.finish)
            }
            Text("Unknown dates can stay blank. Changing a date won’t change your status.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).modifier(MLPanel())
    }
    private var additionalSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Repeat count").font(.caption).foregroundStyle(.secondary)
                            countControl("Repeat count", value: $draft.repeats, maximum: 1000)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Priority").font(.caption).foregroundStyle(.secondary)
                            countControl("Priority", value: $draft.priority, maximum: 255)
                        }
                    }
                    Text("Notes").font(.callout.weight(.semibold))
                    TextEditor(text: $draft.notes).font(.body).scrollContentBackground(.hidden)
                        .frame(minHeight: 80).padding(8).background(palette.background, in: .rect(cornerRadius: 8))
                        .accessibilityLabel("List notes")
                    Toggle("Private entry", isOn: $draft.isPrivate)
                    Toggle("Hide from status lists", isOn: $draft.hiddenFromStatusLists)
                    if !customLists.isEmpty {
                        Divider()
                        Text("Custom lists").font(.callout.weight(.semibold))
                        ForEach(customLists, id: \.self) { name in
                            Toggle(name, isOn: Binding(get: { draft.customLists.contains(name) }, set: { selected in
                                if selected { draft.customLists.append(name) } else { draft.customLists.removeAll { $0 == name } }
                            }))
                        }
                    }
                }.padding(.top, 14)
            } label: { sectionTitle("More options", symbol: "slider.horizontal.3") }
            if !advancedDimensions.isEmpty {
                DisclosureGroup("Advanced scoring") {
                    Text("Uses AniList’s 100-point scale. Your overall score is set separately.").font(.caption).foregroundStyle(.secondary)
                    ForEach(advancedDimensions, id: \.self) { name in
                        HStack {
                            Text(name).lineLimit(2).frame(width: 100, alignment: .leading)
                            Slider(value: Binding(get: { draft.advancedScores[name] ?? 0 }, set: { value in
                                draft.advancedScores[name] = value
                                draft.editedAdvancedScores = advancedDimensions.map { draft.advancedScores[$0] ?? 0 }
                            }), in: 0...100, step: 1).accessibilityLabel("\(name) score")
                            Text("\(Int(draft.advancedScores[name] ?? 0))/100").monospacedDigit().frame(width: 64)
                        }
                    }
                }
            }
        }.padding(16).modifier(MLPanel())
    }
    private var editorFooter: some View {
        HStack(spacing: 12) {
            if draft.entryID != nil {
                Button(role: .destructive) { deleting = true } label: { Label("Remove entry", systemImage: "trash") }
                    .buttonStyle(.borderless).disabled(busy)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }.buttonStyle(.bordered).disabled(busy)
            Button { focusedField = nil; submit() } label: { Label("Save changes", systemImage: "checkmark") }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(busy || runtime.viewer == nil)
        }.controlSize(.large).padding(.horizontal, 24).padding(.vertical, 18)
            .background(palette.surface).overlay(alignment: .top) { Divider().opacity(0.5) }
    }
    private func loadScore(replacing: Bool = false) async {
        guard let id = draft.entryID, let lease = scoreRequest.begin(replacing: replacing) else { return }
        scoreError = false
        defer { scoreRequest.finish(lease) }
        do {
            let result = try await runtime.repository.entryScore(id)
            try Task.checkCancellation()
            guard scoreRequest.owns(lease) else { return }
            guard (0...scoreFormat.maximum).contains(result.value) else { throw MLError.invalidResponse }
            savedScore = result.value; scoreStale = result.cachedAt; scorePartial = result.isPartial
        } catch { if scoreRequest.owns(lease), !Task.isCancelled, !(error is CancellationError) { runtime.handle(error); scoreError = true } }
    }
    private func submit() {
        guard !busy else { return }
        guard draft.start.isValid, draft.finish.isValid else { error = "Please use a valid date, or leave unknown fields blank."; return }
        guard draft.notes.count <= 6000 else { error = "AniList notes can contain up to 6,000 characters."; return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let entry = try await runtime.repository.saveList(draft)
                guard !runtime.stopped else { return }
                var updated = media; updated.mediaListEntry = entry
                saved(updated); runtime.didMutate(); dismiss()
            } catch { runtime.handle(error); if !(error is CancellationError) { self.error = (error as? MLError)?.localizedDescription ?? MLError.rejected.localizedDescription } }
        }
    }
    private func remove() {
        guard let id = draft.entryID, !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try await runtime.repository.deleteList(id)
                guard !runtime.stopped else { return }
                var updated = media; updated.mediaListEntry = nil
                saved(updated); runtime.didMutate(); dismiss()
            } catch { runtime.handle(error); self.error = (error as? MLError)?.localizedDescription ?? MLError.rejected.localizedDescription }
        }
    }
}
struct MLFuzzyDateFields: View {
    let title: String
    @Binding var date: MLFuzzyDate
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold))
            HStack(alignment: .bottom, spacing: 10) {
                field("Year", value: $date.year, width: 72)
                field("Month", value: $date.month, width: 50)
                field("Day", value: $date.day, width: 50)
                Button("Clear", systemImage: "xmark.circle") { date = MLFuzzyDate() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).frame(height: 24)
                    .accessibilityLabel("Clear \(title.lowercased()) date").help("Clear \(title.lowercased()) date")
            }
        }.textFieldStyle(.roundedBorder)
    }
    private func field(_ label: String, value: Binding<Int?>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.grouping(.never)).labelsHidden()
                .accessibilityLabel("\(title) \(label.lowercased())")
        }.frame(width: width)
    }
}
