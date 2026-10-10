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
                Button { runtime.routes.append(.media(media.id)) } label: {
                    MLArtwork(url: media.coverImage?.medium ?? media.coverImage?.large, width: compact ? 52 : 48, height: compact ? 78 : 72, radius: 8)
                }.buttonStyle(.plain).accessibilityLabel("Open \(media.name)")
                VStack(alignment: .leading, spacing: 7) {
                    Button(media.name) { runtime.routes.append(.media(media.id)) }
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
    private var scoreLoading: Bool { scoreRequest.loading }
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
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(media.name).font(.title3.bold()).lineLimit(2); Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy) }.padding(20)
            Form {
                Section("Your list entry") {
                    Picker("Status", selection: $draft.status) { ForEach(MLListStatus.allCases) { Text($0.title(for: type)).tag($0) } }
                    Stepper("\(type == .anime ? "Episodes" : "Chapters"): \(draft.progress)\(media.length.map { " / \($0)" } ?? "")", value: $draft.progress, in: 0...max(media.length ?? 100000, draft.progress))
                    if type == .manga { Stepper("Volumes: \(draft.volumes)", value: $draft.volumes, in: 0...max(media.volumes ?? 100000, draft.volumes)) }
                    HStack {
                        Text("Score")
                        if draft.entryID != nil && savedScore == nil {
                            Spacer()
                            if scoreLoading { ProgressView().controlSize(.small); Text("Loading saved score…").font(.caption) }
                            else if scoreError { Text("Saved score unavailable").font(.caption).foregroundStyle(.secondary); Button("Retry") { reads.run { await loadScore() } } }
                        } else {
                            Slider(value: scoreBinding, in: 0...scoreFormat.maximum, step: scoreFormat.step).accessibilityLabel("Overall score")
                            Text(scoreFormat.label(scoreBinding.wrappedValue)).monospacedDigit().frame(minWidth: 64)
                        }
                    }
                    MLStaleBanner(date: scoreStale, partial: scorePartial)
                    if scoreError { Text("You can edit the other fields. Your score stays unchanged unless you edit it.").font(.caption).foregroundStyle(.secondary) }
                    if !advancedDimensions.isEmpty {
                        DisclosureGroup("Advanced scoring") {
                            Text("Scores use AniList’s 100-point scale. Changing a dimension keeps the other dimension values; MaoList does not calculate your overall score.").font(.caption).foregroundStyle(.secondary)
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
                    Stepper("Repeat count: \(draft.repeats)", value: $draft.repeats, in: 0...1000)
                    Stepper("Priority: \(draft.priority)", value: $draft.priority, in: 0...255)
                }
                Section("Dates") {
                    VStack(alignment: .leading, spacing: 16) {
                        MLFuzzyDateFields(title: "Started", date: $draft.start)
                        MLFuzzyDateFields(title: "Finished", date: $draft.finish)
                        Text("Leave fields blank for unknown dates. Dates do not change your status automatically.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 4).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading)
                }
                Section("Notes and privacy") {
                    TextEditor(text: $draft.notes).frame(minHeight: 70).accessibilityLabel("List notes")
                    Toggle("Private entry", isOn: $draft.isPrivate)
                    Toggle("Hide from status lists", isOn: $draft.hiddenFromStatusLists)
                }
                if !customLists.isEmpty {
                    Section("Custom lists") {
                        ForEach(customLists, id: \.self) { name in
                            Toggle(name, isOn: Binding(get: { draft.customLists.contains(name) }, set: { selected in
                                if selected { draft.customLists.append(name) } else { draft.customLists.removeAll { $0 == name } }
                            }))
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.orange) }
            }.formStyle(.grouped).disabled(busy)
            HStack {
                if draft.entryID != nil { Button("Remove from list…", role: .destructive) { deleting = true }.disabled(busy) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Save to AniList") { submit() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(busy || runtime.viewer == nil)
            }.padding(20)
        }.frame(width: 580, height: 670)
            .mlTask(id: "entry-score/\(draft.entryID ?? 0)") { if savedScore == nil { await loadScore(replacing: true) } }
            .mlReadActions(reads, id: "\(draft.entryID ?? 0)")
            .confirmationDialog("Remove \(media.name) from your AniList list?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Remove from list", role: .destructive) { remove() }
                Button("Cancel", role: .cancel) {}
            }
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
                field("Year", value: $date.year, width: 88)
                field("Month", value: $date.month, width: 64)
                field("Day", value: $date.day, width: 64)
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
