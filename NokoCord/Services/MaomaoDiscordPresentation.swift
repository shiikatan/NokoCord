import Foundation
import WebKit

enum NokoGlassStyle: String, CaseIterable, Identifiable, Sendable {
    case original, v2
    var id: String { rawValue }
    var label: String { self == .original ? "NokoGlass" : "NokoGlassv2" }
}

/// Maomao's Discord-owned surfaces. No native controls or Discord application
/// internals are replaced; the isolated script only installs a stylesheet.
@MainActor
enum MaomaoDiscordPresentation {
    static let world = WKContentWorld.world(name: "NokoCord.Maomao.Presentation")
    nonisolated static let preferenceKey = "maomaoNokoGlass"
    nonisolated static let stylePreferenceKey = "maomaoNokoGlassStyle"
    private static let scriptMarker = "/* NokoCord.Maomao.Presentation */"

    nonisolated static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? true
    }
    nonisolated static func selectedStyle(in defaults: UserDefaults = .standard) -> NokoGlassStyle {
        NokoGlassStyle(rawValue: defaults.string(forKey: stylePreferenceKey) ?? "") ?? .v2
    }

    static func install(on controller: WKUserContentController, safeMode: Bool = false,
                        editionID: String? = EditionIdentity.current?.id,
                        enabled: Bool = isEnabled(), style: NokoGlassStyle = selectedStyle()) {
        guard editionID == "maomao" else { return }
        // WebKit has no individual user-script removal API. Preserve every
        // other script exactly while replacing this presentation's registration.
        let retained = controller.userScripts.filter { !$0.source.hasPrefix(scriptMarker) }
        if retained.count != controller.userScripts.count {
            controller.removeAllUserScripts()
            retained.forEach(controller.addUserScript)
        }
        guard !safeMode, let source = source(enabled: enabled, style: style) else { return }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                             forMainFrameOnly: true, in: world))
    }

    static func apply(to view: WKWebView, safeMode: Bool,
                      editionID: String? = EditionIdentity.current?.id,
                      enabled: Bool = isEnabled(), style: NokoGlassStyle = selectedStyle()) {
        guard editionID == "maomao", let source = source(enabled: enabled && !safeMode, style: style) else { return }
        // Exiting Safe Mode can leave the existing document open. Registration
        // is idempotent and checks its own frame/origin before touching the DOM.
        view.evaluateJavaScript(source, in: nil, in: world) { _ in }
    }

    static func source(enabled: Bool = true, style: NokoGlassStyle = selectedStyle()) -> String? {
        guard let resourceBody else { return nil }
        return "\(scriptMarker)\n(() => { const presentationEnabled = \(enabled); const presentationStyle = \"\(style.rawValue)\";\n\(resourceBody)\n})();"
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
