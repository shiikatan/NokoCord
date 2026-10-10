import SwiftUI
import WebKit

struct NokoRootView: View {
    @Environment(ActiveBrowserEngine.self) private var browser
    @Environment(MaoListModule.self) private var maolist
    @AppStorage(MaomaoWorkspaceAppearance.barPreferenceKey) private var showNokoBar = true
    @State private var selection: NokoDestination = .home
    @State private var showQuickSwitcher = false
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        ZStack {
            // Keep MaoList's view state and scroll position while Discord covers it.
            // Its tasks and artwork are gated by workspace visibility below.
            if !browser.lifecycle.isVisible || selection == .maolist {
                ContentView(selection: $selection, showQuickSwitcher: $showQuickSwitcher)
                    .environment(\.nokoWorkspaceVisible, !browser.lifecycle.isVisible)
                    .opacity(browser.lifecycle.isVisible ? 0 : 1)
                    .allowsHitTesting(!browser.lifecycle.isVisible)
                    .accessibilityHidden(browser.lifecycle.isVisible)
            }
            if let view = browser.view {
                VStack(spacing: 0) {
                    if EditionIdentity.current?.id != "maomao" || showNokoBar {
                        workspaceBar
                    }
                    if let notice = browser.notice {
                        HStack { Text(notice).font(.callout); Spacer(); Button("Dismiss") { browser.dismissNotice() } }.padding(10)
                    }
                    if browser.lifecycle.phase == .failed || browser.lifecycle.phase == .crashed {
                        ContentUnavailableView {
                            Label(browser.lifecycle.phase == .crashed ? "Discord needs to reopen" : "Discord could not load", systemImage: "network.slash")
                        } description: {
                            Text("Check your connection, then reload. Reloading interrupts any active call.")
                        } actions: { Button("Reload Discord") { browser.reload() } }
                    }
                    BrowserHostView(view: view, visible: browser.lifecycle.isVisible)
                        .id(ObjectIdentifier(view))
                }
                .environment(\.nokoWorkspaceVisible, browser.lifecycle.isVisible)
                .opacity(browser.lifecycle.isVisible ? 1 : 0)
                .allowsHitTesting(browser.lifecycle.isVisible)
                .accessibilityHidden(!browser.lifecycle.isVisible)
            }
        }
        .onAppear { [browser, maolist, workspaceSelection = $selection] in
            browser.onSwitchToMaoList = { [weak browser, weak maolist, workspaceSelection] in
                guard maolist?.enabled == true else { return }
                workspaceSelection.wrappedValue = .maolist; browser?.showHome()
            }
            browser.setMaoListSwitchEnabled(maolist.enabled)
        }
        .onChange(of: maolist.enabled) { _, enabled in browser.setMaoListSwitchEnabled(enabled) }
        .focusedSceneValue(\.nokoCordQuickSwitcher, $showQuickSwitcher)
        .focusedSceneValue(\.nokoCordSwitchApp, maolist.enabled ? {
            if !browser.lifecycle.isVisible && selection == .maolist { browser.openDiscord() }
            else { selection = .maolist; browser.showHome() }
        } : nil)
        .focusedSceneValue(\.nokoCordHome, { selection = .home; browser.showHome() })
        .background(WindowLifetimeObserver { showQuickSwitcher = false }.frame(width: 0, height: 0))
        .sheet(isPresented: $showQuickSwitcher) {
            NokoQuickSwitcher { destination in
                switch destination {
                case .discord: browser.openDiscord()
                case .settings: openSettings()
                default: selection = destination; browser.showHome()
                }
            }
        }
        .navigationTitle(browser.lifecycle.isVisible ? "NokoCord" : selection == .home ? "" : selection.title)
        .toolbar(removing: browser.lifecycle.isVisible || selection == .maolist ? .title : nil)
        .toolbar(removing: browser.lifecycle.isVisible ? .sidebarToggle : nil)
        .background(WorkspaceWindowToolbarVisibility(
            hidden: browser.lifecycle.isVisible || selection == .maolist
        ).frame(width: 0, height: 0))
        .nokoCordAppearance()
    }
    // NokoBar is a flat content row. The native toolbar stays hidden throughout
    // Discord so NavigationSplitView cannot add a second row or sidebar button.
    private var workspaceBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Button("Home", systemImage: "house") { selection = .home; browser.showHome() }
                    .help("Home (⇧⌘H)")
                Button("Back", systemImage: "chevron.left") { browser.goBack() }
                    .disabled(!browser.canGoBack)
                    .help("Previous Discord page")
                    .accessibilityHint("Returns to the previous Discord page")
            }.labelStyle(.iconOnly).controlSize(.large)
            Divider().frame(height: 20)
            Image("NokoMark").renderingMode(.original).resizable().scaledToFit()
                .frame(width: 24, height: 24).clipShape(.rect(cornerRadius: 6)).accessibilityHidden(true)
            Text("NokoCord").font(.headline)
            if browser.lifecycle.phase == .loading {
                ProgressView(value: browser.progress).frame(width: 72).accessibilityLabel("Discord loading")
            }
            Spacer(minLength: 16)
            HStack(spacing: 12) {
                Button("Quick switcher", systemImage: "command") { showQuickSwitcher = true }
                    .help("Quick switcher (⌘K)")
                Button("Downloads", systemImage: "arrow.down.circle") { selection = .downloads; browser.showHome() }
                    .help("Downloads")
                Button("Reload", systemImage: "arrow.clockwise") { browser.reload() }
                    .help("Reload Discord (⌘R)")
                    .accessibilityHint("Reloads Discord and may interrupt an active call")
                SettingsLink { Label("Settings", systemImage: "gearshape") }.help("Settings")
            }.labelStyle(.iconOnly).controlSize(.large)
        }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 10)
            .modifier(WorkspaceBarSurface())
    }
}

private struct WorkspaceBarSurface: ViewModifier {
    func body(content: Content) -> some View {
        if EditionIdentity.current?.id == "maomao" {
            content.background(Color(nsColor: .controlBackgroundColor))
        } else {
            content.modifier(NokoSurface(cornerRadius: 0))
        }
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
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 14))
                        }
                    }.padding(28)
                }
            }
        }
    }
}

struct DiscordSocialAccountSection: View {
    @Environment(DiscordSocialAccountService.self) private var account
    @State private var connecting = false
    @State private var disconnecting = false

    var body: some View {
        Section("Discord activity") {
            VStack(alignment: .leading, spacing: 10) {
                Label(statusTitle, systemImage: statusSymbol)
                    .font(.headline)
                    .accessibilityLabel("Discord activity: \(statusTitle)")

                Text(statusDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if EditionIdentity.current?.id == "maomao" {
                    Label("Your Discord authorization is saved in macOS Keychain. After an update, macOS may ask permission to restore it. Any password requested in that dialog is handled by macOS.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let warning = account.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 10) {
                    if showsConnect {
                        Button(connectTitle) {
                            connecting = true
                            Task {
                                await account.authorize()
                                connecting = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(connecting || disconnecting || account.authorizationIsQuarantined)
                    }

                    if showsDisconnect {
                        Button(disconnectTitle, role: .destructive) {
                            disconnecting = true
                            Task {
                                await account.disconnect()
                                disconnecting = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(disconnecting)
                    }

                    if isWaiting || connecting || disconnecting {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Discord activity connection in progress")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var statusTitle: String {
        switch account.state {
        case .signedOut: "Checking saved authorization"
        case .authorizationRequired: "Not connected"
        case .authorizing: "Waiting for Discord authorization"
        case .connecting: "Connecting"
        case .ready: "Connected"
        case .reconnecting: "Reconnecting"
        case .failed: "Connection needs attention"
        }
    }

    private var statusSymbol: String {
        switch account.state {
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle"
        case .authorizationRequired: "person.crop.circle.badge.plus"
        default: "circle.dotted"
        }
    }

    private var statusDescription: String {
        switch account.state {
        case .signedOut:
            "NokoCord is checking Keychain for a saved Discord authorization."
        case .authorizationRequired:
            "Connect your Discord account so NokoCord can publish activity while the Discord desktop app is closed."
        case .authorizing:
            "Complete the Discord authorization in your browser."
        case .connecting, .reconnecting:
            "NokoCord is establishing the activity connection."
        case .ready:
            "NokoCord can publish activity while the Discord desktop app is closed."
        case .failed(let message):
            message
        }
    }

    private var showsConnect: Bool {
        switch account.state {
        case .authorizationRequired, .failed: true
        default: false
        }
    }

    private var showsDisconnect: Bool {
        switch account.state {
        case .authorizing, .connecting, .ready, .reconnecting, .failed: true
        default: false
        }
    }

    private var isWaiting: Bool {
        switch account.state {
        case .signedOut, .authorizing, .connecting, .reconnecting: true
        default: false
        }
    }

    private var connectTitle: String {
        if case .failed = account.state { return "Try Again" }
        return "Connect Discord"
    }

    private var disconnectTitle: String {
        if case .authorizing = account.state { return "Cancel" }
        return disconnecting ? "Disconnecting…" : "Disconnect"
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
    @State private var confirmCache = false
    @State private var clearingCache = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Clear Web & RAM Cache").font(.headline)
                Text("Clear temporary Discord web caches and recreate its web view to release transient memory without signing you out.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Clear & Reload") { confirmCache = true }
                    .buttonStyle(.bordered).tint(.orange)
                    .disabled(browser.lifecycle.phase == .clearing)
                    .confirmationDialog("Clear Web & RAM Cache?", isPresented: $confirmCache, titleVisibility: .visible) {
                        Button("Clear & Reload") {
                            clearingCache = true
                            Task { await browser.clearTemporaryCache(); clearingCache = false }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Discord will reload in a fresh web view and keep your saved sign-in. Active calls and playback will stop.")
                    }
            }
            Divider()
            Text("Clear Discord Session").font(.headline)
            Text("Clear saved session data to sign out of Discord on this Mac. Files you have downloaded are kept.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Clear Discord session…", role: .destructive) { confirmClear = true }
                .buttonStyle(.bordered).foregroundStyle(.red)
                .disabled(browser.lifecycle.phase == .clearing)
            if browser.lifecycle.phase == .clearing {
                ProgressView(clearingCache ? "Refreshing web cache" : "Clearing session data")
            }
            Divider()
            Label("Camera, microphone and screen sharing require your permission.", systemImage: "lock")
                .font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .confirmationDialog("Clear your Discord session?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear session", role: .destructive) { Task { await browser.clearProfile() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This ends active calls and playback, signs you out of Discord, and removes saved session data. Downloaded files are kept.") }
    }
}
