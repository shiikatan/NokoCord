import AppKit

@main
struct WorkspaceToolbarChecks {
    @MainActor
    static func settle() async {
        for _ in 0..<6 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }

    @MainActor
    static func main() async {
        _ = NSApplication.shared
        // Unshown disposable window: no interaction with the user's app/session.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        let toolbar = NSToolbar(identifier: "fixture")
        window.toolbar = toolbar
        await settle()
        precondition(toolbar.isVisible, "Fixture must begin with a visible toolbar")
        let view = WorkspaceWindowToolbarVisibility.VisibilityView(hidden: true)
        window.contentView?.addSubview(view)
        await settle()
        precondition(!toolbar.isVisible, "Hidden workspace must collapse the toolbar")
        // Verify visibility and controls here. Reclaimed titlebar space is
        // checked in the visible app rather than this unshown window fixture.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            precondition(window.standardWindowButton(button)?.isHidden == false,
                         "Hiding the toolbar must retain every native window control")
        }

        toolbar.isVisible = true
        await settle()
        precondition(!toolbar.isVisible, "Restored toolbar must be hidden again")

        let replacement = NSToolbar(identifier: "replacement")
        window.toolbar = replacement
        await settle()
        precondition(!replacement.isVisible, "Replacement toolbar must follow the workspace")

        replacement.isVisible = true
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        await settle()
        precondition(!replacement.isVisible, "Fullscreen restoration must not expose hidden toolbar")
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            precondition(window.standardWindowButton(button)?.isHidden == false,
                         "Fullscreen notification handling must not hide native window controls")
        }

        view.setHidden(false)
        await settle()
        precondition(replacement.isVisible, "Enabled NokoBar must show the native toolbar")
        view.setHidden(true)
        view.setHidden(false)
        await settle()
        precondition(replacement.isVisible, "Rapid toggles must preserve the latest preference")

        view.stopObserving()
        replacement.isVisible = false
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        await settle()
        precondition(!replacement.isVisible, "Detached observer must stop enforcing toolbar state")
        window.toolbar = nil
        view.removeFromSuperview()
        print("PASS toolbar restoration, replacement, fullscreen notifications, all native window controls, rapid toggles and teardown")
    }
}
