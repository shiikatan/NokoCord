import Foundation
import WebKit

/// A bundled native Tan owns its reversible page hooks. No file paths, account
/// credentials, or content cross a native message bridge. Temporary File/Blob
/// copies live only as long as Discord's attachment state needs them.
@MainActor
final class MaomaoNokonymise {
    private let manager: TanManager
    private let available: Bool
    private var installedEnabled = false
    private var selectedEnabled: Bool
    private var documentEnabled: Bool?
    private var pendingEnabled: Bool?
    private var pendingInvalidated = false
    private var needsFreshDocument = false
    private static let key = "__nokoNokonymise"
    private static let marker = "/* NokoCord.Maomao.Nokonymise */"
    private static let source: String? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let main = bundle.url(forResource: "Nokonymise", withExtension: "js"),
              let worker = bundle.url(forResource: "NokonymiseWorker", withExtension: "js"),
              let mainSource = try? String(contentsOf: main, encoding: .utf8),
              let workerSource = try? String(contentsOf: worker, encoding: .utf8) else { return nil }
        return mainSource.replacingOccurrences(of: "/* NOKONYMise_WORKER_SOURCE */", with: TanRuntime.quote(workerSource))
    }()

    init(manager: TanManager, editionID: String? = EditionIdentity.current?.id) {
        self.manager = manager
        available = editionID == "maomao"
        selectedEnabled = available && manager.active.contains {
            $0.id == NokoNativeTanID.nokonymise && $0.contentHash == TanPackage.nokonymise.contentHash
        }
    }
    private var enabled: Bool {
        available && manager.active.contains {
            $0.id == NokoNativeTanID.nokonymise && $0.contentHash == TanPackage.nokonymise.contentHash
        }
    }
    func install(on controller: WKUserContentController) {
        guard available else { return }
        installedEnabled = enabled
        let retained = controller.userScripts.filter { !$0.source.hasPrefix(Self.marker) }
        if retained.count != controller.userScripts.count {
            controller.removeAllUserScripts()
            retained.forEach(controller.addUserScript)
        }
        guard enabled, let source = Self.source else { return }
        // TanRuntime rebuilds the controller's scripts; the owner reinstalls
        // this one afterwards. Inactive documents have no hooks or worker.
        controller.addUserScript(WKUserScript(source: Self.marker + "\n" + source + "\n\(Self.key).configure(true);",
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }
    func apply(to view: WKWebView) {
        guard available else { return }
        let enabled = enabled
        if selectedEnabled != enabled, documentEnabled != nil || pendingEnabled != nil {
            needsFreshDocument = true
            if pendingEnabled != nil { pendingInvalidated = true }
        }
        selectedEnabled = enabled
        updateNotice(for: view)
        // Discord retains references to APIs captured at startup. Replacing
        // those APIs again in a running document is not a reliable activation.
        // Stop immediately, but only activate through the document-start script.
        if !enabled { stop(in: view) }
    }
    func documentNavigationStarted() {
        guard available else { return }
        pendingEnabled = installedEnabled
        pendingInvalidated = false
    }
    func pageDidLoad(_ view: WKWebView) {
        guard available else { return }
        if BrowserPolicy.isDiscordOrigin(view.url) {
            documentEnabled = pendingEnabled ?? installedEnabled
            needsFreshDocument = pendingInvalidated || documentEnabled != enabled
        } else {
            documentEnabled = nil
            needsFreshDocument = false
        }
        pendingEnabled = nil; pendingInvalidated = false
        selectedEnabled = enabled
        updateNotice(for: view)
        if !enabled { stop(in: view) }
    }
    func locationChanged(_ view: WKWebView) {
        guard available else { return }
        updateNotice(for: view)
    }
    func detach() {
        guard available else { return }
        documentEnabled = nil; pendingEnabled = nil; pendingInvalidated = false; needsFreshDocument = false
        selectedEnabled = enabled
        manager.setMaomaoNativeReloadRequired(false, for: NokoNativeTanID.nokonymise)
    }
    private func updateNotice(for view: WKWebView) {
        manager.setMaomaoNativeReloadRequired(needsFreshDocument && BrowserPolicy.isDiscordOrigin(view.url),
                                             for: NokoNativeTanID.nokonymise)
    }
    private func stop(in view: WKWebView) {
        guard BrowserPolicy.isDiscordOrigin(view.url) else { return }
        view.evaluateJavaScript("globalThis.\(Self.key)?.configure(false);", in: nil, in: .page) { _ in }
    }
}
