import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum NokoDestination: String, CaseIterable, Identifiable {
    case home, discord, downloads, shortcuts, privacy, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: String(localized: "Home")
        case .discord: String(localized: "Discord")
        case .downloads: String(localized: "Downloads")
        case .shortcuts: String(localized: "Keyboard shortcuts")
        case .privacy: String(localized: "Privacy")
        case .settings: String(localized: "Settings")
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .discord: "bubble.left.and.bubble.right"
        case .downloads: "arrow.down.circle"
        case .shortcuts: "command"
        case .privacy: "hand.raised"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(ActiveBrowserEngine.self) private var browser
    @Binding var selection: NokoDestination
    @Binding var showQuickSwitcher: Bool
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Home", systemImage: "house").tag(NokoDestination.home)
                Label("Discord", systemImage: "bubble.left.and.bubble.right").tag(NokoDestination.discord)
                Section {
                    Label("Downloads", systemImage: "arrow.down.circle").tag(NokoDestination.downloads)
                    Label("Shortcuts", systemImage: "command").tag(NokoDestination.shortcuts)
                    Label("Privacy", systemImage: "hand.raised").tag(NokoDestination.privacy)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("NokoCord")
            .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 280)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    Button("Quick switcher", systemImage: "command") { showQuickSwitcher = true }
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                }.buttonStyle(.borderless).frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }
        } detail: {
            Group {
                switch selection {
                case .downloads: BrowserSettingsView()
                case .privacy: PrivacyPage()
                case .shortcuts: KeyboardShortcutsView()
                default: home
                }
            }.navigationTitle(selection == .home ? "" : selection.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selection) { _, destination in
            if destination == .discord { browser.openDiscord() }
        }
        .nokoCordAppearance()
    }
    private var home: some View { TanHubView() }
}

struct NokoPageHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint)
                .frame(width: 48, height: 48).background(.tint.opacity(0.1), in: .rect(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(28)
    }
}

struct PrivacyPage: View {
    var body: some View {
        VStack(spacing: 0) {
            NokoPageHeader(title: "Privacy", subtitle: "Control what stays on this Mac.", symbol: "hand.raised")
            ScrollView {
                GroupBox { DiscordSessionControls() } label: { Text("Discord session").font(.headline) }
                    .frame(maxWidth: 760, alignment: .leading).padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct NokoSurface: ViewModifier {
    var cornerRadius: CGFloat = 16
    @AppStorage("useLiquidGlass") private var useLiquidGlass = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        if (EditionIdentity.current?.id != "maomao" && !useLiquidGlass) || reduceTransparency || contrast == .increased {
            content.background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.12)))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

struct NokoPrimaryAction: ViewModifier {
    @AppStorage("useLiquidGlass") private var useLiquidGlass = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        if (EditionIdentity.current?.id == "maomao" || useLiquidGlass) && !reduceTransparency && contrast != .increased {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

struct NokoQuickSwitcher: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: NokoDestination? = .home
    @FocusState private var focused: Bool
    let navigate: (NokoDestination) -> Void
    private var matches: [NokoDestination] {
        NokoDestination.allCases.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to…", text: $query).textFieldStyle(.plain).focused($focused)
                    .onSubmit { activate() }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if matches.isEmpty {
                Text("No matching destinations").foregroundStyle(.secondary).padding()
            }
            ForEach(matches) { destination in
                Button {
                    dismiss(); navigate(destination)
                } label: {
                    HStack { Label(destination.title, systemImage: destination.symbol); Spacer(); if selected == destination { Image(systemName: "return") } }
                        .padding(12).contentShape(Rectangle())
                        .background(selected == destination ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
        }.padding(14).frame(width: 480)
            .onAppear { focused = true }
            .onChange(of: query) { _, _ in selected = matches.first }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
    }
    private func move(_ offset: Int) {
        guard !matches.isEmpty else { selected = nil; return }
        let index = matches.firstIndex(where: { $0 == selected }) ?? 0
        selected = matches[min(max(index + offset, 0), matches.count - 1)]
    }
    private func activate() {
        guard let destination = selected, matches.contains(destination) else { return }
        dismiss(); navigate(destination)
    }
}

struct KeyboardShortcutsView: View {
    var body: some View {
        VStack(spacing: 0) {
            NokoPageHeader(title: "Keyboard shortcuts", subtitle: "A few keys. Right where you want to be.", symbol: "command")
            ScrollView {
                VStack(spacing: 0) {
                    shortcut("Quick switcher", keys: ["⌘", "K"], spoken: "Command K")
                    Divider()
                    shortcut("Open Discord", keys: ["⌘", "⇧", "D"], spoken: "Command Shift D")
                    Divider()
                    shortcut("Home", keys: ["⌘", "⇧", "H"], spoken: "Command Shift H")
                    Divider()
                    shortcut("Settings", keys: ["⌘", ","], spoken: "Command comma")
                    Divider()
                    shortcut("Reload Discord", keys: ["⌘", "R"], spoken: "Command R")
                    if EditionIdentity.current?.id == "maomao" {
                        Divider()
                        shortcut("Show Noko-Bar", keys: ["⌃", "⌘", "N"], spoken: "Control Command N")
                    }
                }.padding(.horizontal, 20)
                    .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 16))
                Text("Reloading Discord interrupts active calls and playback.")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 16)
            }.padding(.horizontal, 28).padding(.bottom, 28)
        }
    }
    private func shortcut(_ title: String, keys: [String], spoken: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            HStack(spacing: 5) {
                ForEach(keys, id: \.self) { key in
                    Text(key).font(.body.monospaced()).frame(minWidth: 26, minHeight: 28)
                        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
                }
            }
        }.padding(.vertical, 14).accessibilityElement(children: .ignore).accessibilityLabel("\(title), \(spoken)")
    }
}

struct SettingsView: View {
    @AppStorage("useLiquidGlass") private var useLiquidGlass = true
    @AppStorage("openDiscordOnLaunch") private var openDiscordOnLaunch = false
    @AppStorage("showMenuBar") private var showMenuBar = false
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        TabView {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image("NokoMark").renderingMode(.original).resizable().scaledToFit().frame(width: 56, height: 56)
                            .clipShape(.rect(cornerRadius: 14)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("NokoCord").font(.title2.bold())
                            Text("Made by shiikatan").foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
                Section("Appearance") {
                    Picker("Color scheme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }.pickerStyle(.radioGroup)
                    if EditionIdentity.current?.id != "maomao" {
                        Toggle("Liquid Glass", isOn: $useLiquidGlass)
                        Text("Use translucent controls and surfaces. Accessibility settings take priority.").font(.caption).foregroundStyle(.secondary)
                    }
                    if EditionIdentity.current?.id == "maomao" {
                        MaomaoDiscordAppearanceSettings()
                        MaomaoBarAppearanceSettings()
                    }
                    Toggle("Show NokoCord in menu bar", isOn: $showMenuBar)
                }
                Section("Startup") {
                    Toggle("Open Discord on Launch", isOn: $openDiscordOnLaunch)
                    Text("Safe Mode always opens Home so you can review your Tans.").font(.caption).foregroundStyle(.secondary)
                }
                Section("About") {
                    if let edition = EditionIdentity.current {
                        LabeledContent("Version", value: edition.publicVersion)
                        LabeledContent("Edition", value: edition.name)
                        LabeledContent("Maintainer", value: edition.maintainer)
                    } else {
                        LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    }
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
            Form {
                DiscordSocialAccountSection()
                DiscordSessionPrivacySection()
                Section { Label("No analytics or telemetry", systemImage: "hand.raised") }
            }.formStyle(.grouped).tabItem { Label("Privacy", systemImage: "hand.raised") }
            ManualUpdatesSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.down.app") }
        }.frame(width: 640, height: 480).nokoCordAppearance()
    }
}

private struct ManualUpdatesSettingsView: View {
    @Environment(TanManager.self) private var tans
    @State private var updater = ManualUpdateService()
    @State private var selectedFileName: String?
    @State private var candidate: ManualUpdateCandidate?
    @State private var phase: Phase = .empty
    @State private var progress: ManualUpdateProgress?
    @State private var dropTargeted = false
    @State private var showFileImporter = false
    @State private var showInformation = false
    @State private var showUpdateConfirmation = false
    @State private var showCleanFirstConfirmation = false
    @State private var showCleanFinalConfirmation = false
    @State private var pendingCandidate: ManualUpdateCandidate?
    @State private var legacyAvailability: ManualUpdateTanImportAvailability?
    @State private var legacyImportResult: ManualUpdateTanImportResult?
    @State private var legacyImportError: String?
    @State private var legacyLoading = true
    @State private var legacyImporting = false
    @State private var showLegacyImportConfirmation = false
    @State private var pendingLegacyDigest: String?
    @State private var helperFailure: ManualUpdateHelperFailureResult?
    @State private var helperFailureError: String?
    @State private var dismissingHelperFailure = false
    @State private var fetcher = NokoFetchService()
    @State private var fetchTask: Task<Void, Never>?
    @State private var fetchID: UUID?
    @State private var fetchProgress: NokoFetchProgress?
    @State private var fetchStatus = "Check GitHub Releases for the latest stable Maomao ZIP."
    @State private var fetchedCandidate = false

    private enum Phase {
        case empty, inspecting, ready, error(String), applying, waitingForRelaunch
    }

    private var isBusy: Bool {
        if legacyImporting || fetchTask != nil { return true }
        return switch phase {
        case .inspecting, .applying, .waitingForRelaunch: true
        default: false
        }
    }

    var body: some View {
        Form {
            if helperFailure != nil || helperFailureError != nil {
                Section("Previous update attempt") {
                    if let helperFailure {
                        Label(helperFailureHeading(helperFailure.status), systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        LabeledContent("Action", value: helperFailure.operation == .cleanReinstall ? "Clean Reinstall" : "Update")
                        LabeledContent("Before attempt", value: "Maomao \(helperFailure.installedVersion) (build \(helperFailure.installedBuild))")
                        LabeledContent("Selected ZIP", value: "Maomao \(helperFailure.candidateVersion) (build \(helperFailure.candidateBuild))")
                        Text(helperFailure.message)
                            .lineLimit(4)
                        Text(helperFailure.recovery)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        Button("Dismiss") { dismissHelperFailure(helperFailure.nonce) }
                            .disabled(dismissingHelperFailure)
                    }
                    if let helperFailureError {
                        Label("Update result needs attention", systemImage: "exclamationmark.triangle")
                        Text(helperFailureError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        Button("Retry") { refreshHelperFailure() }
                    }
                }
            }
            Section("Local update ZIP") {
                Text("Choose a Maomao app ZIP from this Mac. Selecting a file only checks it; nothing is installed until you choose an action below.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Choose ZIP…", systemImage: "folder") { showFileImporter = true }
                        .disabled(isBusy)
                    Button("Information", systemImage: "info.circle") { showInformation = true }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Label("Drop a local ZIP here", systemImage: "square.and.arrow.down")
                        .font(.headline)
                    Text(selectedFileName ?? "No ZIP selected")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                .padding(.horizontal, 16)
                .background(dropTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(dropTargeted ? Color.accentColor : .secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5])))
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
                    guard !isBusy, let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in inspectSelection(url) }
                    }
                    return true
                }
            }

            if EditionIdentity.current?.id == MaomaoDataPaths.editionID {
                Section("Noko-Fetch · GitHub") {
                    Text("Fetch a verified update ZIP from GitHub, then review it below. Local ZIP updates remain available offline.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Noko-Fetch", systemImage: "arrow.down.app") { fetchFromGitHub() }
                            .disabled(isBusy)
                        if fetchTask != nil {
                            Button("Cancel", role: .cancel) { fetchTask?.cancel() }
                        }
                    }
                    if let fetchProgress {
                        switch fetchProgress {
                        case .checking: ProgressView("Checking GitHub…")
                        case .downloading(let version, let received, let total):
                            ProgressView(value: Double(received), total: Double(total)) {
                                Text("Downloading \(version) · \(Int(Double(received) / Double(total) * 100))%")
                            }
                        case .verifying: ProgressView("Verifying SHA-256…")
                        case .inspecting: ProgressView("Checking downloaded ZIP…")
                        }
                    } else {
                        Text(fetchStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Inspection") {
                inspectionContent
                if let candidate, case .ready = phase {
                    LabeledContent("Current", value: versionLabel(candidate.installedMarketingVersion, build: candidate.installedBuild))
                    LabeledContent("Selected ZIP", value: versionLabel(candidate.marketingVersion, build: candidate.build))
                    Text("Current → selected ZIP").font(.caption).foregroundStyle(.secondary)
                    candidateExplanation(candidate)
                    if candidate.permits(.update) {
                        Button("Update…") {
                            pendingCandidate = candidate
                            showUpdateConfirmation = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                    } else if candidate.permits(.cleanReinstall) {
                        Button("Clean Reinstall…", role: .destructive) {
                            pendingCandidate = candidate
                            showCleanFirstConfirmation = true
                        }
                        .disabled(isBusy)
                    }
                }
            }

            Section("Optional shared Tan import") {
                Text("This one-time import is separate from app ZIP updates. A later Clean Reinstall resets imported Tans with other Maomao data.")
                    .font(.caption).foregroundStyle(.secondary)
                legacyImportContent
                if !legacyLoading && !legacyImporting && legacyImportResult == nil {
                    Button("Refresh Tan folder", systemImage: "arrow.clockwise") { refreshLegacyAvailability() }
                        .disabled(isBusy)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): inspectSelection(url)
            case .failure(let error): phase = .error("Could not open the ZIP picker: \(error.localizedDescription)")
            }
        }
        .sheet(isPresented: $showInformation) { informationSheet }
        .confirmationDialog("Update Maomao?", isPresented: $showUpdateConfirmation, titleVisibility: .visible) {
            Button("Update and Relaunch") {
                if let pendingCandidate { apply(pendingCandidate, operation: .update) }
                pendingCandidate = nil
            }
            Button("Cancel", role: .cancel) { pendingCandidate = nil }
        } message: {
            Text("This local ZIP will replace the app with a newer version or build. Maomao will close and relaunch. Your Discord login, Maomao settings, and scoped Tans are preserved. Shared build-3 Tans remain untouched and need a separate import.")
        }
        .confirmationDialog("Reinstall Maomao \(pendingCandidate?.marketingVersion.description ?? "") Cleanly?", isPresented: $showCleanFirstConfirmation, titleVisibility: .visible) {
            Button("Continue to Final Confirmation", role: .destructive) {
                showCleanFirstConfirmation = false
                DispatchQueue.main.async { showCleanFinalConfirmation = true }
            }
            Button("Cancel", role: .cancel) { pendingCandidate = nil }
        } message: {
            Text("This exact same version and build will be reinstalled. It will erase Maomao's Discord login, WebKit data and cookies, scoped Tans, settings, gateways, bridge configuration, and customizations. You will need to sign in and set up again.")
        }
        .alert("Are You Sure?", isPresented: $showCleanFinalConfirmation) {
            Button("Cancel", role: .cancel) { pendingCandidate = nil }
                .keyboardShortcut(.defaultAction)
            Button("Erase Data and Clean Reinstall", role: .destructive) {
                if let pendingCandidate { apply(pendingCandidate, operation: .cleanReinstall) }
                pendingCandidate = nil
            }
        } message: {
            Text("Final confirmation: this permanently erases Maomao's Discord session, WebKit data and cookies, scoped Tans, Tan and app settings, gateways, bridge configuration, and customizations. This cannot be undone.")
        }
        .confirmationDialog("Import shared Tans into Maomao?", isPresented: $showLegacyImportConfirmation, titleVisibility: .visible) {
            Button("Import Shared Tans") {
                if let pendingLegacyDigest { importLegacyTans(expectedSourceDigest: pendingLegacyDigest) }
                pendingLegacyDigest = nil
            }
            Button("Cancel", role: .cancel) { pendingLegacyDigest = nil }
        } message: {
            Text(legacyImportWarning)
        }
        .task {
            let updates = await updater.progressUpdates()
            for await update in updates { progress = update }
        }
        .task { refreshLegacyAvailability() }
        .onAppear { refreshHelperFailure() }
        .onDisappear {
            fetchTask?.cancel()
            if fetchedCandidate, let discarded = candidate, !isBusy {
                candidate = nil
                fetchedCandidate = false
                phase = .empty
                Task { try? await updater.discardCandidate(discarded) }
            }
        }
    }

    @ViewBuilder private var legacyImportContent: some View {
        if legacyImporting {
            ProgressView("Importing shared Tans…")
            Text("The shared source is being checked again before validated files are copied.")
                .font(.caption).foregroundStyle(.secondary)
        } else if let result = legacyImportResult {
            Label("Import complete", systemImage: "checkmark.circle").font(.headline)
            Text("Imported \(result.packageCount) Tans; \(result.enabledCount) saved enabled selections are restored. The shared source folder was left unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            if result.tanManagerRefreshed {
                Text("Your Tans are ready in this session. Review them on Home, especially any that are enabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if legacyLoading {
            ProgressView("Checking shared Tan folder…")
        } else {
            if let legacyImportError {
                Label("Import error", systemImage: "exclamationmark.triangle").font(.headline)
                Text(legacyImportError).foregroundStyle(.secondary)
            }
            if let availability = legacyAvailability {
                if availability.eligible {
                    Label("Shared Tans available", systemImage: "square.on.square").font(.headline)
                    Text("This folder was shared with older editions. Its files have no reliable edition provenance and may include M1.2 or Chiaki Tans.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Source folder").font(.caption).foregroundStyle(.secondary)
                    Text(availability.sourcePath).font(.caption.monospaced())
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    LabeledContent("Validated Tans", value: "\(availability.packageCount)")
                    LabeledContent("Saved as enabled", value: "\(availability.enabledCount)")
                    if availability.translatedArchiveCount > 0 {
                        LabeledContent("Translation archives", value: "\(availability.translatedArchiveCount)")
                    }
                    DisclosureGroup("Tans in shared folder") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(availability.packageNames.indices, id: \.self) { index in
                                Text(availability.packageNames[index])
                            }
                        }.font(.caption).padding(.top, 4)
                    }
                    if availability.safeMode {
                        Text("The saved Safe Mode setting is on, so imported enabled Tans will stay paused until you resume them.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if availability.enabledCount > 0 {
                        Text("Saved enabled Tans may start running in Discord as soon as you import them.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Import Shared Tans…") {
                        pendingLegacyDigest = availability.sourceDigest
                        showLegacyImportConfirmation = pendingLegacyDigest != nil
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                } else {
                    legacyUnavailableMessage(availability.reason)
                }
            }
        }
    }

    @ViewBuilder private func legacyUnavailableMessage(_ reason: ManualUpdateTanImportBlockReason?) -> some View {
        switch reason {
        case .sourceMissing:
            Label("No shared Tan folder found", systemImage: "tray")
                .foregroundStyle(.secondary)
        case .alreadyCompleted:
            Label("One-time import already completed", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .scopedStorageExists:
            Label("Maomao already has its own Tans", systemImage: "square.stack")
            Text("The import is unavailable because it would replace your existing Maomao Tan collection.")
                .font(.caption).foregroundStyle(.secondary)
        case .unsupportedBaseline:
            Label("Import not supported by this build", systemImage: "xmark.circle")
            Text("Install the M1.3.0 checkpoint before importing shared Tans.")
                .font(.caption).foregroundStyle(.secondary)
        case .noValidatedPackages:
            Label("No valid Tans to import", systemImage: "tray")
            Text("The shared folder contains no Tan packages that passed validation.")
                .font(.caption).foregroundStyle(.secondary)
        case .invalidSource(let detail):
            Label("Shared Tan folder unavailable", systemImage: "exclamationmark.triangle")
            Text(detail).font(.caption).foregroundStyle(.secondary)
        case nil:
            Label("Shared Tan import unavailable", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var legacyImportWarning: String {
        guard let availability = legacyAvailability else { return "Review the shared Tan folder before importing." }
        let executionWarning = availability.enabledCount > 0
            ? " \(availability.enabledCount) saved enabled Tans may start running in Discord immediately\(availability.safeMode ? " after Safe Mode is turned off" : "")."
            : ""
        return "The shared build-3 Tan folder has no reliable edition provenance. It may contain M1.2 or Chiaki data. This one-time action copies \(availability.packageCount) validated Tans, matching translation archives, and saved Tan settings into Maomao; the original folder stays untouched.\(executionWarning) Import is separate from Update and Clean Reinstall."
    }

    private func refreshLegacyAvailability() {
        guard !isBusy else { return }
        legacyLoading = true
        legacyImportError = nil
        Task {
            do {
                legacyAvailability = try await updater.legacyTanImportAvailability()
            } catch {
                legacyAvailability = nil
                legacyImportError = error.localizedDescription
            }
            legacyLoading = false
        }
    }

    private func refreshHelperFailure() {
        Task {
            do {
                helperFailure = try await updater.pendingHelperFailure()
                helperFailureError = nil
            } catch {
                helperFailure = nil
                helperFailureError = "Could not read the saved updater result. \(String(error.localizedDescription.prefix(240)))"
            }
        }
    }

    private func helperFailureHeading(_ status: ManualUpdateHelperFailureStatus) -> LocalizedStringKey {
        switch status {
        case .recoveryPending: "Update recovery needs attention"
        case .previousAppRestored: "Previous app restored"
        case .previousAppStillInstalled: "Previous app remains installed"
        case .replacementReadyCleanupIncomplete: "Replacement ready; cleanup incomplete"
        }
    }

    private func dismissHelperFailure(_ nonce: String) {
        guard !dismissingHelperFailure else { return }
        dismissingHelperFailure = true
        Task {
            do {
                try await updater.dismissHelperFailure(nonce: nonce)
                helperFailure = nil
                helperFailureError = nil
            } catch {
                helperFailureError = "Could not dismiss the saved updater result. \(String(error.localizedDescription.prefix(240)))"
            }
            dismissingHelperFailure = false
        }
    }

    private func importLegacyTans(expectedSourceDigest: String) {
        guard !isBusy, legacyAvailability?.sourceDigest == expectedSourceDigest else { return }
        legacyImporting = true
        legacyImportError = nil
        Task {
            do {
                let result = try await updater.importLegacyTansOnce(expectedSourceDigest: expectedSourceDigest, refreshing: tans)
                legacyImportResult = result
                legacyAvailability = try? await updater.legacyTanImportAvailability()
            } catch {
                legacyAvailability = nil
                legacyImportError = (error as? ManualUpdateError) == .staleCandidate
                    ? "The shared Tan folder changed since the preview. Refresh the folder and review it before importing."
                    : error.localizedDescription
            }
            legacyImporting = false
        }
    }

    @ViewBuilder private var inspectionContent: some View {
        switch phase {
        case .empty:
            Label("No ZIP selected", systemImage: "doc.zipper").foregroundStyle(.secondary)
            Text("Choose or drop a ZIP to inspect it. Selection does not install it.")
                .font(.caption).foregroundStyle(.secondary)
        case .inspecting:
            ProgressView(progressLabel)
            Text("The ZIP is being copied to a private location and checked before any action is offered.")
                .font(.caption).foregroundStyle(.secondary)
        case .ready:
            if let candidate {
                Label(candidate.classification == .older || candidate.classification == .unsupportedBaseline ? "Not Supported" : "Available",
                      systemImage: candidate.classification == .older || candidate.classification == .unsupportedBaseline ? "xmark.circle" : "checkmark.circle")
                    .font(.headline)
            }
        case .error(let message):
            Label("Error", systemImage: "exclamationmark.triangle").font(.headline)
            Text(message).foregroundStyle(.secondary)
            Text("Choose a different local ZIP or inspect this one again.")
                .font(.caption).foregroundStyle(.secondary)
        case .applying:
            ProgressView(progressLabel)
            Text("Keep Maomao open while the update handoff starts.")
                .font(.caption).foregroundStyle(.secondary)
        case .waitingForRelaunch:
            Label("Relaunching Maomao", systemImage: "arrow.clockwise").font(.headline)
            Text("The update handoff started. Maomao will close and reopen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func candidateExplanation(_ candidate: ManualUpdateCandidate) -> some View {
        switch candidate.classification {
        case .newerMarketingVersion:
            Text("A newer Maomao version is available. Updating preserves the Discord session, Maomao settings, and Tans in Maomao's scoped storage. Shared build-3 Tans remain untouched and require a separate import.")
                .font(.caption).foregroundStyle(.secondary)
        case .newerBuild:
            Text("This ZIP has the same version number with a newer build. Updating preserves the Discord session, Maomao settings, and Tans in Maomao's scoped storage. Shared build-3 Tans remain untouched and require a separate import.")
                .font(.caption).foregroundStyle(.secondary)
        case .sameVersionCleanReinstall:
            Text("This is the exact installed version and build. Only Clean Reinstall is available; it erases Maomao-owned data during the reinstall and relaunch. Read Information before continuing.")
                .font(.caption).foregroundStyle(.secondary)
        case .older:
            Text("This ZIP contains an older version or build. This updater cannot install it. To downgrade, back up your data and install the older app manually.")
                .font(.caption).foregroundStyle(.secondary)
        case .unsupportedBaseline:
            Text("This installed Maomao version is below the supported updater baseline. Install the M1.3.0 checkpoint manually, then inspect a ZIP here again.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var informationSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("About Manual Updates").font(.title2.bold())
                Text("Choose a local Maomao app ZIP or drop it into Updates. Selection inspects the ZIP only. Noko-Fetch is an optional way to download a verified ZIP from GitHub when you request it. There are no background update checks. Both paths use the same inspection and installation process.")
                Text("Update").font(.headline)
                Text("Update is offered only for a newer version or build. After you confirm, Maomao closes and relaunches. Your Discord session, Maomao settings and customizations, and scoped Tans are preserved. The old shared build-3 Tan folder is left untouched; import from it separately after reviewing its provenance warning.")
                Text("Clean Reinstall").font(.headline)
                Text("Clean Reinstall can repair a broken Maomao installation. It is offered only for the exact same version and build. It replaces the app and resets Maomao-owned data during the reinstall and relaunch:")
                VStack(alignment: .leading, spacing: 5) {
                    Text("• Discord login, WebKit data, and cookies")
                    Text("• Maomao's scoped Tans, Tan settings, and enabled selections")
                    Text("• Maomao preferences, gateway and bridge configuration, caches, and customizations")
                }
                Text("You will need to sign in and set up again. Two separate confirmations are required.")
                    .fontWeight(.semibold)
                HStack { Spacer(); Button("Done") { showInformation = false }.keyboardShortcut(.defaultAction) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(width: 520, height: 390)
    }

    private var progressLabel: String {
        switch progress {
        case .inspecting: "Inspecting ZIP…"
        case .copyingArchive: "Copying ZIP privately…"
        case .validatingArchive: "Checking ZIP contents…"
        case .extracting: "Unpacking app for inspection…"
        case .validatingApplication: "Checking app identity and signature…"
        case .staging: "Staging the replacement app…"
        case .launchingHelper: "Starting the update helper…"
        case .applying: "Preparing update handoff…"
        case .waitingForRelaunch: "Waiting for Maomao to relaunch…"
        default: "Inspecting ZIP…"
        }
    }

    private func versionLabel(_ version: ManualUpdateVersion, build: ManualUpdateBuild) -> String {
        "Maomao \(version) (build \(build))"
    }

    private func inspectSelection(_ url: URL) {
        guard !isBusy else { return }
        fetchedCandidate = false
        selectedFileName = url.lastPathComponent
        candidate = nil
        pendingCandidate = nil
        guard url.isFileURL, url.pathExtension.lowercased() == "zip" else {
            phase = .error("Choose a local .zip file containing a Maomao app.")
            return
        }
        phase = .inspecting
        progress = .inspecting
        Task {
            do {
                candidate = try await updater.inspect(zipURL: url)
                phase = .ready
            } catch {
                candidate = nil
                phase = .error(error.localizedDescription)
            }
        }
    }

    private func fetchFromGitHub() {
        guard !isBusy, EditionIdentity.current?.id == MaomaoDataPaths.editionID,
              Bundle.main.bundleIdentifier == MaomaoDataPaths.bundleIdentifier,
              let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let version = try? ManualUpdateVersion(value) else { return }
        let id = UUID()
        fetchID = id
        candidate = nil
        pendingCandidate = nil
        fetchedCandidate = false
        selectedFileName = nil
        phase = .empty
        fetchProgress = .checking
        fetchTask = Task {
            defer { fetchTask = nil; fetchProgress = nil }
            do {
                try await updater.discardCandidates()
                let result = try await fetcher.fetch(currentVersion: version, updater: updater) { update in
                    Task { @MainActor in
                        guard fetchID == id, fetchTask != nil else { return }
                        fetchProgress = update
                    }
                }
                if Task.isCancelled {
                    if case .ready(let discarded, _) = result { try? await updater.discardCandidate(discarded) }
                    throw CancellationError()
                }
                switch result {
                case .upToDate(let remote):
                    fetchStatus = remote == version ? "Up to date · M\(version)" : "Up to date · this Mac has a newer Maomao version than GitHub."
                case .ready(let inspected, let filename):
                    candidate = inspected
                    selectedFileName = filename
                    fetchedCandidate = true
                    phase = .ready
                    fetchStatus = "SHA-256 verified · review M\(version) → M\(inspected.marketingVersion) below."
                }
            } catch is CancellationError {
                fetchStatus = "Cancelled. Nothing was installed."
            } catch {
                fetchStatus = (error as? NokoFetchError)?.errorDescription ?? NokoFetchError.storage.errorDescription!
            }
            fetchID = nil
        }
    }

    private func apply(_ candidate: ManualUpdateCandidate, operation: ManualUpdateOperation) {
        guard !isBusy, candidate.permits(operation) else { return }
        phase = .applying
        progress = .applying
        Task {
            do {
                _ = try await updater.apply(candidate: candidate, operation: operation)
                phase = .waitingForRelaunch
                RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) {
                    NSApp.terminate(nil)
                }
            } catch {
                self.candidate = nil
                phase = .error(error.localizedDescription)
            }
        }
    }
}

private struct NokoCordAppearance: ViewModifier {
    @AppStorage("appearance") private var appearance = "system"
    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }
}

extension View {
    func nokoCordAppearance() -> some View { modifier(NokoCordAppearance()) }
}
