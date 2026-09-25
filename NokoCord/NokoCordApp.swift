//
//  NokoCordApp.swift
//  NokoCord
//
//  Maintained by shiikatan.
//

import SwiftUI

@main
struct NokoCordApp: App {
    @NSApplicationDelegateAdaptor(NokoApplicationDelegate.self) private var applicationDelegate
    @State private var browser: ActiveBrowserEngine
    @State private var tans: TanManager
    @State private var handledStartup = false

    init() {
        let manager = TanManager()
        _tans = State(initialValue: manager)
        _browser = State(initialValue: ActiveBrowserEngine(tans: manager))
    }

    @AppStorage("showMenuBar") private var showMenuBar = false

    var body: some Scene {
        Window("NokoCord", id: "main") {
            NokoRootView()
                .environment(browser)
                .environment(tans)
                .frame(minWidth: 960, minHeight: 600)
                .task {
                    guard !handledStartup else { return }
                    handledStartup = true
                    browser.openDiscord()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands { NokoCordCommands(browser: browser) }
        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent(browser: browser, tans: tans)
        } label: {
            NokoMenuBarIcon(unreadCount: browser.unreadCount, isInCall: browser.isInCall)
        }
        Settings {
            SettingsView()
                .environment(browser)
                .environment(tans)
        }
    }
}

private struct NokoMenuBarIcon: View {
    let unreadCount: Int
    let isInCall: Bool
    @State private var gamePresence = GamePresenceService.shared

    // Copy the shared artwork before sizing; never mutate the asset-catalog image.
    private static let image: NSImage = {
        let image = (NSImage(named: "NokoMark")?.copy() as? NSImage) ?? NSImage(size: NSSize(width: 18, height: 18))
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }()
    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: Self.image).renderingMode(.original)
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            } else if isInCall {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            } else if gamePresence.activePresence != nil {
                Circle()
                    .fill(Color.purple)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityLabel(unreadCount > 0 ? "NokoCord (\(unreadCount) unread)" : "NokoCord")
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
        CommandGroup(replacing: .help) {
            Button("NokoCord Tour & Shortcuts") {
                openWindow(id: "main")
                browser.onOpenTutorial?()
            }
            .keyboardShortcut("/", modifiers: .command)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Show NokoCord") { openWindow(id: "main") }
        }
        CommandGroup(after: .textEditing) {
            Button("Quick Selector") { quickSwitcher?.wrappedValue = true }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(quickSwitcher == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Toggle Tans") {
                openWindow(id: "main")
                browser.onToggleTans?()
            }
                .keyboardShortcut("t", modifiers: .command)
            Button("Reload Discord") { browser.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!browser.lifecycle.isVisible || browser.lifecycle.phase == .clearing)
            Divider()
            Button(browser.isMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone") {
                browser.toggleMicrophoneMute()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!browser.isInCall)

            Button("Disconnect Voice Call") {
                browser.disconnectCall()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!browser.isInCall)
            Divider()
            Button("Back") { browser.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!browser.canGoBack)
            Button("Forward") { browser.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!browser.canGoForward)
            Divider()
            Button("Zoom In") { browser.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { browser.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { browser.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}

@MainActor
private final class NokoApplicationDelegate: NSObject, NSApplicationDelegate {
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
    let browser: ActiveBrowserEngine
    let tans: TanManager
    @State private var gamePresence = GamePresenceService.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let edition = EditionIdentity.current {
            Text("\(edition.name) (\(edition.publicVersion))")
        } else {
            Text("NokoCord")
        }

        if let presence = gamePresence.activePresence {
            Text("🎮 Playing \(presence.name)")
        }

        if browser.unreadCount > 0 {
            Text("● \(browser.unreadCount) Unread Mention\(browser.unreadCount == 1 ? "" : "s")")
        }

        if browser.isInCall {
            Text(browser.isMicrophoneMuted ? "🎤 Microphone Muted" : "🟢 Voice Call Active")
        }

        Divider()

        Button("Open Discord") {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
        }

        Button("Command Palette…") {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
            browser.onToggleQuickSwitcher?()
        }
        .keyboardShortcut("k", modifiers: .command)

        Button("Toggle Tans Inspector") {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
            browser.onToggleTans?()
        }
        .keyboardShortcut("t", modifiers: .command)

        if browser.isInCall {
            Divider()

            Button(browser.isMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone") {
                browser.toggleMicrophoneMute()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Button("Disconnect Voice Call") {
                browser.disconnectCall()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        Divider()

        Button("Reload Discord") {
            browser.reload()
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!browser.lifecycle.isVisible || browser.lifecycle.phase == .clearing)

        Button(tans.safeMode ? "Disable Safe Mode" : "Enable Safe Mode") {
            tans.setSafeMode(!tans.safeMode)
        }

        Divider()

        SettingsLink()

        Divider()

        Button("Quit NokoCord") {
            NokoApplicationDelegate.requestTermination()
        }
        .keyboardShortcut("q")
    }
}
