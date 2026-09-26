import SwiftUI
import WebKit

struct NokoRootView: View {
    @Environment(ActiveBrowserEngine.self) private var browser
    @Environment(TanManager.self) private var tans
    @Environment(\.openSettings) private var openSettings

    @State private var showTansInspector = false
    @State private var showQuickSwitcher = false
    @State private var showBookmarksDrawer = false
    @State private var bookmarkToast: String?
    @State private var showDownloadsSheet = false
    @AppStorage("showFloatingToolbar") private var showFloatingToolbar = false
    @State private var isHoveringToolbarZone = false
    @AppStorage("hasSeenWelcomeTutorial") private var hasSeenWelcomeTutorial = false
    @State private var showWelcomeTutorial = false
    @State private var activeMediaURL: URL?
    @State private var activeMediaIsVideo = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // MARK: - 1. Full-Bleed Native Discord Viewport (100% Window Edge-to-Edge)
            Group {
                if browser.lifecycle.phase == .failed || browser.lifecycle.phase == .crashed {
                    ContentUnavailableView {
                        Label(
                            browser.lifecycle.phase == .crashed ? "Discord needs to reopen" : "Discord could not load",
                            systemImage: "network.slash"
                        )
                    } description: {
                        Text("Check your connection, then reload. Reloading interrupts any active call.")
                    } actions: {
                        Button("Reload Discord") { browser.reload() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let view = browser.view {
                    BrowserHostView(view: view, visible: true)
                        .id(ObjectIdentifier(view))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Initial launching state before WebKit view is attached
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Opening Discord…")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .background(Color(nsColor: NSColor(srgbRed: 0.118, green: 0.122, blue: 0.133, alpha: 1.0)))

            // MARK: - 2. Native Top Hairline Loading Progress Bar
            if browser.lifecycle.phase == .loading {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, proxy.size.width * browser.progress), height: 2.5)
                        .animation(.nokoSnappySpring, value: browser.progress)
                }
                .frame(height: 2.5)
                .ignoresSafeArea()
                .zIndex(20)
            }

            // MARK: - 3. Native Voice Call HUD (Top Center)
            if browser.isInCall {
                NativeVoiceHUD()
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .zIndex(16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // MARK: - 4. Floating Header Capsule (Auto-hide on hover or pinned by preference)
            if showFloatingToolbar || isHoveringToolbarZone {
                WorkspaceToolbar(
                    showTansInspector: $showTansInspector,
                    showQuickSwitcher: $showQuickSwitcher,
                    showBookmarksDrawer: $showBookmarksDrawer
                )
                .padding(.top, 10)
                .padding(.trailing, 16)
                .zIndex(15)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isHoveringToolbarZone = hovering
                    }
                }
            } else {
                // Invisible top-right trigger zone (does not block Discord buttons)
                Color.clear
                    .frame(width: 80, height: 16)
                    .contentShape(Rectangle())
                    .padding(.top, 0)
                    .padding(.trailing, 16)
                    .zIndex(15)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isHoveringToolbarZone = hovering
                        }
                    }
            }

            // MARK: - 5. Floating Notice Banner (if any)
            if let notice = browser.notice {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.tint)
                    Text(notice)
                        .font(.callout)
                    Spacer()
                    Button("Dismiss") { browser.dismissNotice() }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.3), radius: 10, y: 4)
                .padding(.horizontal, 24)
                .padding(.top, 50)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity, alignment: .center)
                .zIndex(18)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // MARK: - 5b. Saved Bookmark Toast Banner
            if let toast = bookmarkToast {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.35), radius: 10, y: 4)
                .padding(.top, 46)
                .frame(maxWidth: .infinity, alignment: .center)
                .zIndex(22)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // MARK: - 6. In-Discord Tans Inspector Overlay
            if showTansInspector {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.nokoFluidSpring) {
                            showTansInspector = false
                        }
                    }
                    .zIndex(24)

                TansInspectorView(isPresented: $showTansInspector)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(25)
            }

            // MARK: - 6b. Bookmarks / Saved Messages Drawer Overlay (⌘⇧B)
            if showBookmarksDrawer {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.nokoFluidSpring) {
                            showBookmarksDrawer = false
                        }
                    }
                    .zIndex(26)

                BookmarksDrawerView(isPresented: $showBookmarksDrawer, onOpenURL: { url in
                    browser.openURL(url)
                })
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(27)
            }

            // MARK: - 7. Spotlight / Raycast Liquid Glass Command Palette (⌘K)
            if showQuickSwitcher {
                Color.black.opacity(0.35)
                    .background(.ultraThinMaterial.opacity(0.3))
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.nokoSnappySpring) {
                            showQuickSwitcher = false
                        }
                    }
                    .zIndex(29)

                CommandPaletteView(
                    isPresented: $showQuickSwitcher,
                    onOpenDownloads: {
                        showDownloadsSheet = true
                    },
                    onOpenTutorial: {
                        withAnimation(.nokoFluidSpring) {
                            showWelcomeTutorial = true
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 90)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.95, anchor: .top).combined(with: .opacity),
                    removal: .scale(scale: 0.97, anchor: .top).combined(with: .opacity)
                ))
                .zIndex(30)
            }

            // MARK: - 8. Welcome Tutorial Modal (First-launch or Quick Selector)
            if showWelcomeTutorial {
                WelcomeTutorialView(isPresented: $showWelcomeTutorial)
                    .zIndex(35)
            }

            // MARK: - 9. Native Media Lightbox Overlay (Zero-heap out-of-process media preview)
            if let mediaURL = activeMediaURL {
                NativeMediaLightboxView(mediaURL: mediaURL, isVideo: activeMediaIsVideo) {
                    withAnimation(.nokoFluidSpring) {
                        activeMediaURL = nil
                    }
                }
                .zIndex(40)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.96).combined(with: .opacity),
                    removal: .scale(scale: 0.98).combined(with: .opacity)
                ))
            }
        }
        .animation(.nokoFluidSpring, value: showTansInspector)
        .animation(.nokoFluidSpring, value: showBookmarksDrawer)
        .animation(.nokoSnappySpring, value: showQuickSwitcher)
        .animation(.nokoFluidSpring, value: showWelcomeTutorial)
        .animation(.nokoFluidSpring, value: activeMediaURL != nil)
        .animation(.nokoSnappySpring, value: browser.isInCall)
        .onAppear {
            if !hasSeenWelcomeTutorial {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation(.nokoFluidSpring) {
                        showWelcomeTutorial = true
                    }
                }
            }
            browser.onOpenMedia = { url, isVideo in
                withAnimation(.nokoFluidSpring) {
                    activeMediaURL = url
                    activeMediaIsVideo = isVideo
                }
            }
            browser.onOpenTutorial = {
                withAnimation(.nokoFluidSpring) {
                    showWelcomeTutorial = true
                }
            }
            browser.onToggleTans = {
                withAnimation(.nokoFluidSpring) {
                    showTansInspector.toggle()
                }
            }
            browser.onToggleQuickSwitcher = {
                withAnimation(.nokoSnappySpring) {
                    showQuickSwitcher.toggle()
                }
            }
            browser.onToggleBookmarks = {
                withAnimation(.nokoFluidSpring) {
                    showBookmarksDrawer.toggle()
                }
            }
            browser.onSaveBookmark = { bookmark in
                withAnimation(.nokoSnappySpring) {
                    bookmarkToast = "Saved message from @\(bookmark.authorName) to Bookmarks"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(.nokoSnappySpring) {
                        bookmarkToast = nil
                    }
                }
            }
        }
        .focusedSceneValue(\.nokoCordQuickSwitcher, $showQuickSwitcher)
        .focusedSceneValue(\.nokoCordBookmarks, $showBookmarksDrawer)
        .focusedSceneValue(\.nokoCordHome, {
            withAnimation(.nokoFluidSpring) {
                showTansInspector.toggle()
            }
        })
        .background(WindowLifetimeObserver {
            showQuickSwitcher = false
            showTansInspector = false
            showWelcomeTutorial = false
            activeMediaURL = nil
        }.frame(width: 0, height: 0))
        .sheet(isPresented: $showDownloadsSheet) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { showDownloadsSheet = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding()
                BrowserSettingsView()
            }
            .frame(width: 600, height: 500)
        }
        .nokoCordAppearance()
    }
}

/// Native Liquid Glass Floating Voice Call HUD (Sonoma/Sequoia dynamic capsule).
struct NativeVoiceHUD: View {
    @Environment(ActiveBrowserEngine.self) private var browser

    var body: some View {
        HStack(spacing: 8) {
            // Pulsing Call Indicator
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(browser.isMicrophoneMuted ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    if !browser.isMicrophoneMuted {
                        Circle()
                            .stroke(Color.green.opacity(0.4), lineWidth: 2)
                            .frame(width: 14, height: 14)
                    }
                }

                Text(browser.isMicrophoneMuted ? "Muted" : "Voice Connected")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(browser.isMicrophoneMuted ? .orange : .primary)
            }
            .padding(.leading, 4)

            // Mute / Unmute Button
            Button {
                browser.toggleMicrophoneMute()
            } label: {
                Image(systemName: browser.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(browser.isMicrophoneMuted ? Color.orange : Color.primary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help(browser.isMicrophoneMuted ? "Unmute Microphone (⌘⇧M)" : "Mute Microphone (⌘⇧M)")

            // End Call Button
            Button {
                browser.disconnectCall()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.red, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Disconnect Call (⌘⇧D)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 12, y: 4)
    }
}

private struct BrowserHostView: NSViewRepresentable {
    let view: NSView
    let visible: Bool
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.isHidden = !visible }
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // The app owns this view. Closing a window is not logout or teardown.
    }
}

struct BrowserSettingsView: View {
    @Environment(ActiveBrowserEngine.self) private var browser
    var body: some View {
        VStack(spacing: 0) {
            NokoPageHeader(title: "Downloads", subtitle: "Your transfers, all in one place.", symbol: "arrow.down.circle")
            if let error = browser.downloads.error {
                HStack { Text(error).font(.callout); Spacer(); Button("Dismiss") { browser.downloads.dismissError() } }
                    .padding(16).background(Color.orange.opacity(0.08), in: .rect(cornerRadius: 12)).padding(.horizontal, 28)
            }
            if browser.downloads.records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
                    Text("No downloads yet").font(.title3.weight(.semibold))
                    Text("Downloads from Discord appear here during this session.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(browser.downloads.records) { item in
                            HStack(spacing: 14) {
                                Image(systemName: item.status == .complete ? "checkmark.circle" : "doc")
                                    .font(.title2).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.name).font(.headline).lineLimit(1)
                                    switch item.status {
                                    case .choosing: Text("Choose a destination").font(.caption)
                                    case .downloading: ProgressView(value: item.fraction)
                                    case .complete: Text("Completed").font(.caption).foregroundStyle(.secondary)
                                    case .cancelled: Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                                    case .failed: Text("Failed").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if item.status == .choosing || item.status == .downloading {
                                    Button("Cancel") { browser.downloads.cancel(item.id) }
                                }
                            }
                            .padding(18)
                            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 14))
                        }
                    }
                    .padding(28)
                }
            }
        }
    }
}

struct DiscordSessionPrivacySection: View {
    var body: some View {
        Section("Discord session") { DiscordSessionControls() }
    }
}

struct DiscordSessionControls: View {
    @Environment(ActiveBrowserEngine.self) private var browser
    @State private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Clear saved session data to sign out of Discord on this Mac. Files you have downloaded are kept.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Clear Discord session…", role: .destructive) { confirmClear = true }
                .buttonStyle(.bordered).foregroundStyle(.red)
                .disabled(browser.lifecycle.phase == .clearing)
            if browser.lifecycle.phase == .clearing { ProgressView("Clearing session data") }
            Divider()
            Label("Camera, microphone and screen sharing require your permission.", systemImage: "lock")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .confirmationDialog("Clear your Discord session?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear session", role: .destructive) { Task { await browser.clearProfile() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This ends active calls and playback, signs you out of Discord, and removes saved session data. Downloaded files are kept.")
        }
    }
}
