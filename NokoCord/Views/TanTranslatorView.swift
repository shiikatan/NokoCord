import SwiftUI
import AppKit

struct TanTranslatorView: View {
    @Environment(TanManager.self) private var tans
    @Environment(\.dismiss) private var dismiss
    @State private var windowReference = PresentationWindowReference()
    @State private var source: [String: String] = [:]
    @State private var result: TanTranslationResult?
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    @State private var sourcePanel: NSOpenPanel?
    @State private var repository: URL?
    @State private var repositoryAccess = false
    @State private var plugins: [String] = []
    @State private var selectedPlugin = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tan Translator").font(.title2.bold())
                    Text("Bring a source folder. See what fits.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("Choose a Vencord plugin folder or source repository to check compatibility and create a Tan. Your original files stay unchanged.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(result == nil ? "Choose source folder…" : "Choose another folder…") { chooseSource() }
                    .disabled(busy || sourcePanel != nil)
                Button("Choose repository…") { chooseSource(repositoryMode: true) }.disabled(busy || sourcePanel != nil)
                if busy { ProgressView().controlSize(.small); Text("Translating…").foregroundStyle(.secondary) }
            }
            if repository != nil {
                HStack {
                    Picker("Plugin", selection: $selectedPlugin) {
                        ForEach(plugins, id: \.self) { Text($0).tag($0) }
                    }.disabled(busy || sourcePanel != nil)
                    .onChange(of: selectedPlugin) { _, _ in result = nil; source = [:]; error = nil }
                    Button("Translate") { translateRepository() }.disabled(busy || sourcePanel != nil || selectedPlugin.isEmpty)
                }
            }
            if let result {
                Divider()
                HStack {
                    Text(result.report.classification).font(.headline)
                    Spacer()
                    if result.report.installable { Label("Ready to review", systemImage: "checkmark.circle").foregroundStyle(.green) }
                }
                if let package = try? result.package() {
                    Text(package.manifest.name).font(.title3.bold())
                    Text(package.manifest.description).foregroundStyle(.secondary)
                    Text("By " + package.manifest.authors.joined(separator: ", ")).font(.caption)
                }
                Text("\(result.report.files.count) source files · \(result.report.licenses.count) license files preserved").font(.caption).foregroundStyle(.secondary)
                if !result.report.findings.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(result.report.findings.enumerated()), id: \.offset) { _, finding in
                                Label(finding.code.replacingOccurrences(of: "-", with: " ").capitalized, systemImage: "info.circle")
                                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(maxHeight: 150)
                }
                if result.report.findings.count == 1, result.report.findings.first?.code == "lifecycle-timing-needs-review" {
                    Text("This plugin normally waits for Discord’s modules. You can instead start it when the document is ready. Features that depend on module timing may behave differently.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Convert with document-ready startup") { adaptTiming() }.disabled(busy)
                }
                ForEach(result.report.adaptations ?? [], id: \.self) { adaptation in
                    Text(adaptation).font(.callout).foregroundStyle(.secondary)
                }
                Text(result.report.installable ? "Review code you trust before enabling it. Installation preserves the source and report, and leaves the Tan turned off." : "No installable Tan was created. Required behavior needs an adapter or source changes; it has not been silently removed.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Button(busy ? "Cancel translation" : "Close") {
                    task?.cancel()
                    if !busy { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Spacer()
                if let result, result.report.installable {
                    Button("Install Tan") {
                        do { try tans.installTranslation(result, source: source); dismiss() }
                        catch { self.error = "The translated Tan could not be installed. Your source files are unchanged." }
                    }.buttonStyle(.borderedProminent).disabled(busy)
                }
            }
        }.padding(28).frame(width: 540)
            .interactiveDismissDisabled(busy)
            .background(WindowLifetimeObserver(reference: windowReference) { sourcePanel?.cancel(nil); sourcePanel = nil; task?.cancel() }.frame(width: 0, height: 0))
            .onDisappear { sourcePanel?.cancel(nil); sourcePanel = nil; task?.cancel(); task = nil; source = [:]; result = nil; releaseRepository() }
    }
    private func chooseSource(repositoryMode: Bool = false) {
        guard sourcePanel == nil, let owner = windowReference.window else { return }
        let panel = NSOpenPanel()
        sourcePanel = panel
        panel.title = "Translate Tan"
        panel.message = repositoryMode ? "Choose the source repository containing src/plugins and LICENSE." : "Choose the plugin folder containing its index file and license."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        // The translator is already a sheet. Keep the picker modeless and
        // explicitly cancel it with that sheet's lifetime instead of nesting sheets.
        panel.begin { [weak owner] response in
            panel.orderOut(nil)
            owner?.makeKeyAndOrderFront(nil)
            sourcePanel = nil
            guard response == .OK, let url = panel.url else { return }
            releaseRepository()
            let access = url.startAccessingSecurityScopedResource()
            if repositoryMode {
                busy = true; result = nil; source = [:]; error = nil
                task = Task { @MainActor in
                    var retainedAccess = false
                    defer {
                        if access && !retainedAccess { url.stopAccessingSecurityScopedResource() }
                        busy = false; task = nil
                    }
                    do {
                        let names = try await Task.detached(priority: .userInitiated) {
                            try TanTranslationService.repositoryPlugins(url)
                        }.value
                        try Task.checkCancellation()
                        plugins = names; selectedPlugin = names.first ?? ""
                        repository = url; repositoryAccess = access; retainedAccess = true
                    } catch is CancellationError { self.error = nil }
                    catch { self.error = "Choose a repository containing src/plugins with plugin folders." }
                }
                return
            }
            busy = true; error = nil; result = nil; source = [:]
            task = Task { @MainActor in
                defer { if access { url.stopAccessingSecurityScopedResource() }; busy = false; task = nil }
                do {
                    let files = try await Task.detached(priority: .userInitiated) { try TanTranslationService.readSource(url) }.value
                    try Task.checkCancellation()
                    let converted = try await TanTranslationService.translate(files: files)
                    try Task.checkCancellation()
                    source = files; result = converted
                } catch is CancellationError { self.error = nil }
                catch let failure as TanTranslationError { self.error = failure.errorDescription }
                catch { self.error = TanTranslationError.invalidSource.errorDescription }
            }
        }
    }
    private func adaptTiming() {
        guard !busy, !source.isEmpty else { return }
        let files = source
        busy = true; error = nil
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            do {
                let converted = try await TanTranslationService.translate(files: files, useDocumentReadyTiming: true)
                try Task.checkCancellation()
                result = converted
            } catch is CancellationError { self.error = nil }
            catch { self.error = TanTranslationError.failed.errorDescription }
        }
    }
    private func releaseRepository() {
        if repositoryAccess { repository?.stopAccessingSecurityScopedResource() }
        repository = nil; repositoryAccess = false; plugins = []; selectedPlugin = ""
    }
    private func translateRepository() {
        guard let repository, !busy else { return }
        let plugin = selectedPlugin
        // Hold a separate grant for this task, even if its view disappears.
        let access = repository.startAccessingSecurityScopedResource()
        busy = true; error = nil; result = nil; source = [:]
        task = Task { @MainActor in
            defer { if access { repository.stopAccessingSecurityScopedResource() }; busy = false; task = nil }
            do {
                let files = try await Task.detached(priority: .userInitiated) {
                    try TanTranslationService.readRepositorySource(repository, plugin: plugin)
                }.value
                try Task.checkCancellation()
                let converted = try await TanTranslationService.translate(files: files)
                try Task.checkCancellation()
                source = files; result = converted
            } catch is CancellationError { self.error = nil }
            catch let failure as TanTranslationError { self.error = failure.errorDescription }
            catch { self.error = TanTranslationError.invalidSource.errorDescription }
        }
    }

}
