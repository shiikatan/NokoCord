import AppKit
import Observation
import WebKit

@MainActor
protocol BrowserEngine: AnyObject {
    var view: NSView? { get }
    var lifecycle: BrowserLifecycle { get }
    func openDiscord()
    func showHome()
    func reload()
    func clearProfile() async
}

@MainActor @Observable
final class WKBrowserEngine: NSObject, BrowserEngine, WKNavigationDelegate, WKUIDelegate {
    private(set) var browserView: WKWebView?
    var view: NSView? { browserView }
    private(set) var lifecycle = BrowserLifecycle()
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var notice: String?
    let engineDescription = String(localized: "System WebKit")
    let downloads = BrowserDownloads()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var navigation: WKNavigation?
    @ObservationIgnored private let dataStore: WKWebsiteDataStore
    @ObservationIgnored private var tanRuntime: TanRuntime?

    init(dataStore: WKWebsiteDataStore? = nil, tans: TanManager? = nil) {
        self.dataStore = dataStore ?? .default()
        super.init()
        if let tans {
            tanRuntime = TanRuntime(manager: tans)
            tans.onChange = { [weak self] in self?.tanRuntime?.configurationChanged() }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.lifecycle.sleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.lifecycle.wake() }
            }
        ]
    }
    deinit { workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }

    func prepareBrowser() -> WKWebView {
        if let browserView { return browserView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // Master Plan v2: controlled local Tans only; no auth/token bridge.
        // No enabled Tans means no injected scripts or handlers.
        tanRuntime?.prepare(configuration.userContentController)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isInspectable = false
        tanRuntime?.attach(view)
        observations = [
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.browserView === view else { return }
                    self.tanRuntime?.locationChanged()
                }
            },
            view.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.browserView === view else { return }
                    self.progress = view.estimatedProgress
                }
            },
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.browserView === view else { return }
                    self.canGoBack = view.canGoBack
                }
            }
        ]
        browserView = view
        return view
    }
    func openDiscord() {
        guard lifecycle.phase != .clearing else { return }
        lifecycle.show()
        if browserView == nil {
            _ = prepareBrowser()
            lifecycle.loading()
            navigation = browserView?.load(URLRequest(url: BrowserPolicy.home))
        }
    }
    func showHome() { lifecycle.hide() }
    func openGuild(_ id: String) {
        guard !id.isEmpty, id.utf8.count <= 20,
              id.utf8.allSatisfy({ (48...57).contains($0) }), lifecycle.phase != .clearing else { return }
        lifecycle.show()
        let view = prepareBrowser()
        lifecycle.loading()
        navigation = view.load(URLRequest(url: URL(string: "https://discord.com/channels/\(id)")!))
    }
    func reload() {
        guard lifecycle.phase != .clearing else { return }
        notice = nil
        lifecycle.loading()
        if let view = browserView { navigation = view.reload() ?? view.load(URLRequest(url: BrowserPolicy.home)) }
        else { openDiscord() }
    }
    func goBack() { guard canGoBack else { return }; browserView?.goBack() }
    func dismissNotice() { notice = nil }
    func clearProfile() async {
        guard lifecycle.phase != .clearing else { return }
        lifecycle.clearing()
        downloads.cancelAll()
        browserView?.stopLoading()
        await browserView?.setCameraCaptureState(.none)
        await browserView?.setMicrophoneCaptureState(.none)
        await browserView?.pauseAllMediaPlayback()
        browserView?.navigationDelegate = nil
        browserView?.uiDelegate = nil
        observations.removeAll()
        tanRuntime?.detach()
        browserView = nil
        navigation = nil
        canGoBack = false
        progress = 0
        // Delete without enumerating or reading cookies, credentials or records.
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        lifecycle.cleared()
        lifecycle.hide()
        notice = nil
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === browserView, lifecycle.phase != .clearing else { return }
        self.navigation = navigation
        notice = nil
        lifecycle.loading()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === browserView, lifecycle.phase != .clearing, self.navigation === navigation else { return }
        lifecycle.ready()
        tanRuntime?.pageDidLoad()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(navigation, error: error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(navigation, error: error)
    }
    private func failed(_ navigation: WKNavigation?, error: Error) {
        guard lifecycle.phase != .clearing, self.navigation === navigation, (error as NSError).code != NSURLErrorCancelled else { return }
        // Never expose WebKit's URL-bearing localized errors or page content.
        lifecycle.fail()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === browserView, lifecycle.phase != .clearing else { return }
        lifecycle.crash()
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let topLevel = action.targetFrame?.isMainFrame ?? true
        guard lifecycle.phase != .clearing else { decisionHandler(.cancel); return }
        let activated = action.navigationType == .linkActivated
        if action.shouldPerformDownload, BrowserPolicy.isDiscordOrigin(webView.url) {
            decisionHandler(.download); return
        }
        switch BrowserPolicy.route(action.request.url, isMainFrame: topLevel, userActivated: activated) {
        case .workspace:
            // A same-origin popup uses this one workspace rather than creating
            // a second persistent browser. Ordinary page resources are untouched.
            if action.targetFrame == nil, let url = action.request.url, BrowserPolicy.isDiscordOrigin(url) {
                webView.load(action.request); decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        case .external:
            if let url = action.request.url { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        case .deny:
            notice = String(localized: "This page could not open in NokoCord. You can try signing in at discord.com.")
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { downloads.attach(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { downloads.attach(download) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let safe = BrowserPolicy.permitsMediaPrompt(scheme: origin.protocol, host: origin.host, port: origin.port,
                                                   frameURL: frame.request.url, topURL: webView.url)
        decisionHandler(safe ? .prompt : .deny)
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard BrowserPolicy.isDiscordOrigin(frame.request.url), let window = webView.window else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { response in completionHandler(response == .OK ? panel.urls : nil) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}
