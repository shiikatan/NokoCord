//
//  NokoCordApp.swift
//  NokoCord
//
//  Maintained by shiikatan.
//

import SwiftUI
import Observation

@main
struct NokoCordApp: App {
    @NSApplicationDelegateAdaptor(NokoApplicationDelegate.self) private var applicationDelegate
    @State private var startup = NokoStartupCoordinator()

    var body: some Scene {
        Window("NokoCord", id: "main") {
            Group {
                if let context = startup.context {
                    NokoRootView()
                        .environment(context.browser)
                        .environment(context.tans)
                        .environment(context.activityRuntime.appleMusicPresence)
                        .task { startup.openDiscordOnLaunchIfNeeded(context) }
                } else {
                    NokoStartupRecoveryView(
                        isPreparing: startup.isPreparing,
                        errorMessage: startup.errorMessage,
                        retry: { Task { await startup.start() } }
                    )
                }
            }
            .frame(minWidth: 960, minHeight: 600)
            .task { await startup.start() }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            if let context = startup.context {
                NokoCordCommands(browser: context.browser)
            } else {
                NokoStartupRecoveryCommands()
            }
        }
        MenuBarExtra(isInserted: Binding(
            get: { startup.context != nil && startup.showMenuBar },
            set: { startup.setMenuBarVisible($0) }
        )) {
            if startup.context != nil { MenuBarContent() }
        } label: {
            NokoMenuBarIcon()
        }
        Settings {
            Group {
                if let context = startup.context {
                    SettingsView()
                        .environment(context.browser)
                        .environment(context.tans)
                        .environment(context.activityRuntime.appleMusicPresence)
                } else {
                    NokoStartupRecoveryView(
                        isPreparing: startup.isPreparing,
                        errorMessage: startup.errorMessage,
                        retry: { Task { await startup.start() } }
                    )
                }
            }
        }
    }
}

@MainActor
private final class NokoAppContext {
    let tans: TanManager
    let browser: ActiveBrowserEngine
    let activityRuntime: NokoActivityRuntime
    var handledInitialDiscordOpen = false

    init(tans: TanManager, browser: ActiveBrowserEngine, activityRuntime: NokoActivityRuntime) {
        self.tans = tans
        self.browser = browser
        self.activityRuntime = activityRuntime
    }
}

@MainActor @Observable
private final class NokoStartupCoordinator {
    private(set) var context: NokoAppContext?
    private(set) var errorMessage: String?
    private(set) var isPreparing = true
    private(set) var showMenuBar = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?

    func start() async {
        guard context == nil, !started else { return }
        started = true
        isPreparing = true
        errorMessage = nil
        do {
            let paths = try ManualUpdateStartupRecovery.currentPaths()
            let receipt = try await ManualUpdateStartupRecovery.prepare(
                runningAppURL: Bundle.main.bundleURL,
                paths: paths,
                arguments: ProcessInfo.processInfo.arguments
            )
            let tans = TanManager()
            let browser = ActiveBrowserEngine(tans: tans)
            let activityRuntime = NokoActivityRuntime()
            if let receipt { try ManualUpdateStartupRecovery.complete(receipt) }
            let readyContext = NokoAppContext(tans: tans, browser: browser, activityRuntime: activityRuntime)
            NokoApplicationDelegate.configure(runtime: activityRuntime, tanManager: tans)
            context = readyContext
            showMenuBar = UserDefaults.standard.bool(forKey: "showMenuBar")
            observeMenuBarPreference()
        } catch {
            errorMessage = error.localizedDescription
        }
        isPreparing = false
        started = false
    }

    func openDiscordOnLaunchIfNeeded(_ readyContext: NokoAppContext) {
        guard context === readyContext, !readyContext.handledInitialDiscordOpen else { return }
        readyContext.handledInitialDiscordOpen = true
        if UserDefaults.standard.bool(forKey: "openDiscordOnLaunch"), !readyContext.tans.safeMode {
            readyContext.browser.openDiscord()
        }
    }

    func setMenuBarVisible(_ visible: Bool) {
        guard context != nil else { return }
        showMenuBar = visible
        UserDefaults.standard.set(visible, forKey: "showMenuBar")
    }

    private func observeMenuBarPreference() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.context != nil else { return }
                self.showMenuBar = UserDefaults.standard.bool(forKey: "showMenuBar")
            }
        }
    }
}

private struct NokoStartupRecoveryView: View {
    let isPreparing: Bool
    let errorMessage: String?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if isPreparing {
                ProgressView("Preparing NokoCord…")
            } else if let errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("NokoCord could not finish startup")
                    .font(.title2.bold())
                Text(errorMessage)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
                HStack {
                    Button("Retry", action: retry)
                        .buttonStyle(.borderedProminent)
                    Button("Quit NokoCord") { NokoApplicationDelegate.requestTermination() }
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NokoStartupRecoveryCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("Quit NokoCord") { NokoApplicationDelegate.requestTermination() }
                .keyboardShortcut("q")
        }
    }
}

private struct NokoMenuBarIcon: View {
    // Copy the shared artwork before sizing; never mutate the asset-catalog image.
    private static let image: NSImage = {
        let image = (NSImage(named: "NokoMark")?.copy() as? NSImage) ?? NSImage(size: NSSize(width: 18, height: 18))
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }()
    var body: some View {
        Image(nsImage: Self.image).renderingMode(.original).accessibilityLabel("NokoCord")
    }
}

private struct QuickSwitcherFocusKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct HomeActionFocusKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var nokoCordHome: (() -> Void)? {
        get { self[HomeActionFocusKey.self] }
        set { self[HomeActionFocusKey.self] = newValue }
    }
    var nokoCordQuickSwitcher: Binding<Bool>? {
        get { self[QuickSwitcherFocusKey.self] }
        set { self[QuickSwitcherFocusKey.self] = newValue }
    }
}

private struct NokoCordCommands: Commands {
    let browser: ActiveBrowserEngine
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.nokoCordQuickSwitcher) private var quickSwitcher
    @FocusedValue(\.nokoCordHome) private var goHome

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About NokoCord") {
                var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
                if let edition = EditionIdentity.current {
                    options[.applicationVersion] = edition.publicVersion
                    options[.credits] = NSAttributedString(
                        string: "Edition: \(edition.name)\nMaintainer: \(edition.maintainer)"
                    )
                }
                NSApp.orderFrontStandardAboutPanel(options: options)
            }
        }
        CommandGroup(replacing: .appTermination) {
            Button("Quit NokoCord") { NokoApplicationDelegate.requestTermination() }
                .keyboardShortcut("q")
        }
        CommandGroup(after: .windowArrangement) {
            Button("Show NokoCord") { openWindow(id: "main") }
        }
        CommandGroup(after: .textEditing) {
            Button("Quick switcher") { quickSwitcher?.wrappedValue = true }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(quickSwitcher == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Open Discord") { openWindow(id: "main"); browser.openDiscord() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Home") {
                if let goHome { goHome() }
                else { browser.showHome(); openWindow(id: "main") }
            }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Reload Discord") { browser.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!browser.lifecycle.isVisible || browser.lifecycle.phase == .clearing)

        }
    }
}

@MainActor
private final class NokoApplicationDelegate: NSObject, NSApplicationDelegate {
    private var activityRuntime: NokoActivityRuntime?
    private var didFinishLaunching = false
    private var didStartActivity = false
    private static weak var activeDelegate: NokoApplicationDelegate?
    private static var configuredRuntime: NokoActivityRuntime?
    private static var configuredTanManager: TanManager?

    static func configure(runtime: NokoActivityRuntime, tanManager: TanManager) {
        configuredRuntime = runtime
        configuredTanManager = tanManager
        activeDelegate?.startConfiguredRuntimeIfReady()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.activeDelegate = self
        didFinishLaunching = true
        startConfiguredRuntimeIfReady()
        // On a fresh install SwiftUI can create the single Window scene without
        // ordering it on screen. Present that existing window once at launch.
        DispatchQueue.main.async {
            guard let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }),
                  !main.isVisible else { return }
            main.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func startConfiguredRuntimeIfReady() {
        guard didFinishLaunching, !didStartActivity,
              let runtime = Self.configuredRuntime,
              let tans = Self.configuredTanManager else { return }
        didStartActivity = true
        activityRuntime = runtime
        if ProcessInfo.processInfo.arguments.contains("--nokocord-activity-smoke") {
            runtime.startSmokeTest()
        } else {
            runtime.start(tanManager: tans)
        }
    }
    static func requestTermination() {
        // AppKit may defer its standard termination action while a sheet is
        // modal. Clear owned presentation state before invoking that action.
        NotificationCenter.default.post(name: .nokoCloseTransientUI, object: nil)
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let main = sender.windows.first(where: { $0.identifier?.rawValue == "main" }) else {
            return true // Let SwiftUI recreate its scene if no retained window remains.
        }
        main.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Tan dialogs contain no unsaved document. They must not defer an explicit
        // Quit request or survive it as detached windows.
        for window in sender.windows where window.sheetParent == nil {
            dismissSheets(of: window)
        }
        if let activityRuntime {
            Task {
                await activityRuntime.stop()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
    private func dismissSheets(of window: NSWindow) {
        for sheet in window.sheets {
            dismissSheets(of: sheet)
            window.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
        }
    }
}

private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("NokoCord")
        Button("Open NokoCord") {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) { window.makeKeyAndOrderFront(nil) }
            else { openWindow(id: "main") }
        }
        SettingsLink()
        Divider()
        Button("Quit NokoCord") { NokoApplicationDelegate.requestTermination() }.keyboardShortcut("q")
    }
}
