import SwiftUI
import AppKit

extension EnvironmentValues {
    /// Hidden workspaces retain their view state without doing background work.
    @Entry var nokoWorkspaceVisible = true
}

/// Retain SwiftUI state while removing a covered workspace from AppKit's
/// tooltip and tracking-area lookup. Opacity and SwiftUI hit testing alone
/// leave native help regions active behind the Discord web view.
struct NokoRetainedWorkspace<Content: View>: NSViewRepresentable {
    let visible: Bool
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let view = NSHostingView(rootView: root(environment: context.environment))
        view.sizingOptions = []
        view.isHidden = !visible
        return view
    }

    func updateNSView(_ view: NSHostingView<AnyView>, context: Context) {
        view.rootView = root(environment: context.environment)
        view.isHidden = !visible
    }

    private func root(environment: EnvironmentValues) -> AnyView {
        AnyView(content().environment(\.self, environment))
    }
}
