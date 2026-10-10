import AppKit
import SwiftUI

/// Hide only the toolbar, leaving standard window controls to macOS. SwiftUI's
/// retained NavigationSplitView and fullscreen transitions can restore or replace
/// the toolbar, so observe those changes instead of polling the window.
struct WorkspaceWindowToolbarVisibility: NSViewRepresentable {
    let hidden: Bool
    func makeNSView(context: Context) -> VisibilityView { VisibilityView(hidden: hidden) }
    func updateNSView(_ view: VisibilityView, context: Context) { view.setHidden(hidden) }
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) { view.stopObserving() }

    final class VisibilityView: NSView {
        private var toolbarHidden: Bool
        private var revision = 0
        private var observing = false
        private var windowObservation: NSKeyValueObservation?
        private var visibilityObservation: NSKeyValueObservation?
        private weak var observedToolbar: NSToolbar?

        init(hidden: Bool) { toolbarHidden = hidden; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("Not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            observing = true
            windowObservation = window.observe(\.toolbar, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.observeToolbar() }
            }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(fullscreenChanged), name: name, object: window)
            }
            observeToolbar()
        }

        func stopObserving() {
            observing = false
            revision += 1
            windowObservation = nil
            visibilityObservation = nil
            observedToolbar = nil
            NotificationCenter.default.removeObserver(self)
        }

        func setHidden(_ hidden: Bool) { toolbarHidden = hidden; reconcile() }

        private func observeToolbar() {
            guard observing else { return }
            guard observedToolbar !== window?.toolbar else { reconcile(); return }
            visibilityObservation = nil
            observedToolbar = window?.toolbar
            visibilityObservation = observedToolbar?.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.reconcile() }
            }
            reconcile()
        }

        @objc private func fullscreenChanged() { observeToolbar() }

        private func reconcile() {
            guard observing else { return }
            revision += 1
            let expectedRevision = revision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.observing, self.revision == expectedRevision,
                      let toolbar = self.window?.toolbar,
                      toolbar.isVisible == self.toolbarHidden else { return }
                toolbar.isVisible = !self.toolbarHidden
            }
        }
    }
}
