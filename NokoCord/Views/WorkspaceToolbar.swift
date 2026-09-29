import SwiftUI

/// Modern Apple Liquid Glass floating capsule toolbar for the Discord workspace.
struct WorkspaceToolbar: View {
    @Environment(ActiveBrowserEngine.self) private var browser
    @Environment(TanManager.self) private var tans
    @Binding var showTansInspector: Bool
    @Binding var showQuickSwitcher: Bool
    @Binding var showBookmarksDrawer: Bool
    @State private var showDownloadsPopover = false
    @State private var showCallReadiness = false
    @State private var showCompatibility = false
    @State private var gamePresence = GamePresenceService.shared
    @State private var showGameRPPopover = false
    @State private var appleMusicRPC = AppleMusicRPCService.shared

    var body: some View {
        HStack(spacing: 6) {
            // MARK: - Home / Tan Hub (⌘⇧H)
            Button {
                browser.showHome()
            } label: {
                Image(systemName: "house")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Home / Tan Hub (⌘⇧H)")
            .accessibilityLabel("Home and Tan Hub")

            Divider()
                .frame(height: 14)
                .padding(.horizontal, 1)

            // MARK: - Navigation Chevrons (shown when history is available)
            if browser.canGoBack || browser.canGoForward {
                HStack(spacing: 2) {
                    Button {
                        browser.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .disabled(!browser.canGoBack)
                    .help("Back (⌘[)")
                    .accessibilityLabel("Back")
                    .buttonStyle(.plain)

                    Button {
                        browser.goForward()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .disabled(!browser.canGoForward)
                    .help("Forward (⌘])")
                    .accessibilityLabel("Forward")
                    .buttonStyle(.plain)
                }

                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 1)
            }

            // Keep diagnostics reachable before a call is active. Otherwise a
            // failed join would hide the only surface explaining why it was
            // not confirmed.
            if !browser.isInCall,
               browser.lifecycle.phase == .ready,
               browser.discordCompatibility.isSupportedRoute {
                Button {
                    showCallReadiness.toggle()
                } label: {
                    Image(systemName: browser.callReadiness.state == .blocked ? "exclamationmark.shield" : "checkmark.shield")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(browser.callReadiness.state == .ready ? Color.green : Color.orange)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show call readiness")
                .help("Show call readiness")
                .popover(isPresented: $showCallReadiness, arrowEdge: .bottom) {
                    CallReadinessView(
                        readiness: browser.callReadiness,
                        onRetry: { browser.refreshCallReadiness() },
                        teardownState: browser.callTeardown,
                        onRequestLeave: { browser.disconnectCall() }
                    )
                }

                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 1)
            }

            if browser.lifecycle.phase == .ready {
                Button {
                    showCompatibility.toggle()
                } label: {
                    Image(systemName: compatibilityIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(compatibilityColor)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show Discord compatibility")
                .help("Show Discord compatibility")
                .popover(isPresented: $showCompatibility, arrowEdge: .bottom) {
                    CompatibilityCenterView(
                        snapshot: browser.discordCompatibility,
                        onRefresh: { browser.refreshDiscordCompatibility() }
                    )
                }
            }

            // MARK: - Voice Call Status Pill (when in call)
            if browser.isInCall {
                Button {
                    browser.toggleMicrophoneMute()
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(browser.isMicrophoneMuted ? Color.orange : Color.green)
                            .frame(width: 6, height: 6)
                        Image(systemName: browser.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(browser.isMicrophoneMuted ? Color.orange : Color.green)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        (browser.isMicrophoneMuted ? Color.orange : Color.green).opacity(0.14),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .help(browser.isMicrophoneMuted ? "Unmute Microphone (⌘⇧M)" : "Mute Microphone (⌘⇧M)")
                .accessibilityLabel(browser.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone")

                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 1)
            }

            // MARK: - Game Rich Presence Status Pill (when active)
            if let presence = gamePresence.activePresence {
                Button {
                    showGameRPPopover.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color(red: 0.7, green: 0.45, blue: 1.0), Color(red: 0.45, green: 0.55, blue: 1.0)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        Text(presence.name)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: 110)

                        if let start = presence.startTimestamp {
                            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                                let elapsed = max(0, Int(context.date.timeIntervalSince(start)))
                                let mins = elapsed / 60
                                let secs = elapsed % 60
                                Text(String(format: "%02d:%02d", mins, secs))
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.18), Color.indigo.opacity(0.14)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.purple.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Game Rich Presence: \(presence.name)")
                .popover(isPresented: $showGameRPPopover, arrowEdge: .bottom) {
                    GamePresencePopoverView(presence: presence)
                }

                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 1)
            }

            // MARK: - Apple Music Rich Presence Pill (when playing)
            if let track = appleMusicRPC.currentTrack,
               track.playerState.isPlaying,
               appleMusicRPC.isEnabled,
               appleMusicRPC.helperStatus == .connected {
                HStack(spacing: 5) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.pink, Color.purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Text(track.name)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: 110)

                    Text(track.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 80)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.pink.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.pink.opacity(0.25), lineWidth: 0.5))
                .help("Apple Music: \(track.name) by \(track.artist) (\(track.formattedProgress))")

                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 1)
            }

            // MARK: - Quick Switcher (⌘K)
            Button {
                showQuickSwitcher = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quick Switcher (⌘K)")
            .accessibilityLabel("Quick switcher")

            // MARK: - Saved Messages / Bookmarks (⌘⇧B)
            Button {
                withAnimation(.nokoFluidSpring) {
                    showBookmarksDrawer.toggle()
                }
            } label: {
                Image(systemName: showBookmarksDrawer ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(showBookmarksDrawer ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Saved Messages (⌘⇧B)")
            .accessibilityLabel("Saved messages")

            // MARK: - Downloads Popover Button
            Button {
                showDownloadsPopover.toggle()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(hasActiveDownloads ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())

                    if hasActiveDownloads {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 1, y: -1)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Downloads")
            .accessibilityLabel("Downloads")
            .popover(isPresented: $showDownloadsPopover, arrowEdge: .bottom) {
                DownloadsPopoverView()
                    .environment(browser)
            }

            // MARK: - Dedicated In-App Tans Inspector Trigger (⌘T)
            Button {
                withAnimation(.nokoFluidSpring) {
                    showTansInspector.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(showTansInspector ? Color.white : Color.accentColor)

                    Text("Tans")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(showTansInspector ? Color.white : Color.primary)

                    if !tans.active.isEmpty {
                        Text("\(tans.active.count)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(showTansInspector ? Color.accentColor : Color.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(showTansInspector ? Color.white : Color.accentColor, in: Capsule())
                    } else if tans.safeMode {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    showTansInspector
                        ? Color.accentColor
                        : Color.accentColor.opacity(0.12),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            showTansInspector ? Color.clear : Color.accentColor.opacity(0.22),
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(.plain)
            .help("Tans Inspector (⌘T)")
            .accessibilityLabel("Tans Inspector")

            // MARK: - Settings (⌘,)
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")

            // MARK: - Reload (⌘R)
            Button {
                browser.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .disabled(!browser.lifecycle.isVisible || browser.lifecycle.phase == .clearing)
            .buttonStyle(.plain)
            .help("Reload Discord (⌘R)")
            .accessibilityLabel("Reload Discord")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 10, x: 0, y: 3)
    }

    private var hasActiveDownloads: Bool {
        browser.downloads.records.contains { $0.status == .downloading || $0.status == .choosing }
    }

    private var compatibilityIcon: String {
        if browser.discordCompatibility.features.values.contains(.unsupported) { return "shield.lefthalf.filled" }
        if browser.discordCompatibility.features.values.contains(.degraded) { return "exclamationmark.shield" }
        if browser.discordCompatibility.features.values.allSatisfy({ $0 == .healthy }) { return "checkmark.shield" }
        return "questionmark.shield"
    }

    private var compatibilityColor: Color {
        if browser.discordCompatibility.features.values.contains(.unsupported) { return .red }
        if browser.discordCompatibility.features.values.contains(.degraded) { return .orange }
        if browser.discordCompatibility.features.values.allSatisfy({ $0 == .healthy }) { return .green }
        return .secondary
    }
}
