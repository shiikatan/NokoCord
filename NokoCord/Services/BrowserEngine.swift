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
    func clearTemporaryCache() async
}

@MainActor @Observable
final class WKBrowserEngine: NSObject, BrowserEngine, WKNavigationDelegate, WKUIDelegate {
    private(set) var browserView: WKWebView?
    var view: NSView? { browserView }
    private(set) var lifecycle = BrowserLifecycle()
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var notice: String?
    let downloads = BrowserDownloads()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var navigation: WKNavigation?
    @ObservationIgnored private let dataStore: WKWebsiteDataStore
    @ObservationIgnored private var tanRuntime: TanRuntime?
    @ObservationIgnored private var nokonymise: MaomaoNokonymise?
    @ObservationIgnored private var mediaDownloads: MaomaoMediaDownloads?
    @ObservationIgnored private var appSwitching: MaomaoAppSwitching?
    @ObservationIgnored var onSwitchToMaoList: (() -> Void)?
    private var maoListSwitchEnabled = false
    func setMaoListSwitchEnabled(_ enabled: Bool) {
        guard EditionIdentity.current?.id == "maomao" else { return }
        maoListSwitchEnabled = enabled
        if enabled {
            if appSwitching == nil {
                let switching = MaomaoAppSwitching()
                switching.onSelect = { [weak self] in self?.onSwitchToMaoList?() }
                appSwitching = switching
            }
            if let view = browserView {
                appSwitching?.install(on: view.configuration.userContentController)
                appSwitching?.attach(view, visible: lifecycle.isVisible)
            }
        } else { appSwitching?.detach(); appSwitching = nil }
    }

    init(dataStore: WKWebsiteDataStore? = nil, tans: TanManager? = nil) {
        self.dataStore = dataStore ?? .default()
        super.init()
        if EditionIdentity.current?.id == "maomao" {
            let mediaDownloads = MaomaoMediaDownloads()
            self.mediaDownloads = mediaDownloads
            mediaDownloads.onRequest = { [weak self] url in
                guard let self, let view = self.browserView, self.lifecycle.phase != .clearing,
                      BrowserPolicy.isDiscordOrigin(view.url) else { return }
                self.startDownload(URLRequest(url: url), from: view)
            }
            mediaDownloads.onUnavailable = { [weak self] in
                self?.notice = String(localized: "This image is no longer available. Open it again in Discord and retry the download.")
            }
        }
        if let tans {
            tanRuntime = TanRuntime(manager: tans)
            if EditionIdentity.current?.id == "maomao" { nokonymise = MaomaoNokonymise(manager: tans) }
            tans.onChange = { [weak self, weak tans] in
                guard let self else { return }
                let scriptsChanged = self.tanRuntime?.configurationChanged() != false
                if let view = self.browserView {
                    self.nokonymise?.install(on: view.configuration.userContentController)
                    self.nokonymise?.apply(to: view)
                    self.mediaDownloads?.install(on: view.configuration.userContentController)
                    self.appSwitching?.install(on: view.configuration.userContentController)
                }
                guard scriptsChanged else { return }
                // Tan reconfiguration rebuilds the controller's user scripts.
                if let view = self.browserView {
                    let safeMode = tans?.safeMode ?? false
                    MaomaoDiscordPresentation.install(on: view.configuration.userContentController, safeMode: safeMode)
                    MaomaoDiscordPresentation.apply(to: view, safeMode: safeMode)
                }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.lifecycle.sleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lifecycle.wake()
                    self.tanRuntime?.didWake()
                }
            }
        ]
    }
    deinit { workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }

    func prepareBrowser() -> WKWebView {
        if let browserView { return browserView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        MaomaoWebCompatibility.configure(configuration)
        tanRuntime?.prepare(configuration.userContentController)
        nokonymise?.install(on: configuration.userContentController)
        mediaDownloads?.install(on: configuration.userContentController)
        appSwitching?.install(on: configuration.userContentController)
        MaomaoDiscordPresentation.install(on: configuration.userContentController,
                                         safeMode: tanRuntime?.manager.safeMode ?? false)
        let view: WKWebView
        if mediaDownloads != nil {
            let maomaoView = MaomaoWebView(frame: .zero, configuration: configuration)
            maomaoView.onContextDownload = { [weak self] kind, point in
                self?.mediaDownloads?.requestContextDownload(kind: kind, point: point)
            }
            view = maomaoView
        } else {
            view = WKWebView(frame: .zero, configuration: configuration)
        }
        mediaDownloads?.attach(view)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        #if DEBUG
        view.isInspectable = true
        #else
        view.isInspectable = false
        #endif
        tanRuntime?.attach(view)
        observations = [
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.browserView === view else { return }
                    self.tanRuntime?.locationChanged()
                    self.nokonymise?.locationChanged(view)
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
        appSwitching?.setVisible(true)
        if browserView == nil {
            _ = prepareBrowser()
            lifecycle.loading()
            navigation = browserView?.load(URLRequest(url: BrowserPolicy.home))
        }
    }
    func showHome() { appSwitching?.setVisible(false); lifecycle.hide() }
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
    func setNokoGlassEnabled(_ enabled: Bool) {
        guard EditionIdentity.current?.id == "maomao", let view = browserView else { return }
        let safeMode = tanRuntime?.manager.safeMode ?? false
        MaomaoDiscordPresentation.install(on: view.configuration.userContentController,
                                         safeMode: safeMode, enabled: enabled)
        MaomaoDiscordPresentation.apply(to: view, safeMode: safeMode, enabled: enabled)
    }
    func dismissNotice() { notice = nil }
    func clearProfile() async {
        guard lifecycle.phase != .clearing else { return }
        lifecycle.clearing()
        await discardBrowserView()
        // Delete without enumerating or reading cookies, credentials or records.
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        lifecycle.cleared()
        lifecycle.hide()
        notice = nil
    }
    func clearTemporaryCache() async {
        await resetTemporaryCache(reopen: true)
    }
    // The isolated-store test exercises teardown without contacting Discord.
    func resetTemporaryCache(reopen: Bool) async {
        guard lifecycle.phase != .clearing else { return }
        lifecycle.clearing()
        await discardBrowserView()
        // Keep cookies, local storage, IndexedDB and service workers in the
        // same website data store. A live signed-in check is still required.
        await dataStore.removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
                                   modifiedSince: .distantPast)
        lifecycle.cleared()
        notice = nil
        if reopen { openDiscord() }
        else { lifecycle.hide() }
    }
    private func discardBrowserView() async {
        downloads.cancelAll()
        browserView?.stopLoading()
        await browserView?.setCameraCaptureState(.none)
        await browserView?.setMicrophoneCaptureState(.none)
        await browserView?.pauseAllMediaPlayback()
        browserView?.navigationDelegate = nil
        browserView?.uiDelegate = nil
        observations.removeAll()
        tanRuntime?.detach()
        nokonymise?.detach()
        mediaDownloads?.detach()
        appSwitching?.detach()
        browserView = nil
        navigation = nil
        canGoBack = false
        progress = 0
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === browserView, lifecycle.phase != .clearing else { return }
        self.navigation = navigation
        tanRuntime?.documentNavigationStarted()
        nokonymise?.documentNavigationStarted()
        notice = nil
        lifecycle.loading()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === browserView, lifecycle.phase != .clearing, self.navigation === navigation else { return }
        lifecycle.ready()
        tanRuntime?.pageDidLoad()
        nokonymise?.pageDidLoad(webView)
        mediaDownloads?.pageDidLoad()
        if maoListSwitchEnabled { appSwitching?.attach(webView, visible: lifecycle.isVisible) }
        // WebKit may have captured the document's user scripts before an
        // appearance change during loading. Honor the latest saved preference.
        MaomaoDiscordPresentation.apply(to: webView, safeMode: tanRuntime?.manager.safeMode ?? false)
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
        guard webView === browserView, lifecycle.phase != .clearing else { decisionHandler(.cancel); return }
        let topLevel = action.targetFrame?.isMainFrame ?? true
        let activated = action.navigationType == .linkActivated
        if action.shouldPerformDownload, BrowserPolicy.isDiscordOrigin(webView.url) {
            decisionHandler(.download); return
        }
        if action.targetFrame == nil, activated,
           BrowserPolicy.isDiscordOrigin(webView.url),
           BrowserPolicy.isDownloadableDiscordAttachment(action.request.url,
                                                        sourceURL: action.sourceFrame.request.url) {
            // Discord opens ordinary attachment files in a new window, even
            // from its Download link. Keep the one Discord view in place and
            // use WebKit's download machinery with its existing data store.
            startDownload(action.request, from: webView)
            decisionHandler(.cancel)
            return
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
        guard webView === browserView, lifecycle.phase != .clearing else { decisionHandler(.cancel); return }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        guard webView === browserView, lifecycle.phase != .clearing else { download.cancel { _ in }; return }
        downloads.attach(download)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        guard webView === browserView, lifecycle.phase != .clearing else { download.cancel { _ in }; return }
        downloads.attach(download)
    }
    private func startDownload(_ request: URLRequest, from webView: WKWebView) {
        webView.startDownload(using: request) { [weak self, weak webView] download in
            guard let self, let webView, self.browserView === webView,
                  self.lifecycle.phase != .clearing else { download.cancel { _ in }; return }
            self.downloads.attach(download)
        }
    }
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
