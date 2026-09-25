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
                    if UserDefaults.standard.bool(forKey: "openDiscordOnLaunch"), !tans.safeMode {
                        browser.openDiscord()
                    }
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { NokoCordCommands(browser: browser) }
        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent()
        } label: {
            NokoMenuBarIcon()
        }
        Settings {
            SettingsView()
                .environment(browser)
                .environment(tans)
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
