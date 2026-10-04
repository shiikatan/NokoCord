import AppKit
import WebKit

/// Routes explicit image saves through the same WKDownload owner as attachments.
/// The bridge lives in an isolated world and accepts only the Discord main frame.
@MainActor
final class MaomaoMediaDownloads: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "NokoCord.Maomao.MediaDownloads")
    private static let handler = "maomaoMediaDownload"
    private static let marker = "/* NokoCord.Maomao.MediaDownloads */"
    private weak var controller: WKUserContentController?
    private weak var view: WKWebView?
    var onRequest: ((URL) -> Void)?
    var onUnavailable: (() -> Void)?

    private static let source: String? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "MaomaoMediaDownloads", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return marker + "\n" + source
    }()

    func install(on controller: WKUserContentController) {
        if self.controller !== controller {
            self.controller?.removeScriptMessageHandler(forName: Self.handler, contentWorld: Self.world)
            controller.add(self, contentWorld: Self.world, name: Self.handler)
            self.controller = controller
        }
        let retained = controller.userScripts.filter { !$0.source.hasPrefix(Self.marker) }
        if retained.count != controller.userScripts.count {
            controller.removeAllUserScripts()
            retained.forEach(controller.addUserScript)
        }
        guard let source = Self.source else { return }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: true, in: Self.world))
    }

    func attach(_ view: WKWebView) { self.view = view }

    func pageDidLoad() {
        guard let view, BrowserPolicy.isDiscordOrigin(view.url), let source = Self.source else { return }
        view.evaluateJavaScript(source, in: nil, in: Self.world) { _ in }
    }

    func detach() {
        controller?.removeScriptMessageHandler(forName: Self.handler, contentWorld: Self.world)
        controller = nil; view = nil
    }

    func requestContextDownload(kind: String, point: CGPoint) {
        guard let view, BrowserPolicy.isDiscordOrigin(view.url) else { return }
        view.callAsyncJavaScript("return globalThis.__maomaoMediaDownloads?.contextURL(kind, x, y) ?? null;",
                                arguments: ["kind": kind, "x": point.x, "y": point.y],
                                in: nil, in: Self.world) { [weak self, weak view] result in
            guard let self, let view, self.view === view, BrowserPolicy.isDiscordOrigin(view.url) else { return }
            guard case .success(let value) = result, let raw = value as? String else {
                self.onUnavailable?(); return
            }
            self.request(raw)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handler, let view, message.webView === view,
              message.frameInfo.isMainFrame, BrowserPolicy.isDiscordOrigin(message.frameInfo.request.url),
              BrowserPolicy.isDiscordOrigin(view.url), let raw = message.body as? String else { return }
        request(raw)
    }

    private func request(_ raw: String) {
        guard raw.utf8.count <= 8 * 1024 * 1024, let url = URL(string: raw),
              url.user == nil, url.password == nil else { onUnavailable?(); return }
        let scheme = url.scheme?.lowercased()
        let remote = scheme == "https" && url.host != nil
        let blob = scheme == "blob" && BrowserPolicy.isDiscordOrigin(URL(string: String(raw.dropFirst(5))))
        let inlineImage = scheme == "data" && raw.prefix(11).lowercased() == "data:image/"
        guard remote || blob || inlineImage else { onUnavailable?(); return }
        onRequest?(url)
    }
}

/// WebKit's built-in image save uses a separate delegate path. Replace only
/// download menu actions with our public WKWebView.startDownload integration.
@MainActor
final class MaomaoWebView: WKWebView {
    var onContextDownload: ((String, CGPoint) -> Void)?
    private var contextPoint = CGPoint.zero

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard BrowserPolicy.isDiscordOrigin(url), bounds.width > 0, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        contextPoint = CGPoint(x: (point.x - bounds.minX) / bounds.width,
                               y: isFlipped ? (point.y - bounds.minY) / bounds.height : (bounds.maxY - point.y) / bounds.height)
        for item in menu.items {
            let kind: String
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierDownloadImage": kind = "image"
            case "WKMenuItemIdentifierDownloadLinkedFile": kind = "link"
            case "WKMenuItemIdentifierDownloadMedia": kind = "media"
            default: continue
            }
            item.target = self
            item.action = #selector(downloadContextItem(_:))
            item.representedObject = kind
        }
    }

    @objc private func downloadContextItem(_ item: NSMenuItem) {
        guard let kind = item.representedObject as? String else { return }
        onContextDownload?(kind, contextPoint)
    }
}
