import SwiftUI
import WebKit

struct NokoRootView: View {
    @Environment(ActiveBrowserEngine.self) private var browser
    @State private var selection: NokoDestination = .home
    @State private var showQuickSwitcher = false
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        ZStack {
            if let view = browser.view {
                VStack(spacing: 0) {
                    workspaceBar
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
                .opacity(browser.lifecycle.isVisible ? 1 : 0)
                .allowsHitTesting(browser.lifecycle.isVisible)
                .accessibilityHidden(!browser.lifecycle.isVisible)
            }
            if !browser.lifecycle.isVisible {
                ContentView(selection: $selection, showQuickSwitcher: $showQuickSwitcher)

            }
        }
        .focusedSceneValue(\.nokoCordQuickSwitcher, $showQuickSwitcher)
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
        .nokoCordAppearance()
    }
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
            HStack(spacing: 9) {
                Image("NokoMark").renderingMode(.original).resizable().scaledToFit()
                    .frame(width: 24, height: 24).clipShape(.rect(cornerRadius: 6)).accessibilityHidden(true)
                Text("Discord").font(.headline)
                if browser.lifecycle.phase == .loading {
                    ProgressView(value: browser.progress).frame(width: 72).accessibilityLabel("Discord loading")
                }
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
            .modifier(NokoSurface(cornerRadius: 0))
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
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .confirmationDialog("Clear your Discord session?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear session", role: .destructive) { Task { await browser.clearProfile() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This ends active calls and playback, signs you out of Discord, and removes saved session data. Downloaded files are kept.") }
    }
}
