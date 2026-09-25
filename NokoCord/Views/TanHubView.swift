import SwiftUI
import AppKit

/// Home owns discovery and controls; execution belongs to TanRuntime.
struct TanHubView: View {
    @Environment(TanManager.self) private var tans
    @Environment(ActiveBrowserEngine.self) private var browser
    @State private var windowReference = PresentationWindowReference()
    @State private var search = ""
    @State private var hoveredTanID: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("hideNokoTans") private var hideNokoTans = false
    @State private var enabledFilter = "All"
    @State private var pendingEnable: TanPackage?
    @State private var presentation: TanPresentation?
    @State private var importError: String?
    @State private var filePanel: NSOpenPanel?
    @State private var pendingReloadID: String?

    private func matches(_ package: TanPackage) -> Bool {
        search.isEmpty || (package.manifest.name + " " + package.manifest.description + " " + package.manifest.authors.joined(separator: " ")).localizedStandardContains(search)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 18) {
                    Image("NokoMark").renderingMode(.original).resizable().interpolation(.high).scaledToFit()
                        .frame(width: 72, height: 72).clipShape(.rect(cornerRadius: 19)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Make it yours.").font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("A little Noko. A lot of possibility.").font(.title3).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button(browser.view == nil ? "Open Discord" : "Continue to Discord", systemImage: "arrow.up.right") { browser.openDiscord() }
                        .modifier(NokoPrimaryAction()).controlSize(.large)
                        .disabled(browser.lifecycle.phase == .clearing)
                }
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Fast Find — search Tans", text: $search).textFieldStyle(.plain)
                        .accessibilityLabel("Fast Find").focused($searchFocused)
                    if !search.isEmpty { Button("Clear search", systemImage: "xmark.circle.fill") { search = "" }.labelStyle(.iconOnly).buttonStyle(.plain) }
                }.padding(15).modifier(NokoSurface(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(searchFocused ? Color.accentColor : .clear, lineWidth: contrast == .increased ? 3 : 2))
                if tans.safeMode || tans.reloadRequired {
                    HStack(spacing: 14) {
                        Image(systemName: tans.safeMode ? "shield.lefthalf.filled" : "arrow.clockwise").font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tans.safeMode ? "Safe Mode is on" : "One more step").font(.headline)
                            Text(tans.reloadRequired ? "Reload Discord to finish applying your changes." : "Your Tans are paused. Your selections are saved.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if tans.reloadRequired { Button("Reload Discord") { browser.reload() } }
                        if tans.safeMode { Button("Resume Tans") { tans.setSafeMode(false) } }
                    }.padding(18).background(.orange.opacity(0.1), in: .rect(cornerRadius: 15))
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Your Tans").font(.title2.bold())
                        Text("\(tans.installed.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Translate Tan…", systemImage: "wand.and.stars") { presentation = .translator }
                        Button("Import Tan…", systemImage: "plus") { importTan() }
                    }
                    Picker("Show", selection: $enabledFilter) {
                        Text("All").tag("All")
                        Text("Enabled").tag("Enabled")
                        Text("Disabled").tag("Disabled")
                    }.pickerStyle(.segmented).frame(maxWidth: 300)
                    let installed = tans.installed.filter(matches).filter { enabledFilter == "All" || tans.enabledIDs.contains($0.id) == (enabledFilter == "Enabled") }
                    if installed.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(tans.installed.isEmpty ? "Start with something small." : "No matching Tans").font(.headline)
                            Text(tans.installed.isEmpty ? "Choose a Noko-Tan, or import a Tan of your own." :
                                 search.isEmpty ? "No Tans match this filter. Choose All to see your collection." : "Try another name, author, or feature.")
                                .foregroundStyle(.secondary)
                            if !tans.installed.isEmpty && enabledFilter != "All" {
                                Button("Show all Tans") { enabledFilter = "All"; search = "" }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 16))
                    } else {
                        LazyVStack(spacing: 8) { ForEach(installed) { package in
                            HStack(spacing: 16) {
                                tanIcon(package)
                                Button { presentation = .details(package) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(package.manifest.name).font(.headline)
                                        Text(package.manifest.description).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading).lineLimit(2)
                                        Text((tans.enabledIDs.contains(package.id) ? "Enabled" : "Disabled") + " · " + (package.origin == "Noko Original" ? "Noko-Tan" : package.origin)).font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                if tans.availableOriginalUpdate(package) != nil {
                                    Text("Update available").font(.caption).foregroundStyle(.tint)
                                }
                                Toggle(package.manifest.name, isOn: Binding(get: { tans.enabledIDs.contains(package.id) }, set: { enabled in
                                    if enabled { pendingEnable = package } else { tans.setEnabled(package.id, false) }
                                })).labelsHidden().toggleStyle(.switch).disabled(tans.safeMode)
                            }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hoveredTanID == package.id ? Color.primary.opacity(contrast == .increased ? 0.6 : 0.18) : .clear))
                                .onHover { hoveredTanID = $0 ? package.id : (hoveredTanID == package.id ? nil : hoveredTanID) }
                        } }
                    }
                }
                let originals = tans.availableOriginals.filter(matches)
                HStack {
                    Text("Noko-Tans").font(.headline)
                    Spacer()
                    Button(hideNokoTans ? "Show Noko-Tans" : "Hide Noko-Tans") {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { hideNokoTans.toggle() }
                    }
                }
                if !hideNokoTans && !originals.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Small touches, made for NokoCord.").foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 14) {
                            ForEach(originals) { package in
                                VStack(alignment: .leading, spacing: 14) {
                                    tanIcon(package)
                                    Text(package.manifest.name).font(.headline)
                                    Text(package.manifest.description).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                    Button("Install", systemImage: "plus") {
                                        do { try tans.install(package) } catch { importError = "This Tan could not be installed." }
                                    }.buttonStyle(.bordered)
                                }.padding(22).frame(maxWidth: .infinity, minHeight: 195, alignment: .topLeading)
                                    .background(.tint.opacity(0.06), in: .rect(cornerRadius: 18))
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    Toggle("Safe Mode", isOn: Binding(get: { tans.safeMode }, set: { tans.setSafeMode($0) })).toggleStyle(.switch)
                    Spacer()
                    Toggle("Developer Mode", isOn: Binding(get: { tans.developerMode }, set: { tans.setDeveloperMode($0) })).toggleStyle(.switch)
                }
                if tans.developerMode {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Tan Console").font(.headline)
                            Button("Create Tan…") { createTemplate() }
                            Spacer()
                            Button("Clear") { tans.clearConsole() }.disabled(tans.diagnostics.isEmpty)
                        }
                        Text("Inspect Discord with its context menu. Diagnostics contain lifecycle events only.").font(.caption).foregroundStyle(.secondary)
                        if tans.diagnostics.isEmpty { Text("No events yet.").foregroundStyle(.secondary) }
                        ForEach(tans.diagnostics.suffix(20).reversed()) { event in
                            HStack {
                                Text(event.date, style: .time).foregroundStyle(.secondary)
                                Text(event.tanID)
                                Spacer()
                                Text(event.event.rawValue)
                            }.font(.caption.monospaced())
                        }
                    }.padding(18).background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 14))
                }
            }.frame(maxWidth: 900, alignment: .leading).padding(36).frame(maxWidth: .infinity)
        }
        .confirmationDialog("Enable \(pendingEnable?.manifest.name ?? "Tan")?", isPresented: Binding(get: { pendingEnable != nil }, set: { if !$0 { pendingEnable = nil } }), titleVisibility: .visible) {
            if let package = pendingEnable { Button("Enable Tan") { tans.setEnabled(package.id, true); pendingEnable = nil } }
            Button("Cancel", role: .cancel) { pendingEnable = nil }
        } message: {
            Text((pendingEnable?.manifest.target == .css ? "This Tan changes the appearance of Discord. Enable only Tans you trust." : "This Tan runs code inside Discord and can interact with content in your session. Enable only code you trust.") + (pendingEnable?.manifest.capabilities.contains(.appearanceRead) == true ? " It can also read your app appearance setting." : ""))
        }
        .alert("Tan could not be updated", isPresented: Binding(get: { importError != nil || tans.error != nil }, set: { if !$0 { importError = nil; tans.dismissError() } })) {
            Button("OK") { importError = nil; tans.dismissError() }
        } message: { Text(importError ?? tans.error ?? "Please try again.") }
        .sheet(item: $presentation, onDismiss: {
            if let id = pendingReloadID { pendingReloadID = nil; importTan(replacing: id) }
        }) { route in
            switch route {
            case .translator: TanTranslatorView()
            case .details(let package):
                TanDetailsView(package: package) { id in
                    pendingReloadID = id
                    presentation = nil
                }
            }
        }
        .background(WindowLifetimeObserver(reference: windowReference) {
            pendingReloadID = nil
            filePanel?.cancel(nil); filePanel = nil
            presentation = nil
            pendingEnable = nil
            importError = nil
        }.frame(width: 0, height: 0))
        .onDisappear { pendingReloadID = nil; filePanel?.cancel(nil); filePanel = nil; presentation = nil; pendingEnable = nil }
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

    private func tanIcon(_ package: TanPackage) -> some View {
        Image(systemName: package.manifest.target == .css ? "paintbrush.pointed" : "sparkles")
            .font(.title2).foregroundStyle(.tint).frame(width: 44, height: 44)
            .background(.tint.opacity(0.1), in: .rect(cornerRadius: 12)).accessibilityHidden(true)
    }
    private func createTemplate() {
        guard filePanel == nil, let owner = windowReference.window else { return }
        let panel = NSOpenPanel()
        filePanel = panel
        panel.title = "Create Tan"
        panel.message = "Choose where to create a NokoTanStarter folder. Edit its files, then import the folder."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
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
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
                let code = "NokoTan.register({ start() {\n  // Add your changes here.\n  return () => { /* Remove your changes here. */ };\n} });\n"
                try code.write(to: folder.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch { importError = "The starter folder could not be created. Choose a writable location without an existing NokoTanStarter folder." }
        }
    }
    private func importTan(replacing id: String? = nil) {
        guard filePanel == nil, let owner = windowReference.window else { return }
        let panel = NSOpenPanel()
        filePanel = panel
        panel.title = "Import Tan"
        panel.message = "Choose a folder containing manifest.json and its Tan files."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
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
                } else { try tans.install(package) }
            }
            catch { importError = "Choose a valid Tan folder. Packages must contain a supported manifest and local source files." }
        }
    }
}
