import SwiftUI

/// A single sheet owns its confirmation state; no nested alert/window is created.
struct TanDetailsView: View {
    @Environment(TanManager.self) private var tans
    @Environment(\.dismiss) private var dismiss
    let package: TanPackage
    let reload: (String) -> Void
    @State private var confirming = false
    @State private var removing = false
    @State private var error: String?
    @State private var translationReport: TanTranslationReport?
    @State private var reportUnavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(package.manifest.name).font(.title2.bold())
            if confirming {
                Text("Uninstall this Tan?").font(.headline)
                Text("This removes the installed copy and its saved source, and turns it off. Keep your original source folder to import it again. Changes that need a reload are shown on Home.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { confirming = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Uninstall Tan", role: .destructive) { uninstall() }.disabled(removing)
                }
            } else {
                Text(package.manifest.description).foregroundStyle(.secondary)
                LabeledContent("Version", value: package.manifest.version)
                LabeledContent("By", value: package.manifest.authors.joined(separator: ", "))
                LabeledContent("Source", value: package.origin == "Noko Original" ? "Noko-Tan" : package.origin)
                if let report = translationReport {
                    DisclosureGroup("Translation details") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Compatibility", value: report.classification)
                            Text("Preserved source files: \(report.files.count) · License files: \(report.licenses.count)")
                            if !(report.adaptations ?? []).isEmpty {
                                Text("Startup was explicitly adapted to run when the document is ready. Test the Tan’s behavior before relying on it.")
                            }
                        }.font(.callout).foregroundStyle(.secondary).padding(.top, 6)
                    }
                } else if reportUnavailable {
                    Text("The saved translation report could not be read.").font(.caption).foregroundStyle(.secondary)
                }
                if tans.availableOriginalUpdate(package) != nil {
                    Button("Update Noko-Tan") {
                        do { try tans.updateOriginal(package.id); dismiss() }
                        catch { self.error = "The update could not be installed." }
                    }
                    Text("Updating turns this Tan off. Enable it again when you’re ready.").font(.caption).foregroundStyle(.secondary)
                }
                if tans.developerMode {
                    Text("SHA-256").font(.caption.bold())
                    Text(package.contentHash).font(.caption.monospaced()).textSelection(.enabled)
                    LabeledContent("Runtime", value: package.manifest.target.rawValue)
                    Button("Reload from folder…") { dismiss(); reload(package.id) }
                    LabeledContent("Capabilities", value: package.manifest.capabilities.isEmpty ? "None" : package.manifest.capabilities.map(\.rawValue).joined(separator: ", "))
                }
                HStack {
                    Button("Uninstall…", role: .destructive) { guard !confirming else { return }; error = nil; confirming = true }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }.padding(28).frame(width: 440)
            .task(id: package.id) {
                do {
                    let report = try await tans.translationReport(for: package.id)
                    guard !Task.isCancelled else { return }
                    translationReport = report
                } catch { if !Task.isCancelled { reportUnavailable = true } }
            }
            .onChange(of: tans.installed.map(\.id)) { _, ids in
                if !ids.contains(package.id) { dismiss() }
            }
    }

    private func uninstall() {
        guard confirming, !removing else { return }
        removing = true
        do { try tans.uninstall(package.id); dismiss() }
        catch { self.error = "This Tan could not be removed. Please try again."; confirming = false; removing = false }
    }
}
