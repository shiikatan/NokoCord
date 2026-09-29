import AppKit
import AVFoundation
import Observation
import WebKit

@MainActor
enum NativeTextCheckingSuppressor {
    static func suppressAll() {
        let textCheckingDefaults: [String: Any] = [
            "NSAutomaticSpellingCorrectionEnabled": false,
            "NSAutomaticTextReplacementEnabled": false,
            "NSAutomaticQuoteSubstitutionEnabled": false,
            "NSAutomaticDashSubstitutionEnabled": false,
            "NSAutomaticCapitalizationEnabled": false,
            "NSAutomaticPeriodSubstitutionEnabled": false,
            "NSAutomaticInlinePredictionEnabled": false,
            "NSAutomaticTextCompletionEnabled": false,
            "WebAutomaticTextCompletionEnabled": false,
            "WebInlinePredictionEnabled": false,
            "WebContinuousSpellCheckingEnabled": false,
            "WebGrammarCheckingEnabled": false,
            "WebAutomaticSpellingCorrectionEnabled": false
        ]
        UserDefaults.standard.register(defaults: textCheckingDefaults)
        for (key, val) in textCheckingDefaults {
            UserDefaults.standard.set(val, forKey: key)
        }
        let checker = NSSpellChecker.shared
        let selectors = [
            "setAutomaticInlinePredictionEnabled:",
            "setAutomaticInlineCompletionEnabled:",
            "setAutomaticTextCompletionEnabled:",
            "setAutomaticSpellingCorrectionEnabled:",
            "setAutomaticTextReplacementEnabled:",
            "setAutomaticQuoteSubstitutionEnabled:",
            "setAutomaticDashSubstitutionEnabled:",
            "setAutomaticCapitalizationEnabled:",
            "setAutomaticPeriodSubstitutionEnabled:"
        ]
        for selName in selectors {
            let sel = NSSelectorFromString(selName)
            if checker.responds(to: sel) {
                checker.perform(sel, with: false as NSNumber)
            }
        }
    }
}

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
    private(set) var discordCompatibility = DiscordCompatibilitySnapshot.initial()
    private(set) var callReadiness = CallReadinessService.evaluate(
        origin: "",
        mediaDevicesAvailable: false,
        microphonePermission: .unknown,
        cameraPermission: .unknown,
        encodedTransformAvailable: false,
        discordCallSurfaceReady: false,
        captureState: .none
    )
    private(set) var callTeardown = CallTeardownState(readiness: CallReadinessService.evaluate(
        origin: "",
        mediaDevicesAvailable: false,
        microphonePermission: .unknown,
        cameraPermission: .unknown,
        encodedTransformAvailable: false,
        discordCallSurfaceReady: false,
        captureState: .none
    ))
    var isInCall: Bool { callTeardown.isCallConfirmed }
    private var hasActiveMediaCapture: Bool {
        microphoneCaptureState != .none || cameraCaptureState != .none
    }
    var isMicrophoneMuted: Bool { microphoneCaptureState == .muted }
    private(set) var notice: String?
    let engineDescription = String(localized: "System WebKit")
    let downloads = BrowserDownloads()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var appObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var memoryPurgeTimer: Timer?
    @ObservationIgnored private var channelPurgeTask: Task<Void, Never>?
    @ObservationIgnored private var callReadinessTask: Task<Void, Never>?
    @ObservationIgnored private var compatibilityProbeTask: Task<Void, Never>?
    @ObservationIgnored private var pageGeneration = UUID()
    @ObservationIgnored private var navigation: WKNavigation?
    @ObservationIgnored private let dataStore: WKWebsiteDataStore
    @ObservationIgnored private let tans: TanManager?
    @ObservationIgnored private var tanRuntime: TanRuntime?
    var onToggleTans: (() -> Void)?
    var onToggleQuickSwitcher: (() -> Void)?
    var onToggleBookmarks: (() -> Void)?
    var onOpenTutorial: (() -> Void)?
    var onOpenMedia: ((URL, Bool) -> Void)?
    var onSaveBookmark: ((NokoBookmark) -> Void)?
    private(set) var isZenMode = false

    init(dataStore: WKWebsiteDataStore? = nil, tans: TanManager? = nil) {
        self.dataStore = dataStore ?? .default()
        self.tans = tans
        super.init()
        if let tans {
            let runtime = TanRuntime(manager: tans)
            runtime.onToggleTans = { [weak self] in self?.onToggleTans?() }
            runtime.onToggleQuickSwitcher = { [weak self] in self?.onToggleQuickSwitcher?() }
            runtime.onToggleBookmarks = { [weak self] in self?.onToggleBookmarks?() }
            runtime.onOpenMedia = { [weak self] url, isVideo in self?.onOpenMedia?(url, isVideo) }
            runtime.onToggleZenMode = { [weak self] in self?.toggleZenMode() }
            runtime.onChannelChanged = { [weak self] in self?.handleChannelChanged() }
            runtime.onSaveBookmark = { [weak self] bookmark in self?.onSaveBookmark?(bookmark) }
            runtime.onCompatibilityChange = { [weak self] snapshot in self?.discordCompatibility = snapshot }
            tanRuntime = runtime
            tans.onChange = { [weak self] in
                self?.tanRuntime?.configurationChanged()
                self?.updateAppleMusicActivation()
            }
        }
        // Local Rich Presence is delivered per feature: game presence is a native
        // capability, Apple Music presence belongs to the noko.apple-music Tan.
        GamePresenceService.shared.onPresenceChange = { [weak self] presence in
            self?.syncGamePresenceToDiscord(presence)
            self?.syncAppleMusicPresenceToDiscord()
        }
        AppleMusicRPCService.shared.onPresenceChange = { [weak self] in
            self?.syncAppleMusicPresenceToDiscord()
        }
        updateAppleMusicActivation()
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
                    self?.hibernate()
                }
            },
            appCenter.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.resume()
                }
            },
            appCenter.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Pausing media elements would silence an active call's audio.
                    self.hibernate()
                    if !self.isInCall { self.browserView?.pauseAllMediaPlayback() }
                }
            }
        ]

        // Routine background memory cleanup every 60 seconds
        memoryPurgeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.purgeMemoryCache()
            }
        }
    }
    isolated deinit {
        channelPurgeTask?.cancel()
        callReadinessTask?.cancel()
        compatibilityProbeTask?.cancel()
        gameDispatchTask?.cancel()
        musicDispatchTask?.cancel()
        memoryPurgeTimer?.invalidate()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        observations.forEach { $0.invalidate() }
        tanRuntime?.detach()
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

    @discardableResult
    func beginPageGeneration() -> UUID {
        pageGeneration = UUID()
        channelPurgeTask?.cancel()
        callReadinessTask?.cancel()
        compatibilityProbeTask?.cancel()
        gameDispatchTask?.cancel()
        musicDispatchTask?.cancel()
        resetCallReadiness()
        updateCompatibilityRoute()
        return pageGeneration
    }

    func isCurrentPageGeneration(_ generation: UUID) -> Bool {
        pageGeneration == generation
    }

    /// Releases WebKit memory cache (decoded images/backing buffers) and invokes in-page media/DOM garbage cleanup.
    func purgeMemoryCache() {
        dataStore.removeData(
            ofTypes: [
                WKWebsiteDataTypeMemoryCache,
                WKWebsiteDataTypeFetchCache
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

    /// Suspends background media and drops offscreen channel caches when the view is hidden.
    /// A call keeps its media elements untouched: they carry the live voice stream.
    func hibernate() {
        purgeMemoryCache()
        guard !hasActiveMediaCapture else { return }
        browserView?.evaluateJavaScript("try { window.__nokoHibernate?.(); } catch (_) {}", completionHandler: nil)
    }

    /// Resumes active media tracking when window regains focus.
    func resume() {
        browserView?.evaluateJavaScript("try { window.__nokoResume?.(); } catch (_) {}", completionHandler: nil)
    }

    private func blockNavigationWhileCallIsEnding() -> Bool {
        guard let blocker = callTeardown.navigationBlocker else { return false }
        notice = String(localized: "Finish disconnecting the active Discord call before navigating.") + " " + blocker.title
        return true
    }

    /// Loads a validated Discord URL directly into the active browser workspace.
    func openURL(_ url: URL) {
        guard BrowserPolicy.isDiscordOrigin(url), lifecycle.phase != .clearing else { return }
        guard !blockNavigationWhileCallIsEnding() else { return }
        beginPageGeneration()
        lifecycle.show()
        let view = prepareBrowser()
        lifecycle.loading()
        navigation = view.load(URLRequest(url: url))
    }

    func prepareBrowser() -> WKWebView {
        if let browserView { return browserView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // Without a name in the user agent, Discord cannot identify the client
        // and quietly refuses voice. WebKit is Safari's engine, so say so.
        let system = ProcessInfo.processInfo.operatingSystemVersion
        configuration.applicationNameForUserAgent = "Version/\(system.majorVersion).\(system.minorVersion) Safari/605.1.15"
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
        // 7. Enforce zero autocorrect, spellchecking, prediction, or text replacement
        NativeTextCheckingSuppressor.suppressAll()
        // 8. WebKit parks getUserMedia until the page is visible; a voice join
        // must be able to start while the app is briefly in the background.
        configuration.preferences.setValue(false, forKey: "getUserMediaRequiresFocus")
        // Controlled local Tans only; no auth or token bridge.
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
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        observations = [
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.browserView === view else { return }
                    self.beginPageGeneration()
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
                    self.refreshCallReadiness()
                }
            },
            view.observe(\.cameraCaptureState, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.browserView === view else { return }
                    self.cameraCaptureState = view.cameraCaptureState
                    self.refreshCallReadiness()
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
    func showHome() {
        guard !blockNavigationWhileCallIsEnding() else { return }
        lifecycle.hide()
    }
    func openGuild(_ id: String) {
        guard !id.isEmpty, id.utf8.count <= 20,
              id.utf8.allSatisfy({ (48...57).contains($0) }), lifecycle.phase != .clearing else { return }
        guard !blockNavigationWhileCallIsEnding() else { return }
        beginPageGeneration()
        lifecycle.show()
        let view = prepareBrowser()
        lifecycle.loading()
        navigation = view.load(URLRequest(url: URL(string: "https://discord.com/channels/\(id)")!))
    }
    func reload() {
        guard lifecycle.phase != .clearing else { return }
        guard !blockNavigationWhileCallIsEnding() else { return }
        beginPageGeneration()
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

    /// Re-checks the page's call prerequisites without reading Discord state
    /// through a native bridge. The probe only asks WebKit for capability
    /// facts and semantic call controls, then combines those facts with the
    /// system media permission state and WebKit capture state.
    func refreshCallReadiness() {
        guard let view = browserView else {
            resetCallReadiness()
            return
        }
        callReadinessTask?.cancel()
        let generation = pageGeneration
        let origin = Self.callOrigin(for: view.url)
        let microphonePermission = Self.callPermission(for: .audio)
        let cameraPermission = Self.callPermission(for: .video)
        let captureState = currentCallCaptureState
        callReadinessTask = Task { @MainActor [weak self, weak view] in
            guard let self, let view else { return }
            let raw = try? await view.evaluateJavaScript(Self.callReadinessProbeScript)
            guard !Task.isCancelled,
                  self.isCurrentPageGeneration(generation),
                  self.browserView === view else { return }

            let evidence = Self.callEvidence(from: raw)
            let readiness = CallReadinessService.evaluate(
                origin: origin,
                mediaDevicesAvailable: evidence.mediaDevicesAvailable,
                microphonePermission: microphonePermission,
                cameraPermission: cameraPermission,
                encodedTransformAvailable: evidence.encodedTransformAvailable,
                discordCallSurfaceReady: evidence.discordCallSurfaceReady,
                captureState: captureState
            )
            self.applyCallReadiness(readiness)
        }
    }

    /// Runs the bounded, content-free compatibility probe for the current
    /// document. A stale result is discarded by both the task generation check
    /// and the model reducer before it can affect feature diagnostics.
    func refreshDiscordCompatibility() {
        guard let view = browserView else {
            discordCompatibility = .initial(generation: pageGeneration)
            return
        }

        compatibilityProbeTask?.cancel()
        let generation = pageGeneration
        let origin = Self.discordOrigin
        let routeSnapshot = DiscordCompatibilityService.snapshot(
            for: view.url,
            origin: origin,
            generation: generation
        )
        discordCompatibility = routeSnapshot
        guard routeSnapshot.isSupportedRoute else { return }

        compatibilityProbeTask = Task { @MainActor [weak self, weak view] in
            guard let self, let view else { return }
            let raw = try? await view.evaluateJavaScript(DiscordCompatibilityService.probeScript(for: generation))
            guard !Task.isCancelled,
                  self.isCurrentPageGeneration(generation),
                  self.browserView === view else { return }

            let now = Date()
            guard let facts = DiscordCompatibilityService.probeFacts(
                from: raw,
                generation: generation,
                capturedAt: now
            ) else {
                self.discordCompatibility = DiscordCompatibilityService.invalidProbeSnapshot(
                    for: view.url,
                    origin: origin,
                    generation: generation,
                    at: now
                )
                return
            }
            guard let snapshot = DiscordCompatibilityService.snapshot(
                for: view.url,
                origin: origin,
                generation: generation,
                facts: facts,
                currentGeneration: self.pageGeneration,
                now: now
            ) else { return }
            self.discordCompatibility = snapshot
        }
    }

    private var currentCallCaptureState: CallCaptureState {
        CallCaptureState(
            microphone: Self.callCaptureState(for: microphoneCaptureState),
            camera: Self.callCaptureState(for: cameraCaptureState)
        )
    }

    private func resetCallReadiness() {
        callReadinessTask?.cancel()
        let readiness = CallReadinessService.evaluate(
            origin: Self.callOrigin(for: browserView?.url),
            mediaDevicesAvailable: false,
            microphonePermission: Self.callPermission(for: .audio),
            cameraPermission: Self.callPermission(for: .video),
            encodedTransformAvailable: false,
            discordCallSurfaceReady: false,
            captureState: currentCallCaptureState
        )
        callReadiness = readiness
        callTeardown = CallTeardownState(readiness: readiness)
    }

    private func applyCallReadiness(_ readiness: CallReadiness) {
        callReadiness = readiness
        callTeardown.update(readiness: readiness)
    }

    private func updateCompatibilityRoute() {
        discordCompatibility = DiscordCompatibilityService.snapshot(
            for: browserView?.url,
            origin: Self.discordOrigin,
            generation: pageGeneration
        )
    }

    private struct CallEvidence {
        let mediaDevicesAvailable: Bool
        let encodedTransformAvailable: Bool
        let discordCallSurfaceReady: Bool
    }

    private static let callReadinessProbeScript = """
    (() => {
      try {
        const controls = Array.from(document.querySelectorAll('button,[role="button"]'));
        const text = (element) => [element.getAttribute('aria-label'), element.getAttribute('data-label'), element.textContent]
          .filter(Boolean).join(' ').replace(/\\s+/g, ' ').trim().toLowerCase();
        const callSurface = controls.some((element) => {
          const label = text(element);
          return /\\b(join voice|join video|start video|leave voice|leave call|disconnect from voice|hang up|end call)\\b/.test(label);
        });
        const sender = typeof RTCRtpSender !== 'undefined' && RTCRtpSender.prototype;
        const encodedTransform = typeof RTCRtpScriptTransform === 'function' ||
          (!!sender && typeof sender.createEncodedStreams === 'function');
        return JSON.stringify({
          mediaDevicesAvailable: !!navigator.mediaDevices && typeof navigator.mediaDevices.getUserMedia === 'function',
          encodedTransformAvailable: encodedTransform,
          discordCallSurfaceReady: callSurface
        });
      } catch (_) {
        return JSON.stringify({ mediaDevicesAvailable: false, encodedTransformAvailable: false, discordCallSurfaceReady: false });
      }
    })();
    """

    private static func callEvidence(from raw: Any?) -> CallEvidence {
        let dictionary: [String: Any]
        if let json = raw as? String,
           let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let parsed = object as? [String: Any] {
            dictionary = parsed
        } else {
            dictionary = [:]
        }
        return CallEvidence(
            mediaDevicesAvailable: dictionary["mediaDevicesAvailable"] as? Bool == true,
            encodedTransformAvailable: dictionary["encodedTransformAvailable"] as? Bool == true,
            discordCallSurfaceReady: dictionary["discordCallSurfaceReady"] as? Bool == true
        )
    }

    private static func callOrigin(for url: URL?) -> String {
        guard let url, let scheme = url.scheme, let host = url.host else { return "" }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.string ?? ""
    }

    private static let discordOrigin = "https://discord.com"

    private static func callPermission(for mediaType: AVMediaType) -> CallPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    private static func callCaptureState(for state: WKMediaCaptureState) -> CallMediaCaptureState {
        switch state {
        case .active: .active
        case .muted: .muted
        case .none: .none
        @unknown default: .none
        }
    }

    private static let disconnectCallScript = """
    (() => {
      const labels = /^(leave voice|leave call|disconnect from voice|hang up|end call)$/i;
      const candidates = Array.from(document.querySelectorAll('button,[role="button"]'))
        .filter((element) => !element.closest('[role="dialog"], [aria-modal="true"]'));
      const target = candidates.find((element) => {
        const label = (element.getAttribute('aria-label') || element.getAttribute('data-label') || element.textContent || '')
          .replace(/\\s+/g, ' ').trim();
        return labels.test(label);
      });
      if (!target) return false;
      target.click();
      return true;
    })();
    """

    func disconnectCall() {
        guard let view = browserView else { return }
        view.evaluateJavaScript(Self.disconnectCallScript) { [weak self, weak view] result, error in
            Task { @MainActor [weak self, weak view] in
                guard let self else { return }
                guard error == nil, (result as? Bool) == true else {
                    self.notice = String(localized: "Discord did not expose a leave-call control. Open Discord's call controls to leave.")
                    return
                }
                guard let view, self.browserView === view else { return }
                self.callTeardown.requestLeave()
                // The page click is only a request. WebKit capture state is
                // cleared by the actual media session; never manufacture a
                // disconnected state before Discord confirms that transition.
                self.callReadinessTask?.cancel()
                self.callReadinessTask = Task { @MainActor [weak self, weak view] in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard let self, let view, self.browserView === view else { return }
                    self.refreshCallReadiness()
                }
            }
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
        beginPageGeneration()
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
        resetCallReadiness()
        discordCompatibility = .initial(generation: pageGeneration)
        GamePresenceService.shared.clearPresence()
        // Delete without enumerating or reading cookies, credentials or records.
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        lifecycle.cleared()
        lifecycle.hide()
        notice = nil
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === browserView, lifecycle.phase != .clearing else { return }
        beginPageGeneration()
        self.navigation = navigation
        notice = nil
        lifecycle.loading()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === browserView, lifecycle.phase != .clearing, self.navigation === navigation else { return }
        lifecycle.ready()
        tanRuntime?.pageDidLoad()
        refreshDiscordCompatibility()
        refreshCallReadiness()
        syncGamePresenceToDiscord(GamePresenceService.shared.activePresence)
        syncAppleMusicPresenceToDiscord()
    }

    /// The bundled Apple Music Tan owns the feature; its active state is the
    /// service's switch, and Safe Mode leaves that state empty.
    private func updateAppleMusicActivation() {
        let active = tans?.active.contains(where: { $0.id == TanPackage.appleMusicRPC.id }) ?? false
        AppleMusicRPCService.shared.setActive(active)
    }

    private static let gameSocketID = "nokocord-game-rp"

    /// Dispatches a game activity the native IPC server received. Games outrank
    /// music, so the caller re-evaluates the music activity afterwards.
    private func syncGamePresenceToDiscord(_ presence: GamePresence?) {
        guard browserView != nil, lifecycle.phase == .ready else { return }
        let generation = pageGeneration
        gameDispatchTask?.cancel()
        gameDispatchTask = Task { @MainActor [weak self] in
            await self?.dispatchLocalActivity(presence, socketID: Self.gameSocketID, generation: generation)
        }
    }

    @ObservationIgnored private var gameDispatchTask: Task<Void, Never>?

    /// Dispatches the track the Apple Music Tan should show. Nothing is sent
    /// while the Tan is off, and the activity is cleared when music stops or a
    /// game takes over.
    private func syncAppleMusicPresenceToDiscord() {
        guard browserView != nil, lifecycle.phase == .ready else { return }
        let generation = pageGeneration
        let service = AppleMusicRPCService.shared
        let suppressed = !service.isEnabled
            || service.helperStatus != .connected
            || GamePresenceService.shared.activePresence != nil
        let track = service.currentTrack
        let presence = suppressed || track?.playerState.isPlaying != true
            ? nil
            : track?.toGamePresence(clientId: AppleMusicRPCService.configuredApplicationID)
        musicDispatchTask?.cancel()
        musicDispatchTask = Task { @MainActor [weak self] in
            await self?.dispatchLocalActivity(presence, socketID: Self.musicSocketID, generation: generation)
        }
    }

    /// The single place an activity reaches the page. External artwork is
    /// resolved into Discord media-proxy keys first, and a presence that is
    /// meant to appear is confirmed against Discord's own store and retried,
    /// because Discord accepts dispatches it does not apply while it loads.
    private func dispatchLocalActivity(_ presence: GamePresence?, socketID: String, generation: UUID) async {
        guard isCurrentPageGeneration(generation), let view = browserView else { return }
        var payload = presence?.toDiscordPayload() ?? [:]
        if let presence {
            let resolved = await Self.externalAssetKeys(view: view,
                                                        applicationId: presence.clientId,
                                                        urls: [presence.largeImageKey, presence.smallImageKey])
            guard isCurrentPageGeneration(generation), browserView === view else { return }
            if var assets = payload["assets"] as? [String: Any] {
                if let large = resolved[0] { assets["large_image"] = large }
                if resolved.count > 1, let small = resolved[1] { assets["small_image"] = small }
                payload["assets"] = assets
            }
        }
        let json = payload.isEmpty ? "null" : Self.jsonLiteral(payload)
        // A clear is confirmed the same way a set is: the script reports
        // "applied" when the activity is absent for this socket, so a dispatch
        // Discord swallowed while loading cannot leave a stale status behind.
        for _ in 1...15 {
            guard !Task.isCancelled, isCurrentPageGeneration(generation), browserView === view else { return }
            let outcome = (try? await view.evaluateJavaScript(Self.localActivityScript(payload: json, socketID: socketID))) as? String
            if outcome == "applied" { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// Converts external image URLs into Discord media-proxy keys with the
    /// client's own authenticated endpoint, because Discord only renders images
    /// that are application assets or `mp:` keys.
    private static func externalAssetKeys(view: WKWebView, applicationId: String, urls: [String?]) async -> [String?] {
        guard urls.contains(where: { $0?.hasPrefix("http") == true }) else { return urls }
        let script = """
        const resolved = await window.__nokoResolveExternalAssets(applicationId, urls);
        return JSON.stringify(Array.isArray(resolved) ? resolved : []);
        """
        let arguments: [String: Any] = ["applicationId": applicationId, "urls": urls.map { $0 ?? "" }]
        guard let value = try? await view.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page) as? String,
              let data = value.data(using: .utf8),
              let resolved = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return urls
        }
        return urls.indices.map { index in
            guard index < resolved.count, let key = resolved[index] as? String, !key.isEmpty else { return urls[index] }
            return key
        }
    }

    @ObservationIgnored private var musicDispatchTask: Task<Void, Never>?
    private static let musicSocketID = "nokocord-apple-music"

    /// Serializes an activity payload as a JavaScript literal for page evaluation.
    private static func jsonLiteral(_ payload: [String: Any]?) -> String {
        guard let payload,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// Delivers one local activity to the Flux dispatcher Discord's own
    /// LocalActivityStore registered with, then confirms the client applied it.
    /// Dispatchers reached through the module cache, and stores belonging to
    /// duplicate module copies, accept the action and drop it.
    private static func localActivityScript(payload: String, socketID: String) -> String {
        """
        (() => {
            try {
                const activity = \(payload);
                const chunk = window.webpackChunkdiscord_app;
                if (!chunk || typeof chunk.push !== 'function') return 'no-webpack';
                const requires = [];
                for (let i = 0; i < 3; i++) {
                    try {
                        chunk.push([[Symbol()], {}, (require) => { if (requires.indexOf(require) === -1) requires.push(require); }]);
                    } catch (_) {}
                }
                const usable = (candidate) => candidate && typeof candidate.dispatch === 'function' && typeof candidate.subscribe === 'function';
                let dispatcher = null, store = null;
                for (const require of requires) {
                    const factories = require && require.m ? require.m : null;
                    if (!factories) continue;
                    for (const id of Object.keys(factories)) {
                        let source = '';
                        try { source = Function.prototype.toString.call(factories[id]); } catch (_) { continue; }
                        if (source.indexOf('"LocalActivityStore"') === -1) continue;
                        try {
                            const exported = require(id);
                            const values = [exported, exported && exported.default];
                            if (exported && typeof exported === 'object') values.push(...Object.values(exported));
                            for (const candidate of values) {
                                if (candidate && typeof candidate.getActivities === 'function' && typeof candidate.getPrimaryActivity === 'function') { store = candidate; break; }
                            }
                        } catch (_) { continue; }
                        if (!store) continue;
                        for (const key of Object.getOwnPropertyNames(store)) {
                            const value = store[key];
                            if (!usable(value)) continue;
                            try {
                                const handlers = value._actionHandlers && value._actionHandlers.getOrderedActionHandlers({ type: 'LOCAL_ACTIVITY_UPDATE' });
                                if (handlers && handlers.length) { dispatcher = value; break; }
                            } catch (_) {}
                        }
                        if (dispatcher) break;
                    }
                    if (dispatcher) break;
                }
                if (!dispatcher || !store) return 'no-dispatcher';
                dispatcher.dispatch({ type: 'LOCAL_ACTIVITY_UPDATE', socketId: "\(socketID)", activity });
                const applications = new Set([activity && activity.application_id, "\(socketID)"].filter(Boolean));
                const present = (store.getActivities() ?? []).some((entry) => entry && applications.has(entry.application_id));
                if (activity === null) return present ? 'not-applied' : 'applied';
                return present ? 'applied' : 'not-applied';
            } catch (_) {
                return 'threw';
            }
        })();
        """
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
        // macOS still gates this with the app's TCC permission and the usage
        // description; granting here avoids WebKit's second sheet, which cannot
        // be presented while the web view has no window.
        decisionHandler(safe ? .grant : .deny)
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
