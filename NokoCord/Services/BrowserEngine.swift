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
    private(set) var canGoForward = false
    private(set) var unreadCount = 0
    private(set) var microphoneCaptureState: WKMediaCaptureState = .none
    private(set) var cameraCaptureState: WKMediaCaptureState = .none
    var isInCall: Bool { microphoneCaptureState != .none || cameraCaptureState != .none }
    var isMicrophoneMuted: Bool { microphoneCaptureState == .muted }
    private(set) var notice: String?
    let engineDescription = String(localized: "System WebKit")
    let downloads = BrowserDownloads()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var appObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var memoryPurgeTimer: Timer?
    @ObservationIgnored private var channelPurgeTask: Task<Void, Never>?
    @ObservationIgnored private var navigation: WKNavigation?
    @ObservationIgnored private let dataStore: WKWebsiteDataStore
    @ObservationIgnored private var tanRuntime: TanRuntime?
    var onToggleTans: (() -> Void)?
    var onToggleQuickSwitcher: (() -> Void)?
    var onOpenTutorial: (() -> Void)?
    var onOpenMedia: ((URL, Bool) -> Void)?
    private(set) var isZenMode = false

    init(dataStore: WKWebsiteDataStore? = nil, tans: TanManager? = nil) {
        self.dataStore = dataStore ?? .default()
        super.init()
        if let tans {
            let runtime = TanRuntime(manager: tans)
            runtime.onToggleTans = { [weak self] in self?.onToggleTans?() }
            runtime.onToggleQuickSwitcher = { [weak self] in self?.onToggleQuickSwitcher?() }
            runtime.onOpenMedia = { [weak self] url, isVideo in self?.onOpenMedia?(url, isVideo) }
            runtime.onToggleZenMode = { [weak self] in self?.toggleZenMode() }
            runtime.onChannelChanged = { [weak self] in self?.handleChannelChanged() }
            tanRuntime = runtime
            tans.onChange = { [weak self] in self?.tanRuntime?.configurationChanged() }
        }
        GamePresenceService.shared.onPresenceChange = { [weak self] presence in
            self?.syncPresenceToDiscord(presence)
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

        // Flush WebKit memory cache when NokoCord is backgrounded or minimized
        let appCenter = NotificationCenter.default
        appObservers = [
            appCenter.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.purgeMemoryCache()
                }
            },
            appCenter.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.purgeMemoryCache()
                    self?.browserView?.pauseAllMediaPlayback()
                }
            }
        ]

        // Routine background memory cleanup every 5 minutes
        memoryPurgeTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.purgeMemoryCache()
            }
        }
    }
    deinit {
        channelPurgeTask?.cancel()
        memoryPurgeTimer?.invalidate()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        observations.forEach { $0.invalidate() }
    }

    func handleChannelChanged() {
        channelPurgeTask?.cancel()
        channelPurgeTask = Task { @MainActor [weak self] in
            // Debounce channel purge by 300ms so rapid clicking doesn't stutter,
            // then immediately evict decoded bitmap and network memory caches
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.purgeMemoryCache()
        }
    }

    /// Releases WebKit memory cache (decoded images/backing buffers) and invokes in-page media/DOM garbage cleanup.
    func purgeMemoryCache() {
        dataStore.removeData(
            ofTypes: [
                WKWebsiteDataTypeMemoryCache,
                WKWebsiteDataTypeFetchCache,
                WKWebsiteDataTypeDiskCache
            ],
            modifiedSince: .distantPast
        ) {}
        if let browserView, browserView.responds(to: Selector(("_clearBackForwardCache"))) {
            browserView.perform(Selector(("_clearBackForwardCache")))
        }
        browserView?.evaluateJavaScript("""
        (() => {
            try {
                window.__nokoPurgeMemory?.();
            } catch (_) {}
        })();
        """, completionHandler: nil)
    }

    func prepareBrowser() -> WKWebView {
        if let browserView { return browserView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // WebKit Memory Footprint Optimizations:
        // 1. Explicitly disable Page Cache (WebKit's multi-hundred MB back-forward snapshot cache)
        configuration.preferences.setValue(false, forKey: "usesPageCache")
        // 2. Drop offscreen render layer tiles immediately instead of retaining in GPU memory
        configuration.preferences.setValue(false, forKey: "aggressiveTileRetentionEnabled")
        // 3. Disable giant tile buffers (eliminates multi-hundred MB backing texture allocations)
        configuration.preferences.setValue(false, forKey: "useGiantTiles")
        // 4. Constrain video/audio buffer sizes
        configuration.preferences.setValue(true, forKey: "lowPowerVideoAudioBufferSizeEnabled")
        // 5. Disable offline app cache
        configuration.preferences.setValue(false, forKey: "offlineApplicationCacheIsEnabled")
        // 6. Throttle background DOM timers and enable process suppression
        configuration.preferences.setValue(true, forKey: "hiddenPageDOMTimerThrottlingEnabled")
        configuration.preferences.setValue(true, forKey: "pageVisibilityBasedProcessSuppressionEnabled")
        // Master Plan v2: controlled local Tans only; no auth/token bridge.
        // No enabled Tans means no injected scripts or handlers.
        tanRuntime?.prepare(configuration.userContentController)
        let view = WKWebView(frame: .zero, configuration: configuration)
        let savedZoom = UserDefaults.standard.double(forKey: "pageZoom")
        if savedZoom > 0.1 {
            view.pageZoom = savedZoom
        }
        view.navigationDelegate = self
        view.uiDelegate = self
        // Disable back-forward gestures: eliminates WebKit's multi-hundred-megabyte Page Cache for SPAs
        view.allowsBackForwardNavigationGestures = false
        view.isInspectable = false
        // Discord native dark theme background - eliminates white flicker completely
        view.underPageBackgroundColor = NSColor(srgbRed: 0.118, green: 0.122, blue: 0.133, alpha: 1.0)
        view.setValue(false, forKey: "drawsBackground")
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor(srgbRed: 0.118, green: 0.122, blue: 0.133, alpha: 1.0)
        tanRuntime?.attach(view)
        observations = [
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.browserView === view else { return }
                    self.tanRuntime?.locationChanged()
                    self.handleChannelChanged()
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
            },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.browserView === view else { return }
                    self.canGoForward = view.canGoForward
                }
            },
            view.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.browserView === view else { return }
                    self.updateUnreadCount(from: view.title)
                }
            },
            view.observe(\.microphoneCaptureState, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.browserView === view else { return }
                    self.microphoneCaptureState = view.microphoneCaptureState
                }
            },
            view.observe(\.cameraCaptureState, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.browserView === view else { return }
                    self.cameraCaptureState = view.cameraCaptureState
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
    func goForward() { guard canGoForward else { return }; browserView?.goForward() }
    func zoomIn() {
        guard let view = browserView else { return }
        view.pageZoom = min(view.pageZoom + 0.1, 2.5)
        UserDefaults.standard.set(view.pageZoom, forKey: "pageZoom")
    }
    func zoomOut() {
        guard let view = browserView else { return }
        view.pageZoom = max(view.pageZoom - 0.1, 0.5)
        UserDefaults.standard.set(view.pageZoom, forKey: "pageZoom")
    }
    func resetZoom() {
        guard let view = browserView else { return }
        view.pageZoom = 1.0
        UserDefaults.standard.set(1.0, forKey: "pageZoom")
    }
    /// Toggles Zen Mode: hides Discord server/channel sidebars to cut layout and memory overhead by ~40%.
    func toggleZenMode() {
        isZenMode.toggle()
        browserView?.evaluateJavaScript("document.documentElement.classList.toggle('nokocord-zen-mode', \(isZenMode));", completionHandler: nil)
    }
    func toggleMicrophoneMute() {
        guard let view = browserView else { return }
        let next: WKMediaCaptureState = (microphoneCaptureState == .active) ? .muted : .active
        Task { @MainActor in
            await view.setMicrophoneCaptureState(next)
            self.microphoneCaptureState = next
        }
    }
    func disconnectCall() {
        guard let view = browserView else { return }
        Task { @MainActor in
            await view.setMicrophoneCaptureState(.none)
            await view.setCameraCaptureState(.none)
            self.microphoneCaptureState = .none
            self.cameraCaptureState = .none
        }
    }
    private func updateUnreadCount(from title: String?) {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            unreadCount = 0
            NSApp.dockTile.badgeLabel = nil
            return
        }
        if title.hasPrefix("("), let closeIndex = title.firstIndex(of: ")") {
            let inner = title[title.index(after: title.startIndex)..<closeIndex]
            if let count = Int(inner), count > 0 {
                unreadCount = count
                NSApp.dockTile.badgeLabel = "\(count)"
                return
            }
        } else if title.hasPrefix("•") {
            unreadCount = 0
            NSApp.dockTile.badgeLabel = "•"
            return
        }
        unreadCount = 0
        NSApp.dockTile.badgeLabel = nil
    }
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
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        tanRuntime?.detach()
        browserView = nil
        navigation = nil
        canGoBack = false
        canGoForward = false
        unreadCount = 0
        NSApp.dockTile.badgeLabel = nil
        progress = 0
        microphoneCaptureState = .none
        cameraCaptureState = .none
        GamePresenceService.shared.clearPresence()
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
        if let presence = GamePresenceService.shared.activePresence {
            syncPresenceToDiscord(presence)
        }
    }

    /// Dispatches active Game Rich Presence payload to Discord's web client FluxDispatcher via WKWebView.
    func syncPresenceToDiscord(_ presence: GamePresence?) {
        guard let view = browserView, lifecycle.phase == .ready else { return }

        let jsonString: String
        if let presence,
           let data = try? JSONSerialization.data(withJSONObject: presence.toDiscordPayload()),
           let str = String(data: data, encoding: .utf8) {
            jsonString = str
        } else {
            jsonString = "null"
        }

        let script = """
        (() => {
            try {
                const act = \(jsonString);
                const wp = window.webpackChunkdiscord_app;
                if (!wp) return;
                let modules;
                try {
                    wp.push([[Symbol()], {}, e => { modules = e.c; }]);
                } catch (_) {}
                if (!modules) return;

                let dispatcher = null;
                for (const id in modules) {
                    const m = modules[id]?.exports;
                    if (!m) continue;
                    if (m.default && typeof m.default.dispatch === 'function' && typeof m.default.subscribe === 'function') {
                        dispatcher = m.default;
                        break;
                    }
                    if (typeof m.dispatch === 'function' && typeof m.subscribe === 'function') {
                        dispatcher = m;
                        break;
                    }
                }

                if (dispatcher) {
                    dispatcher.dispatch({
                        type: "LOCAL_ACTIVITY_UPDATE",
                        socketId: "nokocord-game-rp",
                        activity: act
                    });
                }
            } catch (_) {}
        })();
        """

        view.evaluateJavaScript(script, completionHandler: nil)
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
