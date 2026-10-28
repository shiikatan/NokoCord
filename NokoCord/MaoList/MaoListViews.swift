import SwiftUI

struct MaoListView: View {
    @Binding var sidebarVisible: Bool
    @Environment(MLRuntime.self) private var runtime
    @Environment(ActiveBrowserEngine.self) private var browser
    @Environment(\.nokoWorkspaceVisible) private var workspaceVisible
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var entryReduceMotion
    @State private var filtersPresented = false
    private var entryActive: Bool { workspaceVisible && activeState != .inactive }
    private var showEntryLoader: Bool {
        entryActive && runtime.entryLoadingEligible && runtime.entryLoading.isVisible()
    }
    var body: some View {
        @Bindable var runtime = runtime
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                HStack(alignment: .center, spacing: 8) {
                    Image("MaoListMark").renderingMode(.original).resizable().scaledToFit()
                        .frame(width: 28, height: 28).clipShape(.rect(cornerRadius: 7))
                        .accessibilityHidden(true)
                    Text("MaoList").font(.title3.weight(.semibold))
                }.fixedSize(horizontal: true, vertical: false)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find anime or manga", text: Binding(get: { runtime.search.term }, set: { value in
                        guard value != runtime.search.term else { return }
                        runtime.seedSearchFromSection(); runtime.searchTypingDeadline = .now.advanced(by: .milliseconds(350)); runtime.search.term = value; runtime.searching = true; runtime.routes.removeAll()
                    }))
                        .textFieldStyle(.plain).onSubmit { runtime.searchSubmissionRevision += 1; runtime.searchTypingDeadline = nil; runtime.searching = true; runtime.routes.removeAll() }
                    if !runtime.search.term.isEmpty || (runtime.searching && runtime.routes.isEmpty) {
                        Button(runtime.search.term.isEmpty ? "Close search" : "Clear search", systemImage: "xmark.circle.fill") { runtime.search.term = ""; runtime.searching = false }
                            .labelStyle(.iconOnly).buttonStyle(.plain)
                    }
                }.padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: 360).modifier(MLPanel())
                Spacer(minLength: 12)
                Button {
                    sidebarVisible.toggle()
                } label: {
                    Label(sidebarVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
                .labelStyle(.iconOnly)
                .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                Button("Filters", systemImage: "line.3.horizontal.decrease") { runtime.seedSearchFromSection(); filtersPresented.toggle() }
                    .popover(isPresented: $filtersPresented) { MLSearchFilterView(filters: $runtime.search) { runtime.searchSubmissionRevision += 1; runtime.searchTypingDeadline = nil; runtime.searchConfigured = true; runtime.searching = true; runtime.routes.removeAll(); filtersPresented = false } }
                Button { browser.openDiscord() } label: {
                    Image("NokoMark").renderingMode(.original).resizable().scaledToFit()
                        .frame(width: 24, height: 24).clipShape(.rect(cornerRadius: 6))
                        .padding(4).frame(width: 32, height: 32)
                }.buttonStyle(.plain).help("Switch to NokoCord (⌃⌘M)")
                    .accessibilityLabel("Switch to NokoCord")
                if let viewer = runtime.viewer {
                    Button { runtime.routes.append(.notifications) } label: {
                        Label("Notifications", systemImage: viewer.unreadNotificationCount ?? 0 > 0 ? "bell.badge" : "bell")
                    }.labelStyle(.iconOnly).help("AniList notifications")
                    Button { runtime.routes.append(.profile(viewer.id)) } label: {
                        MLArtwork(url: viewer.avatar?.medium, width: 30, height: 30, radius: 15)
                    }.buttonStyle(.plain).accessibilityLabel("Your AniList profile")
                } else if runtime.restoring {
                    ProgressView().controlSize(.small).accessibilityLabel("Restoring AniList connection")
                } else {
                    Button(runtime.connecting ? "Connecting…" : "Connect AniList") { runtime.connect() }.disabled(runtime.connecting || runtime.restoring)
                }
            }.padding(.horizontal, 28).padding(.vertical, 14)
            HStack(spacing: 3) {
                ForEach(MLSection.allCases) { section in
                    MLNavigationButton(section: section, selected: runtime.section == section && !runtime.searching) {
                        runtime.section = section; runtime.searching = false; runtime.routes.removeAll()
                    }
                }
                Spacer()
                Text("Powered by AniList").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 28).padding(.bottom, 0)
            Divider()
            if runtime.needsReconnect {
                HStack { Text("Your AniList connection needs renewing."); Spacer(); Button("Reconnect") { runtime.connect() } }.font(.callout).padding(12)
            }
            if let error = runtime.accountError { MLErrorBanner(message: error) { runtime.accountError = nil } }
            routeContent
                .accessibilityHidden(showEntryLoader)
                .overlay {
                    if showEntryLoader { MLEntryLoader(reduceMotion: entryReduceMotion) }
                }
        }
        .environment(runtime).modifier(MLAppearance())
        .onChange(of: "\(runtime.entryLoadingEligible)/\(runtime.entryLoadingPending)/\(runtime.entryLoadingPermitted)/\(entryActive)", initial: true) { _, _ in
            runtime.entryLoading.update(loading: runtime.entryLoadingEligible, pending: runtime.entryLoadingPending,
                                        active: entryActive, permitted: runtime.entryLoadingPermitted)
        }
        .task(id: runtime.entryLoading.deadline) {
            guard let deadline = runtime.entryLoading.deadline else { return }
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
                if runtime.entryLoading.deadline == deadline { runtime.entryLoading.dismiss() }
            } catch { /* Dismissal cancels only this presentation timeout. */ }
        }
        .onChange(of: runtime.search.term) { _, term in
            if !term.isEmpty { runtime.searching = true; runtime.routes.removeAll(); runtime.search.sort = "SEARCH_MATCH" }
        }
        .task(id: "\(activeState != .inactive && workspaceVisible)/\(runtime.viewer?.id ?? 0)") {
            guard activeState != .inactive && workspaceVisible else { runtime.suspend(); return }
            runtime.beginRestoreConnection()
        }
        .mlTask(id: "viewer/\(runtime.viewer?.id ?? 0)/\(runtime.section)/\(runtime.searching)/\(runtime.mutationRevision)") {
            if runtime.section != .home || runtime.searching { await runtime.refreshViewer() }
        }
        .onDisappear { runtime.entryLoading.dismiss(); runtime.suspend() }
    }
    @ViewBuilder private var routeContent: some View {
        if let route = runtime.routes.last {
            VStack(spacing: 0) {
                HStack {
                    Button("Back", systemImage: "chevron.left") { _ = runtime.routes.popLast() }.keyboardShortcut("[", modifiers: .command)
                    Spacer()
                }.padding(.horizontal, 26).padding(.vertical, 8)
                switch route {
                case .media(let id): MLMediaDetailView(id: id, preview: runtime.mediaPreview(id))
                case .profile(let id): MLProfileView(id: id)
                case .activity(let id): MLSingleActivityView(id: id)
                case .review(let id): MLReviewDetailView(id: id)
                case .character(let id): MLEntityView(id: id, kind: .character)
                case .staff(let id): MLEntityView(id: id, kind: .staff)
                case .studio(let id): MLEntityView(id: id, kind: .studio)
                case .notifications: MLNotificationsView()
                }
            }.id(route)
        } else if runtime.searching {
            MLSearchView(filters: runtime.search)
        } else {
            switch runtime.section {
            case .home: MLHomeView()
            case .anime: MLLibraryView(type: .anime)
            case .manga: MLLibraryView(type: .manga)
            case .discover: MLDiscoveryView()
            case .activity: MLActivityView(userID: nil)
            }
        }
    }
}

struct MaoListSettingsSection: View {
    @Environment(MaoListModule.self) private var module
    @State private var listPreferencesPresented = false
    @State private var preparationConfirmation = false
    @AppStorage("maolistAccent") private var accent = ""
    @AppStorage("maolistThemePreset") private var presetID = ""
    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { module.enabled }, set: module.setEnabled)) {
                SettingsControlLabel("Enable MaoList", explanation: "A native AniList companion for anime and manga. Turning it off unloads MaoList and preserves your saved connection.")
            }
            Toggle(isOn: Binding(get: { module.prepareAtLaunch }, set: { value in
                if value { preparationConfirmation = true }
                else { module.setPrepareAtLaunch(false) }
            })) {
                SettingsControlLabel("Prepare MaoList at launch", explanation: "Prepare sections and library pages during startup so MaoList is ready sooner.")
            }.disabled(!module.enabled)
                .alert("Prepare MaoList at launch?", isPresented: $preparationConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Enable") { module.setPrepareAtLaunch(true) }
                } message: {
                    Text("MaoList will prepare all main sections and your anime and manga library pages when the app starts. This uses additional memory, processing power, and network data. Large libraries take longer and are subject to cache limits. Prepared data is kept for up to 30 minutes; refresh to see newer changes.")
                }
            if module.prepareAtLaunch, let status = module.runtime?.preparationStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Module")
        } footer: {
            Text("Module version: \(MaoListModule.version)")
        }
        if module.enabled {
            Section("Appearance") {
                MLThemePresetPicker(selection: $presetID)
                ColorPicker("Accent color", selection: Binding(get: { Color(mlHex: accent) ?? Color(mlHex: "72CDB4")! }, set: { accent = $0.mlHex ?? ""; presetID = "" }), supportsOpacity: false)
                Button("Reset MaoList colors") { accent = ""; presetID = "" }
            }
            if let runtime = module.runtime, runtime.viewer != nil {
                Section("List preferences") {
                    Button("AniList list preferences…") { listPreferencesPresented = true }
                        .sheet(isPresented: $listPreferencesPresented) { MLListPreferencesView().environment(runtime) }
                }
            }
        }
    }
}

struct MaoListAccountSection: View {
    @Environment(MaoListModule.self) private var module
    var body: some View {
        Section("AniList connection") {
            if let runtime = module.runtime { MLAccountControls().environment(runtime) }
            else { Text("Enable MaoList in Settings → MaoList to connect AniList. Your saved connection is preserved while MaoList is off.").foregroundStyle(.secondary) }
        }
    }
}
private struct MLAccountControls: View {
    @Environment(MLRuntime.self) private var runtime
    @State private var firstConfirmation = false
    @State private var finalConfirmation = false
    @State private var disconnecting = false
    var body: some View {
        if let user = runtime.viewer { Label(user.name ?? "Connected to AniList", systemImage: "checkmark.circle") }
        if let error = runtime.accountError { Text(error).font(.caption).foregroundStyle(.secondary) }
        if runtime.connecting {
            HStack { ProgressView().controlSize(.small); Text("Waiting for AniList…"); Button("Cancel") { runtime.cancelConnect() } }
        } else {
            HStack {
                Button(runtime.viewer == nil ? "Connect AniList" : "Reconnect AniList") { runtime.connect() }.disabled(runtime.restoring || disconnecting)
                Button("Disconnect AniList…", role: .destructive) { firstConfirmation = true }.disabled(disconnecting)
            }
        }
        Text("AniList is separate from your Discord account. Its access token is saved only in macOS Keychain.").font(.caption).foregroundStyle(.secondary)
            .onAppear { runtime.beginRestoreConnection() }
            .confirmationDialog("Disconnect AniList?", isPresented: $firstConfirmation, titleVisibility: .visible) {
                Button("Continue", role: .destructive) { finalConfirmation = true }
                Button("Cancel", role: .cancel) {}
            } message: { Text("You’ll need to reconnect to edit your AniList lists.") }
            .alert("Are you sure?", isPresented: $finalConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Remove connection and local account data", role: .destructive) {
                    disconnecting = true
                    Task { await runtime.disconnect(); disconnecting = false }
                }
            } message: { Text("This removes the saved AniList authentication and account-specific MaoList cache from this Mac. Your lists on AniList are preserved. MaoList stays available for connecting another account.") }
    }
}

struct MLErrorBanner: View {
    let message: String
    var dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
            if let dismiss { Button("Dismiss", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).buttonStyle(.borderless) }
        }.padding(12).modifier(MLPanel()).padding(.horizontal, 26).padding(.vertical, 6)
    }
}
struct MLStaleBanner: View {
    let date: Date?
    var partial = false
    var body: some View {
        if let date { Label("Showing saved information from \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8) }
        if partial { Label("Some AniList information is unavailable. You can keep browsing.", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8) }
    }
}

struct MLPageWindowNotice: View {
    let released: Bool
    var body: some View {
        if released { Text("Earlier pages were released to keep MaoList light. Reopen this page to return to the beginning.").font(.caption).foregroundStyle(.secondary) }
    }
}
struct MLSectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded)).tracking(-0.6).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct MLMediaCard: View {
    @Environment(MLRuntime.self) private var runtime
    @Environment(\.mlPalette) private var palette
    let media: MLMedia
    @State private var hovered = false
    private var accessibilityDescription: String {
        var parts = [media.name, media.summary]
        if let status = media.mediaListEntry?.status { parts.append(status.title(for: media.type ?? .anime)) }
        if let score = media.averageScore { parts.append("\(score)% average score") }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    var body: some View {
        Button { runtime.openMedia(media) } label: {
            VStack(alignment: .leading, spacing: 10) {
                MLArtwork(url: media.coverImage?.large, width: 152, height: 228, radius: 12)
                    .overlay(alignment: .bottomLeading) {
                        if let status = media.mediaListEntry?.status {
                            Text(status.title(for: media.type ?? .anime)).font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(palette.surface, in: .capsule).padding(8)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hovered ? palette.accent : Color.primary.opacity(0.08), lineWidth: hovered ? 2 : 1))
                Text(media.name).font(.callout.weight(.semibold)).lineLimit(2).frame(height: 36, alignment: .topLeading)
                HStack(spacing: 5) {
                    Text(media.summary)
                    Spacer(minLength: 2)
                    if let score = media.averageScore { Image(systemName: "star.fill").font(.system(size: 9)); Text("\(score)%").monospacedDigit() }
                }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: 152, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0; runtime.anticipateMedia(media, hovering: $0) }.onDisappear { runtime.anticipateMedia(media, hovering: false) }.help(media.name).accessibilityLabel(accessibilityDescription)
    }
}
struct MLMediaGrid: View {
    let media: [MLMedia]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 152, maximum: 180), spacing: 20)], alignment: .leading, spacing: 28) {
            ForEach(media) { MLMediaCard(media: $0) }
        }
    }
}
struct MLConnectionPrompt: View {
    @Environment(MLRuntime.self) private var runtime
    var type: MLMediaType = .anime
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(runtime.restoring ? "Restoring your AniList connection…" : type == .manga ? "Your next manga, one click away." : "Your next episode, one click away.", systemImage: runtime.restoring ? "person.crop.circle" : "books.vertical").font(.title2.bold())
            Text(runtime.restoring ? "Public browsing is available while MaoList restores your saved connection." : "Connect AniList to keep your anime and manga lists up to date here. You can browse without signing in.").foregroundStyle(.secondary)
            HStack {
                if runtime.restoring { ProgressView().controlSize(.small) }
                else { Button("Connect AniList") { runtime.connect() }.buttonStyle(.borderedProminent).disabled(runtime.connecting) }
                Button(type == .manga ? "Browse manga" : "Browse anime") { runtime.searchTypingDeadline = nil; runtime.search = MLSearchFilters(); runtime.search.type = type; runtime.searching = true }
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).modifier(MLPanel())
    }
}

private struct MLNavigationButton: View {
    @Environment(\.mlPalette) private var palette
    let section: MLSection
    let selected: Bool
    let action: () -> Void
    private var symbol: String {
        switch section {
        case .home: "house"
        case .anime: "play.rectangle"
        case .manga: "book.closed"
        case .discover: "safari"
        case .activity: "bubble.left.and.bubble.right"
        }
    }
    var body: some View {
        Button(action: action) {
            Label(section.rawValue, systemImage: symbol)
                .font(.callout.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? palette.accent : Color.secondary)
                .padding(.horizontal, 12).padding(.vertical, 13)
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    Capsule().fill(selected ? palette.accent : Color.clear).frame(height: 3).padding(.horizontal, 12)
                }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
