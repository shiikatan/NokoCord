import Foundation
import WebKit

/// Maomao's Discord-owned surfaces. No native controls or Discord application
/// internals are replaced; the isolated script only installs a stylesheet.
@MainActor
enum MaomaoDiscordPresentation {
    static let world = WKContentWorld.world(name: "NokoCord.Maomao.Presentation")
    nonisolated static let preferenceKey = "maomaoNokoGlass"
    private static let scriptMarker = "/* NokoCord.Maomao.Presentation */"

    nonisolated static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? true
    }

    static func install(on controller: WKUserContentController, safeMode: Bool = false,
                        editionID: String? = EditionIdentity.current?.id,
                        enabled: Bool = isEnabled()) {
        guard editionID == "maomao" else { return }
        // WebKit has no individual user-script removal API. Preserve every
        // other script exactly while replacing this presentation's registration.
        let retained = controller.userScripts.filter { !$0.source.hasPrefix(scriptMarker) }
        if retained.count != controller.userScripts.count {
            controller.removeAllUserScripts()
            retained.forEach(controller.addUserScript)
        }
        guard !safeMode, let source = source(enabled: enabled) else { return }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                             forMainFrameOnly: true, in: world))
    }

    static func apply(to view: WKWebView, safeMode: Bool,
                      editionID: String? = EditionIdentity.current?.id,
                      enabled: Bool = isEnabled()) {
        guard editionID == "maomao", let source = source(enabled: enabled && !safeMode) else { return }
        // Exiting Safe Mode can leave the existing document open. Registration
        // is idempotent and checks its own frame/origin before touching the DOM.
        view.evaluateJavaScript(source, in: nil, in: world) { _ in }
    }

    static func source(enabled: Bool = true) -> String? {
        guard let resourceBody else { return nil }
        return "\(scriptMarker)\n(() => { const presentationEnabled = \(enabled);\n\(resourceBody)\n})();"
    }

    private static let resourceBody: String? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let cssURL = bundle.url(forResource: "MaomaoDiscord", withExtension: "css"),
              let scriptURL = bundle.url(forResource: "MaomaoDiscord", withExtension: "js"),
              let css = try? String(contentsOf: cssURL, encoding: .utf8),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              let data = try? JSONEncoder().encode(css),
              let literal = String(data: data, encoding: .utf8) else { return nil }
        return "const stylesheet = \(literal);\n\(script)"
    }()
}
