import SwiftUI

/// Command palette action item for the Spotlight-style HUD.
struct PaletteAction: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let category: String
    let icon: String
    let shortcut: String?
    let tint: Color
    let handler: () -> Void

    static func == (lhs: PaletteAction, rhs: PaletteAction) -> Bool {
        lhs.id == rhs.id
    }
}

/// Apple Spotlight / Raycast-style floating Liquid Glass Command Palette (⌘K).
struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    @Environment(ActiveBrowserEngine.self) private var browser
    @Environment(TanManager.self) private var tans
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var pendingConfirmation: PaletteConfirmation?
    @FocusState private var isFieldFocused: Bool
    @AppStorage(NokoAppDefaults.showFloatingToolbar) private var showFloatingToolbar = false

    var onOpenDownloads: (() -> Void)?
    var onOpenTutorial: (() -> Void)?

    private enum PaletteConfirmation: Identifiable {
        case safeMode(enable: Bool)
        case tan(package: TanPackage, enable: Bool)

        var id: String {
            switch self {
            case .safeMode(let enable): return "safe-mode-\(enable)"
            case .tan(let package, let enable): return "tan-\(package.id)-\(enable)"
            }
        }

        var title: String {
            switch self {
            case .safeMode(let enable): return enable ? "Start Safe Mode?" : "Resume Tans?"
            case .tan(let package, let enable): return "\(enable ? "Enable" : "Disable") \(package.manifest.name)?"
            }
        }

        var buttonTitle: String {
            switch self {
            case .safeMode(let enable): return enable ? "Start Safe Mode" : "Resume Tans"
            case .tan(_, let enable): return enable ? "Enable Tan" : "Disable Tan"
            }
        }

        var isDestructive: Bool {
            switch self {
            case .safeMode(let enable): return !enable
            case .tan(_, let enable): return !enable
            }
        }

        var message: String {
            switch self {
            case .safeMode(let enable):
                return enable
                    ? "Safe Mode reloads Discord without Noko scripts or bridge handlers."
                    : "Resuming Tans will allow the currently approved packages to run after Discord reloads."
            case .tan(let package, let enable):
                if enable {
                    return package.manifest.target == .css
                        ? "This Tan changes Discord’s appearance. Enable only code you trust."
                        : "This Tan runs inside Discord and can interact with content in your signed-in session. Enable only code you trust."
                }
                return "Disabling this Tan may require a Discord reload before the page returns to its original state."
            }
        }
    }

    private var actions: [PaletteAction] {
        var items: [PaletteAction] = []

        // MARK: - Voice & Call (Active Call Controls)
        if browser.isInCall {
            items.append(PaletteAction(
                id: "call.mute",
                title: browser.isMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone",
                subtitle: browser.isMicrophoneMuted ? "Resume microphone input in Discord" : "Silence microphone in Discord",
                category: "Voice Call",
                icon: browser.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
                shortcut: "⌘⇧M",
                tint: browser.isMicrophoneMuted ? .orange : .green
            ) {
                browser.toggleMicrophoneMute()
            })

            items.append(PaletteAction(
                id: "call.disconnect",
                title: "Disconnect from Call",
                subtitle: "Leave the active voice channel",
                category: "Voice Call",
                icon: "phone.down.fill",
                shortcut: "⌘⇧D",
                tint: .red
            ) {
                browser.disconnectCall()
            })
        }

        // MARK: - Navigation
        items.append(PaletteAction(
            id: "nav.discord",
            title: "Discord",
            subtitle: "Jump to Discord main channels",
            category: "Navigation",
            icon: "bubble.left.and.bubble.right.fill",
            shortcut: "⌘⇧O",
            tint: .accentColor
        ) {
            browser.openDiscord()
        })

        items.append(PaletteAction(
            id: "nav.home",
            title: "Home & Tan Hub",
            subtitle: "Return to the native shell, Tan Hub, translator, and shortcuts",
            category: "Navigation",
            icon: "house.fill",
            shortcut: "⌘⇧H",
            tint: .blue
        ) {
            browser.showHome()
        })

        items.append(PaletteAction(
            id: "nav.settings",
            title: "Settings",
            subtitle: "Open application preferences",
            category: "Navigation",
            icon: "gearshape.fill",
            shortcut: "⌘,",
            tint: .gray
        ) {
            openSettings()
        })

        items.append(PaletteAction(
            id: "nav.downloads",
            title: "Downloads",
            subtitle: "View active and recent Discord downloads",
            category: "Navigation",
            icon: "arrow.down.circle.fill",
            shortcut: nil,
            tint: .blue
        ) {
            onOpenDownloads?()
        })

        items.append(PaletteAction(
            id: "nav.bookmarks",
            title: "Saved Messages / Bookmarks",
            subtitle: "View private locally saved Discord messages and notes",
            category: "Productivity",
            icon: "bookmark.fill",
            shortcut: "⌘⇧B",
            tint: .accentColor
        ) {
            browser.onToggleBookmarks?()
        })

        items.append(PaletteAction(
            id: "nav.toolbar",
            title: showFloatingToolbar ? "Auto-hide Floating Toolbar" : "Always Show Floating Toolbar",
            subtitle: showFloatingToolbar ? "Hide the toolbar so it only reveals on hover" : "Keep the floating capsule permanently pinned",
            category: "Navigation",
            icon: "capsule",
            shortcut: nil,
            tint: .indigo
        ) {
            showFloatingToolbar.toggle()
        })

        items.append(PaletteAction(
            id: "nav.zen_mode",
            title: browser.isZenMode ? "Exit Zen Mode (Show Sidebars)" : "Enter Zen Mode (Focus Chat)",
            subtitle: browser.isZenMode ? "Restore Discord server and channel sidebars" : "Hide sidebars to keep the chat focused",
            category: "Navigation",
            icon: "sidebar.left",
            shortcut: "⌘\\",
            tint: .teal
        ) {
            browser.toggleZenMode()
        })

        // MARK: - Game Rich Presence
        if let presence = GamePresenceService.shared.activePresence {
            items.append(PaletteAction(
                id: "rp.stop",
                title: "Stop Broadcasting \(presence.name)",
                subtitle: "Clear current Game Rich Presence and reset Discord status",
                category: "Game Rich Presence",
                icon: "gamecontroller.fill",
                shortcut: nil,
                tint: .purple
            ) {
                GamePresenceService.shared.clearPresence()
            })
        }
        items.append(PaletteAction(
            id: "rp.toggle_daemon",
            title: GamePresenceService.shared.isEnabled ? "Disable Game Rich Presence IPC" : "Enable Game Rich Presence IPC",
            subtitle: GamePresenceService.shared.isEnabled ? "Mute local game presence listening on /tmp/discord-ipc-0" : "Resume listening for game presence",
            category: "Game Rich Presence",
            icon: "gamecontroller",
            shortcut: nil,
            tint: GamePresenceService.shared.isEnabled ? .purple : .gray
        ) {
            GamePresenceService.shared.isEnabled.toggle()
        })

        // MARK: - Apple Music Rich Presence
        let musicPackage = TanPackage.appleMusicRPC
        let musicEnabled = tans.enabledIDs.contains(musicPackage.id)
        if let track = AppleMusicRPCService.shared.currentTrack,
           track.playerState.isPlaying,
           AppleMusicRPCService.shared.helperStatus == .connected {
            items.append(PaletteAction(
                id: "applemusic.now_playing",
                title: "Now Playing: \(track.name)",
                subtitle: "\(track.artist) • \(track.album) (\(track.formattedProgress))",
                category: "Apple Music RPC",
                icon: "music.note",
                shortcut: nil,
                tint: .pink
            ) {
                AppleMusicRPCService.shared.refresh()
            })
        }
        items.append(PaletteAction(
            id: "applemusic.toggle_rpc",
            title: musicEnabled ? "Disable Apple Music RPC" : "Enable Apple Music RPC",
            subtitle: musicEnabled
                ? "Stop broadcasting Apple Music status to Discord"
                : (tans.installed.contains { $0.id == musicPackage.id }
                    ? "Enable the Noko-Tan, then reload Discord to apply"
                    : "Install and enable the bundled Noko-Tan, then reload Discord"),
            category: "Apple Music RPC",
            icon: "waveform",
            shortcut: nil,
            tint: musicEnabled ? .pink : .gray
        ) {
            if musicEnabled { tans.setEnabled(musicPackage.id, false) }
            else { tans.enableOriginal(musicPackage) }
        })

        // MARK: - Tans Extensions
        items.append(PaletteAction(
            id: "tans.toggle_inspector",
            title: "Tans Inspector",
            subtitle: "Slide open the native Tans management drawer",
            category: "Extensions",
            icon: "sparkles",
            shortcut: "⌘T",
            tint: .purple
        ) {
            browser.onToggleTans?()
        })

        items.append(PaletteAction(
            id: "tans.safe_mode",
            title: tans.safeMode ? "Disable Safe Mode" : "Enable Safe Mode",
            subtitle: tans.safeMode ? "Restore enabled Tan modifications" : "Reload Discord with all Tans isolated",
            category: "Extensions",
            icon: tans.safeMode ? "shield.fill" : "shield.slash",
            shortcut: nil,
            tint: .orange
        ) {
            tans.setSafeMode(!tans.safeMode)
        })

        for package in tans.installed {
            let isEnabled = tans.enabledIDs.contains(package.id)
            items.append(PaletteAction(
                id: "tan.pkg.\(package.id)",
                title: "\(isEnabled ? "Disable" : "Enable") \(package.manifest.name)",
                subtitle: package.manifest.description,
                category: "Installed Tans",
                icon: isEnabled ? "checkmark.circle.fill" : "circle",
                shortcut: nil,
                tint: isEnabled ? .green : .secondary
            ) {
                tans.setEnabled(package.id, !isEnabled)
            })
        }

        // MARK: - View & Controls
        items.append(PaletteAction(
            id: "view.reload",
            title: "Reload Discord",
            subtitle: "Refresh current Discord channel view",
            category: "Controls",
            icon: "arrow.clockwise",
            shortcut: "⌘R",
            tint: .blue
        ) {
            browser.reload()
        })

        items.append(PaletteAction(
            id: "view.zoom_in",
            title: "Zoom In",
            subtitle: "Increase Discord scale factor",
            category: "Controls",
            icon: "plus.magnifyingglass",
            shortcut: "⌘+",
            tint: .blue
        ) {
            browser.zoomIn()
        })

        items.append(PaletteAction(
            id: "view.zoom_out",
            title: "Zoom Out",
            subtitle: "Decrease Discord scale factor",
            category: "Controls",
            icon: "minus.magnifyingglass",
            shortcut: "⌘-",
            tint: .blue
        ) {
            browser.zoomOut()
        })

        items.append(PaletteAction(
            id: "view.zoom_reset",
            title: "Actual Size",
            subtitle: "Reset Discord zoom level to 100%",
            category: "Controls",
            icon: "1.magnifyingglass",
            shortcut: "⌘0",
            tint: .blue
        ) {
            browser.resetZoom()
        })

        items.append(PaletteAction(
            id: "view.purge_memory",
            title: "Purge Web Cache & RAM",
            subtitle: "Release uncompressed image buffers and pause inactive media",
            category: "Controls",
            icon: "trash.circle.fill",
            shortcut: nil,
            tint: .orange
        ) {
            browser.purgeMemoryCache()
        })

        // MARK: - Developer
        items.append(PaletteAction(
            id: "dev.mode",
            title: tans.developerMode ? "Disable Developer Mode" : "Enable Developer Mode",
            subtitle: "Toggle Web Inspector context menu and Tan reloading",
            category: "Developer",
            icon: "hammer.fill",
            shortcut: nil,
            tint: .indigo
        ) {
            tans.setDeveloperMode(!tans.developerMode)
        })

        // MARK: - Help & Tour
        items.append(PaletteAction(
            id: "help.tutorial",
            title: "NokoCord Tour & Shortcuts",
            subtitle: "Show first-launch feature guide and keyboard cheatsheet",
            category: "Help",
            icon: "sparkles.tv.fill",
            shortcut: "⌘/",
            tint: .purple
        ) {
            onOpenTutorial?()
        })

        return items
    }

    private var filteredActions: [PaletteAction] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return actions }
        return actions.filter {
            $0.title.localizedStandardContains(trimmed) ||
            ($0.subtitle?.localizedStandardContains(trimmed) ?? false) ||
            $0.category.localizedStandardContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search Input Header
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accentColor)

                TextField("Type a command or search…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .focused($isFieldFocused)
                    .onSubmit {
                        executeSelected()
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear command search")
                }

                Text("ESC")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
                .foregroundStyle(Color.primary.opacity(0.08))

            // Action Items List
            if filteredActions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No commands found for “\(query)”")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filteredActions.enumerated()), id: \.element.id) { index, action in
                                actionRow(action, isSelected: index == selectedIndex)
                                    .id(action.id)
                                    .onTapGesture {
                                        execute(action)
                                    }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selectedIndex) { _, newIndex in
                        if newIndex >= 0 && newIndex < filteredActions.count {
                            proxy.scrollTo(filteredActions[newIndex].id, anchor: .center)
                        }
                    }
                }
            }

            Divider()
                .foregroundStyle(Color.primary.opacity(0.08))

            // Footer Shortcut Hints
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Navigate")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Select")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)

                Spacer()

                Text("NokoCommand")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.02))
        }
        .frame(width: 560)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 32, x: 0, y: 16)
        .onAppear {
            isFieldFocused = true
            selectedIndex = 0
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .onKeyPress(.downArrow) {
            moveSelection(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.escape) {
            withAnimation(.nokoSnappySpring) {
                isPresented = false
            }
            return .handled
        }
        .confirmationDialog(
            pendingConfirmation?.title ?? "Confirm Tan action",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let confirmation = pendingConfirmation {
                Button(confirmation.buttonTitle, role: confirmation.isDestructive ? .destructive : nil) {
                    apply(confirmation)
                    pendingConfirmation = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
        } message: {
            Text(pendingConfirmation?.message ?? "")
        }
    }

    private func actionRow(_ action: PaletteAction, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : action.tint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)

                if let subtitle = action.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let shortcut = action.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        isSelected
                            ? Color.white.opacity(0.18)
                            : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 4)
                    )
            }

            Text(action.category)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    isSelected
                        ? Color.white.opacity(0.12)
                        : Color.primary.opacity(0.04),
                    in: Capsule()
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? Color.accentColor
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    private func moveSelection(_ delta: Int) {
        let count = filteredActions.count
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
    }

    private func executeSelected() {
        guard selectedIndex >= 0 && selectedIndex < filteredActions.count else { return }
        execute(filteredActions[selectedIndex])
    }

    private func execute(_ action: PaletteAction) {
        if let confirmation = confirmation(for: action) {
            pendingConfirmation = confirmation
            return
        }
        withAnimation(.nokoSnappySpring) {
            isPresented = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            action.handler()
        }
    }

    private func confirmation(for action: PaletteAction) -> PaletteConfirmation? {
        switch action.id {
        case "tans.safe_mode":
            return .safeMode(enable: !tans.safeMode)
        case "applemusic.toggle_rpc":
            let package = TanPackage.appleMusicRPC
            return .tan(package: package, enable: !tans.enabledIDs.contains(package.id))
        default:
            guard action.id.hasPrefix("tan.pkg."),
                  let package = tans.installed.first(where: { action.id == "tan.pkg.\($0.id)" }) else {
                return nil
            }
            return .tan(package: package, enable: !tans.enabledIDs.contains(package.id))
        }
    }

    private func apply(_ confirmation: PaletteConfirmation) {
        switch confirmation {
        case .safeMode(let enable):
            tans.setSafeMode(enable)
        case .tan(let package, let enable):
            if enable {
                if TanPackage.originals.contains(package) {
                    tans.enableOriginal(package)
                } else {
                    tans.setEnabled(package.id, true)
                }
            } else {
                tans.setEnabled(package.id, false)
            }
        }
        withAnimation(.nokoSnappySpring) {
            isPresented = false
        }
    }
}
