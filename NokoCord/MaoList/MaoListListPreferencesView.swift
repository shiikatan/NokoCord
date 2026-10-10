import SwiftUI

struct MLListPreferencesView: View {
    @Environment(MLRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    @State private var type: MLMediaType
    @State private var draft = MLListPreferencesDraft(MLListOptions())
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirmChanges = false
    @State private var reads = MLReadActions()
    @State private var loadRequest = MLReadRequest()
    init(type: MLMediaType = .anime) { _type = State(initialValue: type) }
    private var options: Binding<MLTypeListOptions> {
        Binding(get: { type == .anime ? draft.anime : draft.manga }, set: { if type == .anime { draft.anime = $0 } else { draft.manga = $0 } })
    }
    private var customNames: Binding<[String]> {
        Binding(get: { options.wrappedValue.customLists ?? [] }, set: { options.wrappedValue.customLists = $0 })
    }
    private var dimensions: Binding<[String]> {
        Binding(get: { options.wrappedValue.advancedScoring ?? [] }, set: { options.wrappedValue.advancedScoring = $0 })
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("List preferences").font(.title3.bold())
                Spacer()
                Button("Cancel") { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction)
            }.padding(20)
            Form {
                Section("Scoring") {
                    Picker("Overall score format", selection: $draft.scoreFormat) { ForEach(MLScoreFormat.allCases) { Text($0.title).tag($0) } }
                    Text("Applies to both anime and manga on your AniList account.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("List", selection: $type) { ForEach(MLMediaType.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                }
                Section("Custom lists") {
                    MLPreferenceNames(names: customNames, noun: "list")
                    Text("Add and reorder your custom lists. Renaming or removing an existing list removes its membership; anime and manga stay in your library. Changes apply when you save.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Advanced scoring") {
                    Toggle("Enable advanced scoring", isOn: Binding(get: { options.wrappedValue.advancedScoringEnabled ?? false }, set: { options.wrappedValue.advancedScoringEnabled = $0 }))
                    MLPreferenceNames(names: dimensions, noun: "dimension")
                    Text("Configure dimension names in their scoring order. Changing these names or their order can affect scores already stored on AniList. MaoList does not migrate old dimension scores.").font(.caption).foregroundStyle(.secondary)
                }
                Section("List display") {
                    Toggle("Separate completed entries by format", isOn: Binding(get: { options.wrappedValue.splitCompletedSectionByFormat ?? false }, set: { options.wrappedValue.splitCompletedSectionByFormat = $0 }))
                }
            }.formStyle(.grouped).textFieldStyle(.roundedBorder).disabled(!loaded || busy)
            if let error { Text(error).font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20) }
            HStack {
                if !loaded { Button("Retry") { reads.run { await load() } }.disabled(busy) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Save to AniList") { prepareSave() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!loaded || busy || !draft.changed || runtime.viewer == nil)
            }.padding(20)
        }.frame(width: 580, height: 670).modifier(MLAppearance())
            .mlTask(id: "preferences/\(runtime.viewer?.id ?? 0)") { if !loaded { await load(replacing: true) } }
            .mlReadActions(reads, id: "\(runtime.viewer?.id ?? 0)")
            .alert("Apply list changes?", isPresented: $confirmChanges) {
                Button("Cancel", role: .cancel) {}
                Button("Apply changes", role: .destructive) { Task { await save() } }
            } message: {
                Text("Removed or renamed custom lists lose their membership, but entries remain in your AniList library. Changes to scoring dimensions may affect existing dimension scores. Save may apply several operations; a failed later operation cannot undo a completed removal.")
            }
    }
    private func load(replacing: Bool = false) async {
        guard !busy || replacing, let accountID = runtime.viewer?.id,
              let lease = loadRequest.begin(replacing: replacing) else { return }
        busy = true; error = nil
        defer { if loadRequest.owns(lease) { busy = false }; loadRequest.finish(lease) }
        do {
            let result = try await runtime.repository.viewer(refresh: true)
            try Task.checkCancellation()
            guard loadRequest.owns(lease) else { return }
            guard !runtime.stopped, result.value.Viewer?.id == accountID,
                  !result.isStale, let options = result.value.Viewer?.mediaListOptions else {
                error = "Connect to AniList to load current preferences before editing."; return
            }
            draft = MLListPreferencesDraft(options); loaded = true
        } catch { if loadRequest.owns(lease), !Task.isCancelled, !(error is CancellationError) { runtime.handle(error); self.error = (error as? MLError)?.localizedDescription ?? MLError.offline.localizedDescription } }
    }
    private func prepareSave() {
        do { _ = try draft.variables() }
        catch { self.error = "Use unique, nonempty names for custom lists and scoring dimensions."; return }
        if draft.scoringChanged || MLMediaType.allCases.contains(where: { !draft.removals(for: $0).isEmpty }) { confirmChanges = true }
        else { Task { await save() } }
    }
    private func save() async {
        guard !busy, let accountID = runtime.viewer?.id else { return }
        busy = true; error = nil
        defer { busy = false }
        var removedAny = false
        do {
            for type in MLMediaType.allCases {
                for name in draft.removals(for: type) {
                    try await runtime.repository.deleteCustomList(name, type: type)
                    guard !runtime.stopped, runtime.viewer?.id == accountID else { throw CancellationError() }
                    draft.acknowledgeRemoval(name, type: type)
                    removedAny = true; runtime.didMutate()
                }
            }
            let user: MLUser
            if try draft.variables().isEmpty {
                let result = try await runtime.repository.viewer(refresh: true)
                guard !result.isStale, let current = result.value.Viewer else { throw MLError.unavailable }
                user = current
            } else { user = try await runtime.repository.saveListPreferences(draft) }
            guard !runtime.stopped, user.id == accountID else { throw CancellationError() }
            runtime.applyListPreferences(user); dismiss()
        } catch {
            runtime.handle(error)
            if !(error is CancellationError) {
                self.error = removedAny ? "Some custom-list removals were applied. Your remaining changes are kept here; retry Save to finish." : (error as? MLError)?.localizedDescription ?? MLError.rejected.localizedDescription
            }
        }
    }
}

private struct MLPreferenceNames: View {
    @Binding var names: [String]
    let noun: String
    var body: some View {
        ForEach(names.indices, id: \.self) { index in
            HStack {
                TextField("New \(noun) name", text: $names[index]).accessibilityLabel("\(noun.capitalized) \(index + 1) name")
                Button { names.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).accessibilityLabel("Move \(noun) \(index + 1) up")
                Button { names.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }.disabled(index == names.count - 1).accessibilityLabel("Move \(noun) \(index + 1) down")
                Button { names.remove(at: index) } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove \(noun) \(index + 1) from draft")
            }.buttonStyle(.borderless)
        }
        Button("Add \(noun)", systemImage: "plus") { names.append("") }
    }
}
