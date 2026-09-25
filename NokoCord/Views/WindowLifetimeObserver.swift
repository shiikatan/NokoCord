import AppKit
import SwiftUI

extension Notification.Name {
    static let nokoCloseTransientUI = Notification.Name("NokoCord.closeTransientUI")
}

@MainActor
final class PresentationWindowReference {
    weak var window: NSWindow?
}

/// Ties transient SwiftUI presentations to their actual owning window.
/// Closing a Window scene may hide it without destroying its SwiftUI state.
struct WindowLifetimeObserver: NSViewRepresentable {
    let reference: PresentationWindowReference?
    let onClose: () -> Void
    init(reference: PresentationWindowReference? = nil, onClose: @escaping () -> Void) {
        self.reference = reference; self.onClose = onClose
    }
    func makeNSView(context: Context) -> ObserverView { ObserverView(reference: reference, onClose: onClose) }
    func updateNSView(_ view: ObserverView, context: Context) { view.onClose = onClose }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stopObserving() }

    final class ObserverView: NSView {
        var onClose: () -> Void
        let reference: PresentationWindowReference?
        private weak var owner: NSWindow?
        init(reference: PresentationWindowReference?, onClose: @escaping () -> Void) {
            self.reference = reference; self.onClose = onClose; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("Not used") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            owner = window
            reference?.window = window
            NotificationCenter.default.addObserver(self, selector: #selector(closing), name: NSWindow.willCloseNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(closing), name: NSApplication.willTerminateNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(closing), name: .nokoCloseTransientUI, object: nil)
        }
        func stopObserving() { NotificationCenter.default.removeObserver(self); owner = nil; reference?.window = nil }
        @objc private func closing() {
            onClose()
            if let owner { endSheets(of: owner) }
        }
        private func endSheets(of window: NSWindow) {
            for sheet in window.sheets {
                endSheets(of: sheet)
                window.endSheet(sheet, returnCode: .cancel)
                sheet.orderOut(nil)
            }
        }
    }
}
