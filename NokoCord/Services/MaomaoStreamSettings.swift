import WebKit

/// Browser stream controls are an app feature, independent of installed Tans.
/// Discord's own permission and subscription checks still govern each choice.
@MainActor
enum MaomaoStreamSettings {
    private static let marker = "/* NokoCord.Maomao.StreamSettings */"
    private static let source: String? = {
        guard let url = Bundle.main.url(forResource: "MaomaoStreamSettings", withExtension: "js"),
              let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return marker + "\n" + body
    }()
    static func install(on controller: WKUserContentController,
                        editionID: String? = EditionIdentity.current?.id) {
        guard editionID == "maomao", let source,
              !controller.userScripts.contains(where: { $0.source.hasPrefix(marker) }) else { return }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: true, in: .page))
    }
}
