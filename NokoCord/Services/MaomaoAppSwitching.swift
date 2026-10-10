import AppKit
import WebKit

/// A utility toolbar logo opens native MaoList through an isolated message bridge.
@MainActor
final class MaomaoAppSwitching: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "NokoCord.Maomao.AppSwitching")
    private static let handler = "maomaoSwitchApp"
    private static let marker = "/* NokoCord.Maomao.AppSwitching */"
    private weak var controller: WKUserContentController?
    private weak var view: WKWebView?
    var onSelect: (() -> Void)?
    private var desiredVisible = true
    private var generation = UUID()

    private static let source: String? = {
        guard let url = Bundle.main.url(forResource: "MaomaoAppSwitching", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let noko = icon("NokoMark"), let mao = icon("MaoListMark"),
              let data = try? JSONEncoder().encode([noko, mao]),
              let icons = String(data: data, encoding: .utf8) else { return nil }
        return marker + "\n(() => { const icons = \(icons);\n" + script + "\n})();"
    }()
    private static func icon(_ name: String) -> String? {
        guard let image = NSImage(named: name),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 48, height: 48))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
    func install(on controller: WKUserContentController) {
        if self.controller !== controller {
            self.controller?.removeScriptMessageHandler(forName: Self.handler, contentWorld: Self.world)
            controller.add(self, contentWorld: Self.world, name: Self.handler)
            self.controller = controller
        }
        removeScript(from: controller)
        if let source = Self.source {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                                 forMainFrameOnly: true, in: Self.world))
        }
    }
    func attach(_ view: WKWebView, visible: Bool) {
        self.view = view; desiredVisible = visible
        generation = UUID(); let lease = generation
        guard BrowserPolicy.isDiscordOrigin(view.url), let source = Self.source else { return }
        view.evaluateJavaScript(source, in: nil, in: Self.world) { [weak self, weak view] _ in
            guard let self, let view, self.view === view, self.generation == lease else { return }
            self.setVisible(self.desiredVisible)
        }
    }
    func setVisible(_ visible: Bool) {
        desiredVisible = visible
        guard let view, BrowserPolicy.isDiscordOrigin(view.url) else { return }
        view.callAsyncJavaScript("globalThis.__maomaoAppSwitching?.setVisible(visible)",
                                 arguments: ["visible": visible], in: nil, in: Self.world) { _ in }
    }
    func detach() {
        generation = UUID(); desiredVisible = false
        if let view, BrowserPolicy.isDiscordOrigin(view.url) {
            view.evaluateJavaScript("globalThis.__maomaoAppSwitching?.destroy()", in: nil, in: Self.world) { _ in }
        }
        if let controller {
            controller.removeScriptMessageHandler(forName: Self.handler, contentWorld: Self.world)
            removeScript(from: controller)
        }
        controller = nil; view = nil
    }
    private func removeScript(from controller: WKUserContentController) {
        let retained = controller.userScripts.filter { !$0.source.hasPrefix(Self.marker) }
        if retained.count != controller.userScripts.count {
            controller.removeAllUserScripts(); retained.forEach(controller.addUserScript)
        }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handler, let view, message.webView === view,
              message.frameInfo.isMainFrame, BrowserPolicy.isDiscordOrigin(view.url),
              BrowserPolicy.isDiscordOrigin(message.frameInfo.request.url), message.body as? String == "maolist" else { return }
        onSelect?()
    }
}
