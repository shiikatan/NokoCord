import SwiftUI
import AppKit

/// Home owns discovery and controls; execution belongs to TanRuntime.
struct TanHubView: View {
    var showsHomeMusicCard = true
    @Environment(TanManager.self) private var tans
    @Environment(ActiveBrowserEngine.self) private var browser
    @Environment(AppleMusicPresenceService.self) private var appleMusicPresence
    @State private var windowReference = PresentationWindowReference()
    @State private var search = ""
    @State private var hoveredTanID: String?
    @FocusState private var searchFocused: Bool
    @State private var searchBounds = CGRect.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("hideNokoTans") private var hideNokoTans = false
    @AppStorage("maomaoHideInstalledTans") private var hideInstalledTans = false
    @State private var installedVisibleCount = 5
    @State private var enabledFilter = "All"
    @State private var pendingEnable: TanPackage?
    @State private var presentation: TanPresentation?
    @State private var importError: String?
    @State private var filePanel: NSOpenPanel?
    @State private var pendingImport: PendingTanImport?
    @State private var translationInfoExpanded = false
    @State private var translationInfoHovered = false

    private struct PendingTanImport {
        let package: TanPackage
        let decision: TanImportDecision
    }

    private var isMaomao: Bool { EditionIdentity.current?.id == "maomao" }
    private var searchQuery: String {
        isMaomao ? search.trimmingCharacters(in: .whitespacesAndNewlines) : search
    }
    private func matches(_ package: TanPackage) -> Bool {
        searchQuery.isEmpty || (package.manifest.name + " " + package.manifest.description + " " + package.manifest.authors.joined(separator: " ")).localizedStandardContains(searchQuery)
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
                    Toggle("Safe Mode", isOn: Binding(get: { tans.safeMode }, set: { tans.setSafeMode($0) })).toggleStyle(.switch)
                    Button(browser.view == nil ? "Open Discord" : "Continue to Discord", systemImage: "arrow.up.right") { browser.openDiscord() }
                        .modifier(NokoPrimaryAction()).controlSize(.large)
                        .disabled(browser.lifecycle.phase == .clearing)
                }
                if isMaomao && showsHomeMusicCard {
                    HomeMusicPresenceView()
                }
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Fast Find — search Tans", text: $search).textFieldStyle(.plain)
                        .accessibilityLabel("Fast Find").focused($searchFocused)
                    if !search.isEmpty { Button("Clear search", systemImage: "xmark.circle.fill") { search = "" }.labelStyle(.iconOnly).buttonStyle(.plain) }
                }.padding(15).modifier(NokoSurface(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(searchFocused ? Color.accentColor : .clear, lineWidth: contrast == .increased ? 3 : 2))
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("tanHub"))
                    } action: { searchBounds = $0 }
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
                        if isMaomao {
                            let canShow = hideInstalledTans && searchQuery.isEmpty
                            Button(canShow ? "Show Tans" : "Hide Tans", systemImage: canShow ? "chevron.down" : "chevron.up") {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                                    hideInstalledTans = !canShow
                                    if !canShow { search = "" }
                                    installedVisibleCount = 5
                                }
                            }
                            .accessibilityHint("Hide or show the collection. Fast Find can still reveal matching Tans.")
                        }
                        Spacer()
                        Button("Translate Tan…", systemImage: "wand.and.stars") { presentation = .translator }
                        Button("Import Tan…", systemImage: "plus") { importTan() }
                    }
                    if !isMaomao || !hideInstalledTans || !searchQuery.isEmpty {
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
                                    Button("Show all Tans") {
                                        enabledFilter = "All"; search = ""
                                        if isMaomao { hideInstalledTans = false }
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 16))
                        } else {
                            let visible = isMaomao && searchQuery.isEmpty ? Array(installed.prefix(installedVisibleCount)) : installed
                            LazyVStack(spacing: 8) { ForEach(visible) { package in
                                HStack(spacing: 16) {
                                    tanIcon(package)
                                    Button { presentation = .details(package) } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(package.manifest.name).font(.headline)
                                            Text(package.manifest.description).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading).lineLimit(2)
                                            Text((tans.enabledIDs.contains(package.id) ? "Enabled" : "Disabled") + " · " + (package.origin == "Noko Original" ? "Noko-Tan" : package.origin)).font(.caption).foregroundStyle(.secondary)
                                            if package.id == NokoNativeTanID.appleMusicPresence {
                                                let status = appleMusicStatus
                                                Label(status.title, systemImage: status.symbol)
                                                    .font(.caption.weight(.medium))
                                                Text(status.detail).font(.caption).foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
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
                            if isMaomao && searchQuery.isEmpty && installed.count > 5 {
                                HStack {
                                    Text("Showing \(visible.count) of \(installed.count)").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if visible.count < installed.count {
                                        Button("Show more", systemImage: "chevron.down") { installedVisibleCount += 5 }
                                    }
                                    if installedVisibleCount > 5 {
                                        Button("Show fewer", systemImage: "chevron.up") { installedVisibleCount = 5 }
                                    }
                                }
                            }
                        }
                    } else {
                        Text("Your Tans are hidden. Use Fast Find above to look them up, or choose Show Tans.")
                            .font(.callout).foregroundStyle(.secondary)
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
                                    if package.id == NokoNativeTanID.appleMusicPresence {
                                        Text("When enabled, NokoCord reads Music through Apple Events. It looks up cover art using Apple’s iTunes Search service. Only if no cover is found, album and artist details go to Last.fm when configured, or MusicBrainz and Cover Art Archive otherwise. Last.fm may also receive the song title.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
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
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        translationInfoExpanded.toggle()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "info.circle")
                                .font(.title3)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("About Tans").font(.headline)
                                Text("Learn about Tans, translation, updates, and package identity.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 20)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .rotationEffect(.degrees(translationInfoExpanded ? 90 : 0))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { translationInfoHovered = $0 }
                    .accessibilityLabel("About Tans")
                    .accessibilityValue(translationInfoExpanded ? "Expanded" : "Collapsed")
                    .accessibilityHint("Show translation, updates, and package identity information")
                    if translationInfoExpanded {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Translation Compatibility").font(.headline)
                            Text("A classification describes how much conversion work is needed. It does not rate a plugin’s safety or quality.")
                            Group {
                                LabeledContent("Automatic", value: "Can be converted automatically.")
                                Text("NokoCord understands the supported functionality and converts it into Noko-Tan equivalents. Automatic conversion does not make arbitrary third-party code safe.")
                                LabeledContent("Assisted", value: "Mostly convertible; some parts need attention.")
                                Text("Most supported behavior can be converted, while uncertain or unsupported parts may need review or manual adjustment.")
                                LabeledContent("Requires Native Adapter", value: "Needs a NokoCord native capability.")
                                Text("This Tan needs functionality ordinary browser page JavaScript cannot provide. It requires an approved NokoCord native provider or capability.")
                                LabeledContent("Unsupported", value: "Cannot currently be converted reliably.")
                                Text("NokoCord cannot currently make a trustworthy equivalent with the available APIs and runtime. This may change as support improves.")
                            }
                            Text("NokoCord analyzes features, reports uncertain or unsupported behavior, converts supported parts, preserves available source and license details, then validates the Tan locally before installation.")
                            Text("Translated code is still code. Native privileges are never granted silently, and entering a URL does not run remote JavaScript.")

                            Text("Installing & Updating Tans").font(.headline).padding(.top, 4)
                            Text("NokoCord identifies a Tan primarily by its package ID. The same ID means the same Tan; a different ID means a different Tan, even when display names look alike.")
                            Text("Update — A newer version of the same Tan. Importing it replaces the installed version and preserves compatible state or settings where possible. For example: Noko-Chat 1.5.0 → 1.6.0.")
                            Text("Reinstall — If the same Tan and exact version are imported again, NokoCord offers to install it again.")
                            Text("Downgrade — Importing an older version over a newer one prompts for confirmation. Older versions may have different features, settings, or compatibility.")

                            Text("Tan Identity & Similar Names").font(.headline).padding(.top, 4)
                            Text("Different package IDs are separate Tans, even if their names resemble one another—for example, NokoChat, Noko Chat, Noko-Chat, and noko_chat.")
                            Text("When names may be confusing, NokoCord shows “Two Tans have similar names.” Check each Tan’s package ID, author, and source before installing. Install Anyway keeps both Tans; it does not replace one based on its name.")
                        }.font(.callout).foregroundStyle(.secondary).padding(.top, 14)
                    }
                }
                .padding(18).background(.quaternary.opacity(translationInfoHovered ? 0.42 : 0.3), in: .rect(cornerRadius: 14))
            }.frame(maxWidth: 900, alignment: .leading).padding(36).frame(maxWidth: .infinity)
        }
        .coordinateSpace(name: "tanHub")
        .contentShape(Rectangle())
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("tanHub")).onEnded { event in
            if isMaomao && searchFocused && !searchBounds.contains(event.location) {
                searchFocused = false
            }
        })
        .confirmationDialog("Enable \(pendingEnable?.manifest.name ?? "Tan")?", isPresented: Binding(get: { pendingEnable != nil }, set: { if !$0 { pendingEnable = nil } }), titleVisibility: .visible) {
            if let package = pendingEnable { Button("Enable Tan") { tans.setEnabled(package.id, true); pendingEnable = nil } }
            Button("Cancel", role: .cancel) { pendingEnable = nil }
        } message: {
            if pendingEnable?.id == NokoNativeTanID.appleMusicPresence {
                Text("While enabled, NokoCord uses Apple Events to read the current song and playback state from Music and shows the song as your Discord activity. macOS may ask you to allow access to Music. Cover lookup sends artist, title, and album details to Apple’s iTunes Search service. Only if no cover is found, album and artist details go to Last.fm when configured, or MusicBrainz and Cover Art Archive otherwise. Last.fm may also receive the song title.")
            } else {
                Text((pendingEnable?.manifest.target == .css ? "This Tan changes the appearance of Discord. Enable only Tans you trust." : "This Tan runs code inside Discord and can interact with content in your session. Enable only code you trust.") + (pendingEnable?.manifest.capabilities.contains(.appearanceRead) == true ? " It can also read your app appearance setting." : ""))
            }
        }
        .confirmationDialog(importTitle, isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), titleVisibility: .visible) {
            if pendingImport != nil { Button(importActionTitle) { confirmImport() } }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: { Text(importMessage) }
        .alert("Tan could not be installed or updated", isPresented: Binding(get: { importError != nil || tans.error != nil }, set: { if !$0 { importError = nil; tans.dismissError() } })) {
            Button("OK") { importError = nil; tans.dismissError() }
        } message: { Text(importError ?? tans.error ?? "Please try again.") }
        .sheet(item: $presentation) { route in
            switch route {
            case .translator: TanTranslatorView()
            case .details(let package): TanDetailsView(package: package)
            }
        }
        .background(WindowLifetimeObserver(reference: windowReference) {
            filePanel?.cancel(nil); filePanel = nil
            presentation = nil
            pendingEnable = nil
            pendingImport = nil
            importError = nil
        }.frame(width: 0, height: 0))
        .onChange(of: enabledFilter) { _, _ in
            if isMaomao { installedVisibleCount = 5 }
        }
        .onChange(of: searchQuery) { _, _ in
            if isMaomao { installedVisibleCount = 5 }
        }
        .onDisappear { searchFocused = false; filePanel?.cancel(nil); filePanel = nil; presentation = nil; pendingEnable = nil; pendingImport = nil }
    }
    private var importTitle: String {
        guard let pendingImport else { return "Import Tan?" }
        switch pendingImport.decision {
        case .install: return "Install \(pendingImport.package.manifest.name)?"
        case .update: return "Update \(pendingImport.package.manifest.name)?"
        case .reinstall: return "Reinstall \(pendingImport.package.manifest.name) \(pendingImport.package.manifest.version)?"
        case .downgrade: return "Downgrade \(pendingImport.package.manifest.name)?"
        case .similarName: return "Two Tans have similar names"
        }
    }
    private var importActionTitle: String {
        guard let pendingImport else { return "Install" }
        switch pendingImport.decision {
        case .install: return "Install"
        case .update: return "Update"
        case .reinstall: return "Reinstall"
        case .downgrade: return "Downgrade"
        case .similarName: return "Install Anyway"
        }
    }
    private var importMessage: String {
        guard let pendingImport else { return "" }
        let incoming = pendingImport.package
        switch pendingImport.decision {
        case .install: return ""
        case .update(let existing), .reinstall(let existing), .downgrade(let existing):
            let sameOfficialOrigin = ["Noko Original", "Noko-Tan"].contains(existing.origin)
                && ["Noko Original", "Noko-Tan"].contains(incoming.origin)
            let changedIdentity = existing.manifest.authors != incoming.manifest.authors
                || existing.manifest.source != incoming.manifest.source
                || existing.manifest.target != incoming.manifest.target
                || existing.manifest.capabilities != incoming.manifest.capabilities
                || (existing.origin != incoming.origin && !sameOfficialOrigin)
            let identityNotice = changedIdentity ? " The author, source, target, origin, or native access has changed; review it before continuing. This Tan will be disabled for a fresh enable decision." : ""
            let downgradeNotice = incoming.manifest.version.compare(existing.manifest.version, options: .numeric) == .orderedAscending
                ? " Older code or settings may be incompatible. This Tan will be disabled." : ""
            let identityDetails = changedIdentity
                ? "\n\nInstalled: \(existing.manifest.authors.joined(separator: ", ")) · \(existing.manifest.source ?? existing.origin) · \(existing.manifest.target.rawValue)\nIncoming: \(incoming.manifest.authors.joined(separator: ", ")) · \(incoming.manifest.source ?? incoming.origin) · \(incoming.manifest.target.rawValue)"
                : ""
            return "\(existing.manifest.version) → \(incoming.manifest.version). Package ID: \(incoming.id).\(identityNotice)\(downgradeNotice)\(identityDetails)"
        case .similarName(let existing):
            return "These are different package IDs. Both will remain installed.\n\nInstalled: \(existing.manifest.name) \(existing.manifest.version) · \(existing.manifest.authors.joined(separator: ", ")) · \(existing.id) · \(existing.origin)\nIncoming: \(incoming.manifest.name) \(incoming.manifest.version) · \(incoming.manifest.authors.joined(separator: ", ")) · \(incoming.id) · \(incoming.origin)"
        }
    }
    private func confirmImport() {
        guard let pendingImport else { return }
        self.pendingImport = nil
        do {
            switch pendingImport.decision {
            case .install, .similarName: try tans.install(pendingImport.package)
            case .update, .reinstall, .downgrade: try tans.replaceInstalled(pendingImport.package)
            }
        } catch { importError = "This Tan could not be installed. The existing package was kept." }
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

    private var appleMusicStatus: (symbol: String, title: String, detail: String) {
        if tans.safeMode && tans.enabledIDs.contains(NokoNativeTanID.appleMusicPresence) {
            return ("pause.circle", "Paused by Safe Mode", "Resume Tans to read Music again.")
        }
        switch appleMusicPresence.status {
        case .disabled:
            return ("power", "Off", "Turn on this Noko-Tan to show your Apple Music song in Discord.")
        case .waitingForMusic:
            return ("music.note", "Waiting for Music", "Open Apple Music and play a song.")
        case .stopped:
            return ("stop.circle", "Music stopped", "Play a song in Apple Music to show it in Discord.")
        case .playing:
            return ("play.circle", "Music playing", "NokoCord is reading the current song for your Discord activity.")
        case .paused:
            return ("pause.circle", "Music paused", "NokoCord is reading the paused song and position.")
        case .permissionDenied:
            return ("hand.raised", "Music access denied", "In System Settings → Privacy & Security → Automation, allow NokoCord to access Music. Then turn this Noko-Tan off and on.")
        case .unavailable:
            return ("exclamationmark.circle", "Music unavailable", "NokoCord can’t read Music right now. Check that Music is available and try again.")
        }
    }

    private func tanIcon(_ package: TanPackage) -> some View {
        Image(systemName: package.id == NokoNativeTanID.appleMusicPresence ? "music.note" : package.manifest.target == .css ? "paintbrush.pointed" : "sparkles")
            .font(.title2).foregroundStyle(.tint).frame(width: 44, height: 44)
            .background(.tint.opacity(0.1), in: .rect(cornerRadius: 12)).accessibilityHidden(true)
    }
    private func importTan() {
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
                let decision = try tans.importDecision(for: package)
                switch decision {
                case .install: try tans.install(package)
                default: pendingImport = PendingTanImport(package: package, decision: decision)
                }
            }
            catch { importError = "Choose a valid Tan folder. Packages must contain a supported manifest and local source files." }
        }
    }
}
