import SwiftUI
import AppKit

/// Apple-like Liquid Glass Inspector for discovering, toggling, and managing Tans directly inside Discord.
struct TansInspectorView: View {
    @Environment(TanManager.self) private var tans
    @Environment(ActiveBrowserEngine.self) private var browser
    @Binding var isPresented: Bool

    @State private var windowReference = PresentationWindowReference()
    @State private var search = ""
    @State private var hoveredTanID: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("hideNokoTans") private var hideNokoTans = false
    @State private var filterSelection = "All"
    @State private var pendingEnable: TanPackage?
    @State private var presentation: TanPresentation?
    @State private var importError: String?
    @State private var filePanel: NSOpenPanel?
    @State private var pendingReloadID: String?

    private func matches(_ package: TanPackage) -> Bool {
        search.isEmpty || (package.manifest.name + " " + package.manifest.description + " " + package.manifest.authors.joined(separator: " ")).localizedStandardContains(search)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    searchBar

                    if tans.safeMode || tans.reloadRequired {
                        statusBanner
                    }

                    installedSection

                    originalsSection

                    Divider().padding(.vertical, 4)

                    developerSection
                }
                .padding(16)
            }
        }
        .frame(width: 380)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundStyle(Color.primary.opacity(0.1)),
            alignment: .leading
        )
        .confirmationDialog(
            "Enable \(pendingEnable?.manifest.name ?? "Tan")?",
            isPresented: Binding(get: { pendingEnable != nil }, set: { if !$0 { pendingEnable = nil } }),
            titleVisibility: .visible
        ) {
            if let package = pendingEnable {
                Button("Enable Tan") {
                    withAnimation(.nokoFluidSpring) {
                        tans.setEnabled(package.id, true)
                        pendingEnable = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingEnable = nil }
        } message: {
            Text(
                (pendingEnable?.manifest.target == .css
                    ? "This Tan changes the appearance of Discord. Enable only Tans you trust."
                    : "This Tan runs code inside Discord and can interact with content in your session. Enable only code you trust.")
                + (pendingEnable?.manifest.capabilities.contains(.appearanceRead) == true ? " It can also read your app appearance setting." : "")
            )
        }
        .alert("Tan could not be updated", isPresented: Binding(get: { importError != nil || tans.error != nil }, set: { if !$0 { importError = nil; tans.dismissError() } })) {
            Button("OK") { importError = nil; tans.dismissError() }
        } message: {
            Text(importError ?? tans.error ?? "Please try again.")
        }
        .sheet(item: $presentation, onDismiss: {
            if let id = pendingReloadID { pendingReloadID = nil; importTan(replacing: id) }
        }) { route in
            switch route {
            case .translator:
                TanTranslatorView()
            case .details(let package):
                TanDetailsView(package: package) { id in
                    pendingReloadID = id
                    presentation = nil
                }
            }
        }
        .background(
            WindowLifetimeObserver(reference: windowReference) {
                pendingReloadID = nil
                filePanel?.cancel(nil)
                filePanel = nil
                presentation = nil
                pendingEnable = nil
                importError = nil
            }.frame(width: 0, height: 0)
        )
        .nokoCordAppearance()
    }

    // MARK: - Header
    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 28, height: 28)
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.tint)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Tans")
                    .font(.headline.weight(.semibold))
                Text("\(tans.active.count) Active · \(tans.installed.count) Total")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Button {
                    presentation = .translator
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Translate Vencord Plugin…")
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

                Button {
                    importTan()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Import Local Tan…")
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

                Button {
                    withAnimation(.nokoFluidSpring) {
                        isPresented = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Tans Inspector (Esc)")
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Search & Filters
    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Fast Find — search Tans", text: $search)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(searchFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
            )

            Picker("Show", selection: $filterSelection) {
                Text("All").tag("All")
                Text("Enabled").tag("Enabled")
                Text("Disabled").tag("Disabled")
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
    }

    // MARK: - Status Banner
    private var statusBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: tans.safeMode ? "shield.lefthalf.filled" : "arrow.clockwise")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(tans.safeMode ? "Safe Mode is On" : "Reload Required")
                    .font(.subheadline.bold())
                Text(tans.reloadRequired ? "Reload Discord to apply your latest changes." : "Tans are paused. Your settings are saved.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if tans.reloadRequired {
                Button("Reload") {
                    browser.reload()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if tans.safeMode {
                Button("Resume") {
                    withAnimation(.nokoFluidSpring) {
                        tans.setSafeMode(false)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.24)))
    }

    // MARK: - Installed Tans
    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let installed = tans.installed.filter(matches).filter {
                filterSelection == "All" || tans.enabledIDs.contains($0.id) == (filterSelection == "Enabled")
            }

            if installed.isEmpty {
                VStack(spacing: 8) {
                    Text(tans.installed.isEmpty ? "No Tans Installed" : "No Matching Tans")
                        .font(.subheadline.weight(.semibold))
                    Text(tans.installed.isEmpty ? "Install a built-in Noko-Tan below or import a Tan of your own." : "Try clearing your search or filter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(installed) { package in
                        tanRow(package)
                    }
                }
            }
        }
    }

    private func tanRow(_ package: TanPackage) -> some View {
        let isEnabled = tans.enabledIDs.contains(package.id)
        let isHovered = hoveredTanID == package.id

        return HStack(spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(package.manifest.target == .css ? Color.purple.opacity(0.12) : Color.blue.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: package.manifest.target == .css ? "paintbrush.pointed" : "sparkles")
                    .font(.system(size: 15))
                    .foregroundStyle(package.manifest.target == .css ? .purple : .blue)
            }

            // Info
            Button {
                presentation = .details(package)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(package.manifest.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)

                        if tans.availableOriginalUpdate(package) != nil {
                            NokoPillBadge(text: "Update", color: .accentColor)
                        }
                    }

                    Text(package.manifest.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text(package.origin == "Noko Original" ? "Noko-Tan" : package.origin)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text("v\(package.manifest.version)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            // Switch
            Toggle(
                package.manifest.name,
                isOn: Binding(
                    get: { isEnabled },
                    set: { willEnable in
                        if willEnable {
                            pendingEnable = package
                        } else {
                            withAnimation(.nokoFluidSpring) {
                                tans.setEnabled(package.id, false)
                            }
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(tans.safeMode)
        }
        .padding(10)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.9 : 0.55),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isHovered ? Color.primary.opacity(0.18) : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        )
        .onHover { isHovering in
            hoveredTanID = isHovering ? package.id : (hoveredTanID == package.id ? nil : hoveredTanID)
        }
    }

    // MARK: - Curated Noko-Tans
    private var originalsSection: some View {
        let originals = tans.availableOriginals.filter(matches)
        return Group {
            if !originals.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Discover Noko-Tans", systemImage: "star.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    ForEach(originals) { package in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.orange.opacity(0.12))
                                    .frame(width: 32, height: 32)
                                Image(systemName: package.manifest.target == .css ? "paintbrush.pointed" : "sparkles")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.orange)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(package.manifest.name)
                                    .font(.subheadline.weight(.medium))
                                Text(package.manifest.description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 4)

                            Button("Install") {
                                withAnimation(.nokoFluidSpring) {
                                    do {
                                        try tans.install(package)
                                    } catch {
                                        importError = "This Tan could not be installed."
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.12)))
                    }
                }
            }
        }
    }

    // MARK: - Developer Mode & Safe Mode
    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Safe Mode", isOn: Binding(get: { tans.safeMode }, set: { tans.setSafeMode($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Toggle("Developer Mode", isOn: Binding(get: { tans.developerMode }, set: { tans.setDeveloperMode($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if tans.developerMode {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Diagnostics Console")
                            .font(.caption.bold())
                        Spacer()
                        Button("Create Tan…") { createTemplate() }
                            .font(.caption2)
                        Button("Clear") { tans.clearConsole() }
                            .font(.caption2)
                            .disabled(tans.diagnostics.isEmpty)
                    }

                    if tans.diagnostics.isEmpty {
                        Text("No lifecycle events yet.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(tans.diagnostics.suffix(15).reversed()) { event in
                                    HStack {
                                        Text(event.date, style: .time).foregroundStyle(.secondary)
                                        Text(event.tanID)
                                        Spacer()
                                        Text(event.event.rawValue)
                                            .foregroundStyle(event.event == .failed ? .red : (event.event == .started ? .green : .secondary))
                                    }
                                    .font(.system(size: 10, design: .monospaced))
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - File Actions
    private func importTan(replacing id: String? = nil) {
        guard filePanel == nil, let owner = windowReference.window else { return }
        let panel = NSOpenPanel()
        filePanel = panel
        panel.title = "Import Tan"
        panel.message = "Choose a folder containing manifest.json and its Tan files."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: owner) { response in
            filePanel = nil
            guard response == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let package = try TanPackage.load(folder: url)
                if let id {
                    guard package.id == id else { throw TanError.invalid("Select the same Tan") }
                    try tans.replaceFromLocalFolder(package)
                } else {
                    try tans.install(package)
                }
            } catch {
                importError = "Choose a valid Tan folder. Packages must contain a supported manifest and local source files."
            }
        }
    }

    private func createTemplate() {
        guard filePanel == nil, let owner = windowReference.window else { return }
        let panel = NSOpenPanel()
        filePanel = panel
        panel.title = "Create Tan"
        panel.message = "Choose where to create a NokoTanStarter folder."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: owner) { response in
            filePanel = nil
            guard response == .OK, let parent = panel.url else { return }
            let access = parent.startAccessingSecurityScopedResource()
            defer { if access { parent.stopAccessingSecurityScopedResource() } }
            do {
                let folder = parent.appendingPathComponent("NokoTanStarter", isDirectory: true)
                guard !FileManager.default.fileExists(atPath: folder.path) else { throw TanError.invalid("Folder already exists") }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let manifest = TanManifest(id: "local.my-tan", name: "My Tan", version: "1.0.0", description: "A small touch of your own.", authors: ["You"], target: .isolated, entry: "main.js")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
                let code = "NokoTan.register({ start() {\n  // Add your changes here.\n  return () => { /* Clean up here. */ };\n} });\n"
                try code.write(to: folder.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch {
                importError = "The starter folder could not be created."
            }
        }
    }

    private enum TanPresentation: Identifiable {
        case translator, details(TanPackage)
        var id: String {
            switch self {
            case .translator: "translator"
            case .details(let package): "details." + package.id
            }
        }
    }
}
