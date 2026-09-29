import AppKit
import WebKit
import CryptoKit

enum TanBridgeDecision: Equatable {
    case appearanceRead
    case status(TanDiagnostic.Event)
    case rejected
}

enum TanAppBridgeAction: String, Equatable {
    case toggleQuickSwitcher
    case toggleBookmarks
    case toggleTans
    case toggleZenMode
    case channelChanged
    case saveBookmark
    case openMedia
    case notification
}

enum TanAppBridgeDecision: Equatable {
    case allowed(TanAppBridgeAction)
    case rejected
}

enum TanHealthDisplayState: String, CaseIterable, Equatable {
    case awaitingApproval
    case enabledHealthy
    case disabled
    case failedDegraded
    case quarantined
    case reloadRequired
}

enum TanHealthAction: String, Equatable {
    case approveAndEnable
    case enable
    case disable
    case retry
    case recover
    case reload
}

struct TanHealthPresentation: Equatable {
    let state: TanHealthDisplayState
    let title: String
    let message: String
    let action: TanHealthAction?

    static func make(record: TanTrustRecord?, isEnabled: Bool, reloadRequired: Bool) -> TanHealthPresentation {
        if record?.health == .quarantined {
            return forState(.quarantined)
        }
        if record?.health == .failed {
            return forState(.failedDegraded)
        }
        if record == nil || record?.health == .awaitingApproval || record?.approvedAt == nil {
            return forState(.awaitingApproval)
        }
        if reloadRequired, isEnabled {
            return forState(.reloadRequired)
        }
        return forState(isEnabled ? .enabledHealthy : .disabled)
    }

    static func forState(_ state: TanHealthDisplayState) -> TanHealthPresentation {
        switch state {
        case .awaitingApproval:
            return TanHealthPresentation(
                state: state,
                title: "Awaiting approval",
                message: "Review this Tan before it runs in Discord.",
                action: .approveAndEnable
            )
        case .enabledHealthy:
            return TanHealthPresentation(
                state: state,
                title: "Healthy",
                message: "This Tan is enabled and its approved code is running.",
                action: .disable
            )
        case .disabled:
            return TanHealthPresentation(
                state: state,
                title: "Disabled",
                message: "This Tan is installed but will not modify Discord.",
                action: .enable
            )
        case .failedDegraded:
            return TanHealthPresentation(
                state: state,
                title: "Failed or degraded",
                message: "NokoCord stopped this Tan after a runtime problem. Discord remains available.",
                action: .retry
            )
        case .quarantined:
            return TanHealthPresentation(
                state: state,
                title: "Quarantined",
                message: "This Tan is disabled after repeated failures. Recover it only if you trust the package.",
                action: .recover
            )
        case .reloadRequired:
            return TanHealthPresentation(
                state: state,
                title: "Reload required",
                message: "Reload Discord to apply this Tan change safely.",
                action: .reload
            )
        }
    }
}

@MainActor
final class TanRuntime {
    static let appBridgeContentWorldName = "NokoCord.App"
    static let maxTanResources = 256
    static let maxTanBridgePayloadBytes = 8 * 1024
    static let maxAppBridgePayloadBytes = 16 * 1024

    let manager: TanManager
    private weak var view: WKWebView?
    private var controller: WKUserContentController?
    private var configured: [TanPackage] = []
    private var worlds: [String: WKContentWorld] = [:]
    private var activeHashes: [String: String] = [:]
    var retainedWorldCount: Int { worlds.count }
    private var handlers: [TanMessageHandler] = []
    private var generation = UUID()
    private var transitionTask: Task<Void, Never>?
    private var livePackages: [String: TanPackage] = [:]
    private var safeModeNeedsReload = false
    fileprivate private(set) var runtimeNonce = UUID().uuidString
    fileprivate let allowedOrigin: String
    private(set) var compatibility = DiscordCompatibilitySnapshot.initial()
    private var appHandler: NokoAppMessageHandler?
    var onCompatibilityChange: ((DiscordCompatibilitySnapshot) -> Void)?
    var onToggleTans: (() -> Void)?
    var onToggleQuickSwitcher: (() -> Void)?
    var onToggleBookmarks: (() -> Void)?
    var onOpenMedia: ((URL, Bool) -> Void)?
    var onToggleZenMode: (() -> Void)?
    var onChannelChanged: (() -> Void)?
    var onSaveBookmark: ((NokoBookmark) -> Void)?

    init(manager: TanManager, allowedOrigin: String = "https://discord.com") {
        self.manager = manager; self.allowedOrigin = allowedOrigin
    }
    func prepare(_ controller: WKUserContentController) {
        self.controller = controller
        configureScripts()
    }
    func attach(_ view: WKWebView) {
        self.view = view
        view.isInspectable = manager.developerMode
        updateCompatibility()
    }
    func detach() {
        generation = UUID()
        transitionTask = nil
        clearHandlers()
        controller?.removeAllUserScripts()
        controller = nil; view = nil; configured = []; livePackages = [:]
        worlds.removeAll(); activeHashes.removeAll()
        safeModeNeedsReload = false
        compatibility = .initial(generation: generation)
        onCompatibilityChange?(compatibility)
    }
    func configurationChanged() {
        let old = configured
        let needsReload = (old + manager.active).contains { $0.manifest.target == .page || $0.manifest.requiresReload }
        let exitingSafeMode = safeModeNeedsReload && !manager.safeMode
        configureScripts()
        view?.isInspectable = manager.developerMode
        if exitingSafeMode {
            manager.reloadRequired = true
            return
        }
        if needsReload, view?.url != nil { manager.reloadRequired = true }
        if manager.safeMode, view?.url != nil {
            // Page-world code is trusted and may not be fully reversible. A new
            // document with no scripts is the reliable plain-Discord fallback.
            generation = UUID(); transitionTask = nil; livePackages.removeAll(); worlds.removeAll()
            view?.reload()
            return
        }
        applyLive(stopping: old, starting: manager.active.filter { $0.manifest.target != .page && !$0.manifest.requiresReload })
    }
    func pageDidLoad() {
        manager.reloadRequired = false
        if !manager.safeMode { safeModeNeedsReload = false }
        updateCompatibility()
        // DOM Tans also work when Discord moves from /app to /channels during
        // startup. Registration replaces its own prior instance, never a view.
        applyLive(stopping: [], starting: manager.active.filter { $0.manifest.target != .page && !$0.manifest.requiresReload })
    }
    func locationChanged() {
        updateCompatibility()
        guard let url = view?.url else { return }
        if safeModeNeedsReload, !manager.safeMode {
            manager.reloadRequired = true
            return
        }
        if !Self.accepts(url, origin: allowedOrigin) {
            applyLive(stopping: configured + Array(livePackages.values), starting: [])
        } else {
            applyLive(stopping: [], starting: manager.active.filter { $0.manifest.target != .page && !$0.manifest.requiresReload })
            if manager.active.contains(where: { ($0.manifest.target == .page || $0.manifest.requiresReload) && livePackages[$0.id] == nil }) {
                manager.reloadRequired = true
            }
        }
    }
    private func configureScripts() {
        guard let controller else { return }
        clearHandlers(); controller.removeAllUserScripts()
        configured = []
        activeHashes = [:]
        runtimeNonce = UUID().uuidString
        guard !manager.safeMode else {
            safeModeNeedsReload = true
            return
        }
        configured = manager.active
        activeHashes = Dictionary(uniqueKeysWithValues: configured.map { ($0.id, $0.contentHash) })
        for package in configured {
            let world = world(package)
            let handler = TanMessageHandler(runtime: self, package: package)
            controller.addScriptMessageHandler(handler, contentWorld: world, name: Self.handlerName(package))
            handlers.append(handler)
            controller.addUserScript(WKUserScript(source: Self.source(package, allowedOrigin: allowedOrigin, runtimeNonce: runtimeNonce), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        }
        if allowedOrigin == "https://discord.com" {
            let app = NokoAppMessageHandler(runtime: self)
            controller.add(app, contentWorld: Self.appBridgeWorld, name: "nokoCordApp")
            appHandler = app
            controller.addUserScript(WKUserScript(source: Self.discordInjectedScript(nonce: runtimeNonce), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.appBridgeWorld))
        }
    }
    private func clearHandlers() {
        for package in configured { controller?.removeScriptMessageHandler(forName: Self.handlerName(package), contentWorld: world(package)) }
        handlers.removeAll()
        if allowedOrigin == "https://discord.com" {
            controller?.removeScriptMessageHandler(forName: "nokoCordApp", contentWorld: Self.appBridgeWorld)
            appHandler = nil
        }
    }
    private func applyLive(stopping: [TanPackage], starting: [TanPackage]) {
        generation = UUID(); let current = generation
        guard let view else { return }
        let pendingStops = Array(Dictionary((stopping + Array(livePackages.values)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values)
        for package in starting { livePackages[package.id] = package }
        let previousTask = transitionTask
        transitionTask = Task { @MainActor [weak self, weak view] in
            // Keep WebKit evaluations ordered. Otherwise a newer stop can run
            // before an older start finishes and leave that old Tan active.
            await previousTask?.value
            guard let self, let view else { return }
            defer { if self.generation == current { self.transitionTask = nil } }
            for package in pendingStops {
                guard self.generation == current else { return }
                let source = "globalThis[\(Self.quote(Self.key(package)))]?.stop();"
                try? await self.evaluate(source, view: view, world: self.world(package))
                guard self.generation == current else { return }
                self.livePackages.removeValue(forKey: package.id)
            }
            for package in starting {
                guard self.generation == current, !self.manager.safeMode,
                      let url = view.url, Self.accepts(url, origin: self.allowedOrigin) else { return }
                self.livePackages[package.id] = package
                do { try await self.evaluate(Self.source(package, allowedOrigin: self.allowedOrigin, runtimeNonce: self.runtimeNonce), view: view, world: self.world(package)) }
                catch { self.manager.record(package.id, event: .failed) }
            }
            guard self.generation == current else { return }
            let retained = Set(self.configured.map(\.id)).union(self.livePackages.keys)
            self.worlds = self.worlds.filter { retained.contains($0.key) }
        }
    }
    private func evaluate(_ source: String, view: WKWebView, world: WKContentWorld) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            view.evaluateJavaScript(source, in: nil, in: world) { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
    fileprivate func receive(_ message: WKScriptMessage, package: TanPackage, fingerprint: String, reply: @escaping (Any?, String?) -> Void) {
        guard message.webView === view, message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url, Self.accepts(url, origin: allowedOrigin),
              message.frameInfo.securityOrigin.protocol == url.scheme,
              message.frameInfo.securityOrigin.host == url.host,
              (message.frameInfo.securityOrigin.port == 0 ? 443 : message.frameInfo.securityOrigin.port) == (url.port ?? 443),
              !manager.safeMode, manager.enabledIDs.contains(package.id), activeHashes[package.id] == fingerprint,
              let body = message.body as? [String: Any] else { reply(nil, "Request rejected"); return }
        switch Self.validateTanBridgeRequest(body, package: package, runtimeNonce: runtimeNonce) {
        case .status(let event):
            manager.record(package.id, event: event)
            reply(["ok": true], nil)
        case .appearanceRead:
            let name = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            reply(["appearance": name == .darkAqua ? "dark" : "light"], nil)
        case .rejected:
            manager.record(package.id, event: .rejected)
            reply(nil, "Request rejected")
        }
    }
    static func accepts(_ url: URL, origin: String) -> Bool {
        DiscordCompatibilityService.accepts(url, origin: origin)
    }

    private func updateCompatibility() {
        compatibility = DiscordCompatibilityService.snapshot(for: view?.url, origin: allowedOrigin, generation: generation)
        onCompatibilityChange?(compatibility)
    }
    private static var appBridgeWorld: WKContentWorld { .world(name: appBridgeContentWorldName) }

    static func validateTanBridgeRequest(
        _ body: [String: Any],
        package: TanPackage,
        runtimeNonce: String
    ) -> TanBridgeDecision {
        guard body.count <= 8,
              boundedBridgePayload(body, maximumBytes: maxTanBridgePayloadBytes),
              boundedBridgeString(body["type"], maximumBytes: 32),
              body["tanID"] as? String == package.id,
              body["contentHash"] as? String == package.contentHash,
              body["runtimeNonce"] as? String == runtimeNonce,
              boundedBridgeString(body["runtimeNonce"], maximumBytes: 128),
              boundedBridgeString(body["tanID"], maximumBytes: 128),
              boundedBridgeString(body["contentHash"], maximumBytes: 128) else {
            return .rejected
        }

        let identityKeys: Set<String> = ["type", "tanID", "contentHash", "runtimeNonce"]
        guard let type = body["type"] as? String else { return .rejected }
        switch type {
        case "status":
            guard Set(body.keys) == identityKeys.union(["state"]),
                  let rawState = body["state"] as? String,
                  boundedBridgeString(rawState, maximumBytes: 32),
                  let event = TanDiagnostic.Event(rawValue: rawState),
                  event != .rejected else { return .rejected }
            return .status(event)
        case "capability":
            guard Set(body.keys) == identityKeys.union(["capability"]),
                  package.manifest.target == .isolated,
                  package.manifest.capabilities.contains(.appearanceRead),
                  body["capability"] as? String == TanCapability.appearanceRead.rawValue else {
                return .rejected
            }
            return .appearanceRead
        default:
            return .rejected
        }
    }

    static func validateAppBridgeRequest(_ body: [String: Any], runtimeNonce: String) -> TanAppBridgeDecision {
        guard body.count <= 10,
              boundedBridgePayload(body, maximumBytes: maxAppBridgePayloadBytes),
              body["runtimeNonce"] as? String == runtimeNonce,
              boundedBridgeString(body["runtimeNonce"], maximumBytes: 128),
              let rawAction = body["action"] as? String,
              let action = TanAppBridgeAction(rawValue: rawAction),
              boundedBridgeString(rawAction, maximumBytes: 64) else {
            return .rejected
        }

        let baseKeys: Set<String> = ["action", "runtimeNonce"]
        switch action {
        case .toggleQuickSwitcher, .toggleBookmarks, .toggleTans, .toggleZenMode, .channelChanged:
            return Set(body.keys) == baseKeys ? .allowed(action) : .rejected
        case .notification:
            guard Set(body.keys) == baseKeys.union(["title", "body"]),
                  let title = body["title"] as? String,
                  let message = body["body"] as? String,
                  boundedBridgeString(title, maximumBytes: 128),
                  boundedBridgeString(message, maximumBytes: 512, allowEmpty: true),
                  !title.isEmpty else { return .rejected }
            return .allowed(action)
        case .openMedia:
            guard Set(body.keys) == baseKeys.union(["url", "isVideo"]),
                  let url = body["url"] as? String,
                  !url.isEmpty,
                  boundedBridgeString(url, maximumBytes: 2_048),
                  body["isVideo"] as? Bool != nil else { return .rejected }
            return .allowed(action)
        case .saveBookmark:
            let requiredKeys = baseKeys.union(["messageId", "authorName", "channelName", "serverName", "content", "messageURL"])
            let optionalKeys = Set(["authorAvatarURL", "mediaURL"])
            guard Set(body.keys).isSubset(of: requiredKeys.union(optionalKeys)),
                  Set(body.keys).isSuperset(of: requiredKeys),
                  boundedBridgeString(body["messageId"], maximumBytes: 128),
                  boundedBridgeString(body["authorName"], maximumBytes: 256),
                  boundedBridgeString(body["channelName"], maximumBytes: 256),
                  boundedBridgeString(body["serverName"], maximumBytes: 256, allowEmpty: true),
                  boundedBridgeString(body["content"], maximumBytes: 8_192, allowEmpty: true),
                  boundedBridgeString(body["messageURL"], maximumBytes: 2_048),
                  boundedOptionalBridgeString(body["authorAvatarURL"], maximumBytes: 2_048),
                  boundedOptionalBridgeString(body["mediaURL"], maximumBytes: 2_048) else { return .rejected }
            return .allowed(action)
        }
    }

    private static func boundedBridgeString(_ value: Any?, maximumBytes: Int, allowEmpty: Bool = false) -> Bool {
        guard let value = value as? String else { return false }
        return (allowEmpty || !value.isEmpty) && value.utf8.count <= maximumBytes
    }

    private static func boundedBridgePayload(_ body: [String: Any], maximumBytes: Int) -> Bool {
        var bytes = 0
        for (key, value) in body {
            bytes += key.utf8.count
            switch value {
            case let value as String:
                bytes += value.utf8.count
            case let value as Bool:
                bytes += value ? 4 : 5
            case is NSNull:
                bytes += 4
            default:
                return false
            }
            if bytes > maximumBytes { return false }
        }
        return true
    }

    private static func boundedOptionalBridgeString(_ value: Any?, maximumBytes: Int) -> Bool {
        if value is NSNull || value == nil { return true }
        return boundedBridgeString(value, maximumBytes: maximumBytes, allowEmpty: true)
    }

    private func world(_ package: TanPackage) -> WKContentWorld {
        if package.manifest.target == .page { return .page }
        if let world = worlds[package.id] { return world }
        let world = WKContentWorld.world(name: "NokoTan." + package.id)
        worlds[package.id] = world
        return world
    }
    static func handlerName(_ package: TanPackage) -> String { "nokoTan_" + SHA256.hash(data: Data(package.id.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func key(_ package: TanPackage) -> String { "__nokoTan_" + package.id }
    static func quote(_ string: String) -> String { String(data: try! JSONEncoder().encode(string), encoding: .utf8)! }
    static func source(_ package: TanPackage, allowedOrigin: String, runtimeNonce: String = "runtime-fixture") -> String {
        let nativeAllowed = package.manifest.target == .isolated && package.manifest.capabilities.contains(.appearanceRead)
        return #"""
        (() => {
          'use strict';
          if (location.origin !== \#(quote(allowedOrigin))) return;
          const allowed = () => location.origin === \#(quote(allowedOrigin)) &&
            (location.origin !== 'https://discord.com' || location.pathname === '/app' || location.pathname.startsWith('/channels/'));
          if (!allowed()) return;
          const key = \#(quote(key(package)));
          globalThis[key]?.stop();
          let definition = null, cleanup = null, style = null, stopped = false;
          const identity = Object.freeze({
            tanID: \#(quote(package.id)),
            contentHash: \#(quote(package.contentHash)),
            runtimeNonce: \#(quote(runtimeNonce))
          });
          const send = body => window.webkit.messageHandlers[\#(quote(handlerName(package)))].postMessage({ ...body, ...identity });
          const report = state => { try { send({type:'status', state}).catch(() => {}); } catch {} };
          const disposers = new Set();
          let timerCount = 0, listenerCount = 0, mountCount = 0;
          const own = dispose => {
            if (stopped || disposers.size >= \#(String(maxTanResources))) { dispose(); throw new Error('Resource limit reached'); }
            disposers.add(dispose);
            return () => { if (disposers.delete(dispose)) dispose(); };
          };
          const state = {
            stop() {
              if (stopped) return; stopped = true;
              document.removeEventListener('DOMContentLoaded', start);
              let failed = false;
              try { if (typeof cleanup === 'function') cleanup(); } catch { failed = true; }
              try { definition?.stop?.(); } catch { failed = true; }
              for (const dispose of disposers) { try { dispose(); } catch { failed = true; } }
              disposers.clear(); style?.remove();
              timerCount = 0; listenerCount = 0; mountCount = 0;
              cleanup = null; definition = null; style = null;
              if (globalThis[key] === state) delete globalThis[key];
              if (failed) report('failed');
              report('stopped');
            }
          };
          globalThis[key] = state;
          const NokoTan = Object.freeze({
            register(value) { if (definition || !value || typeof value.start !== 'function') throw new Error('Invalid lifecycle'); definition = value; },
            onCleanup(dispose) { if (typeof dispose !== 'function') throw new Error('Invalid cleanup'); return own(dispose); },
            listen(target, type, listener, options) {
              if (listenerCount >= 128) throw new Error('Resource limit reached');
              target.addEventListener(type, listener, options);
              listenerCount++;
              const capture = typeof options === 'boolean' ? options : !!options?.capture;
              return own(() => { target.removeEventListener(type, listener, capture); listenerCount = Math.max(0, listenerCount - 1); });
            },
            interval(callback, milliseconds) {
              if (timerCount >= 64) throw new Error('Resource limit reached');
              const timer = setInterval(() => { if (!stopped) callback(); }, Math.max(16, milliseconds));
              timerCount++;
              return own(() => { clearInterval(timer); timerCount = Math.max(0, timerCount - 1); });
            },
            timeout(callback, milliseconds) {
              if (timerCount >= 64) throw new Error('Resource limit reached');
              let cancel;
              const timer = setTimeout(() => { cancel(); if (!stopped) callback(); }, Math.max(0, milliseconds));
              timerCount++;
              cancel = own(() => { clearTimeout(timer); timerCount = Math.max(0, timerCount - 1); }); return cancel;
            },
            mount(element, parent = document.body) {
              if (mountCount >= 64) throw new Error('Resource limit reached');
              parent.append(element); mountCount++;
              return own(() => { element.remove(); mountCount = Math.max(0, mountCount - 1); });
            },
            appearance: () => \#(nativeAllowed ? "send({type:'capability',capability:'appearance.read'})" : "Promise.reject(new Error('Capability not granted'))")
          });
          function start() {
            if (stopped || !allowed()) return;
            try {
              const css = \#(quote(package.css ?? ""));
              if (css) { style = document.createElement('style'); style.setAttribute('data-noko-tan', \#(quote(package.id))); style.textContent = css; (document.head || document.documentElement).append(style); }
              if (definition) {
                const result = definition.start(NokoTan);
                if (result && typeof result.then === 'function') throw new Error('Async lifecycle is not supported in schema 1');
                cleanup = result;
              }
              report('started');
            } catch { state.stop(); report('failed'); }
          }
          try {
            \#(package.javascript ?? "")
            if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, {once:true}); else start();
          } catch { state.stop(); report('failed'); }
        })();
        //# sourceURL=nokotan://\#(package.id)/main.js
        """#
    }
    static var discordInjectedScript: String { discordInjectedScript(nonce: "runtime-fixture") }
    static func discordInjectedScript(nonce: String) -> String { #"""
    (() => {
      'use strict';
      if (location.origin !== 'https://discord.com') return;
      if (!(location.pathname === '/app' || location.pathname === '/channels' || location.pathname.startsWith('/channels/'))) return;
      if (window.__nokoCordAppInjected) return;
      window.__nokoCordAppInjected = true;
      const __nokoCordRuntimeNonce = \#(quote(nonce));
      const postApp = (body) => {
        try {
          const handler = window.webkit?.messageHandlers?.nokoCordApp;
          if (handler) handler.postMessage({ ...body, runtimeNonce: __nokoCordRuntimeNonce });
        } catch (_) {}
      };

      // 0a. Block Discord Science Telemetry & Analytics Tracking
      try {
        const isTelemetryUrl = (url) => {
          if (!url) return false;
          const str = String(url);
          return str.includes('/api/v9/science') ||
                 str.includes('/api/v9/track') ||
                 str.includes('/api/v9/telemetry') ||
                 str.includes('sentry.io');
        };

        if (window.fetch) {
          const origFetch = window.fetch;
          window.fetch = function(resource, init) {
            const url = (typeof resource === 'string') ? resource : (resource?.url || '');
            if (isTelemetryUrl(url)) {
              return Promise.resolve(new Response(null, { status: 204, statusText: 'No Content' }));
            }
            return origFetch.apply(this, arguments);
          };
        }

        if (window.XMLHttpRequest) {
          const origOpen = XMLHttpRequest.prototype.open;
          const origSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function(method, url) {
            this.__nokoBlocked = isTelemetryUrl(url);
            return origOpen.apply(this, arguments);
          };
          XMLHttpRequest.prototype.send = function() {
            if (this.__nokoBlocked) {
              try {
                Object.defineProperty(this, 'status', { value: 204, writable: false });
                Object.defineProperty(this, 'readyState', { value: 4, writable: false });
                Object.defineProperty(this, 'responseText', { value: '', writable: false });
              } catch (_) {}
              setTimeout(() => {
                try {
                  this.dispatchEvent(new Event('readystatechange'));
                  this.dispatchEvent(new Event('load'));
                  this.dispatchEvent(new Event('loadend'));
                } catch (_) {}
              }, 1);
              return;
            }
            return origSend.apply(this, arguments);
          };
        }

        if (navigator.sendBeacon) {
          const origBeacon = navigator.sendBeacon;
          navigator.sendBeacon = function(url, data) {
            if (isTelemetryUrl(url)) return true;
            return origBeacon.apply(this, arguments);
          };
        }
      } catch (_) {}

      // 0b. Suppress spellchecking and red underlines on active input editors
      try {
        const suppressSpellcheck = (el) => {
          if (!el || !(el instanceof HTMLElement)) return;
          if (el.isContentEditable || el.tagName === 'TEXTAREA' || el.tagName === 'INPUT' || el.getAttribute('role') === 'textbox') {
            try {
              el.spellcheck = false;
              el.setAttribute('spellcheck', 'false');
              el.setAttribute('autocorrect', 'off');
              el.setAttribute('data-gramm', 'false');
            } catch (_) {}
          }
        };
        window.addEventListener('focusin', (e) => suppressSpellcheck(e.target), true);
      } catch (_) {}

      const onReady = (fn) => {
        if (document.readyState === 'interactive' || document.readyState === 'complete') {
          fn();
        } else {
          document.addEventListener('DOMContentLoaded', fn, { once: true });
        }
      };

      // 1. Inject Native macOS App Styling (Traffic lights padding, overlay scrollbars, font smoothing, hide web nags)
      const injectStyles = () => {
        try {
          if (document.getElementById('nokocord-native-overrides')) return;
          const target = document.head || document.documentElement;
          if (!target) {
            onReady(injectStyles);
            return;
          }
          const style = document.createElement('style');
          style.id = 'nokocord-native-overrides';
          style.textContent = `
          /* Window traffic lights space in server list */
          nav[class*="guilds_"],
          div[class*="guilds_"][class*="wrapper_"],
          ul[class*="tree_"] {
            padding-top: 32px !important;
          }

          /* Window dragging on Discord top header (native macOS window feel) */
          [class*="subtitleContainer_"],
          [class*="headerBar_"],
          section[class*="title_"],
          div[class*="subtitleContainer_"] > section {
            -webkit-app-region: drag !important;
          }
          [class*="subtitleContainer_"] button,
          [class*="subtitleContainer_"] a,
          [class*="subtitleContainer_"] input,
          [class*="subtitleContainer_"] [role="button"],
          [class*="subtitleContainer_"] [tabindex],
          [class*="toolbar_"],
          [class*="searchBar_"],
          [class*="children_"] {
            -webkit-app-region: no-drag !important;
          }

          /* macOS typography & subpixel antialiasing */
          html, body, button, input, select, textarea {
            -webkit-font-smoothing: antialiased !important;
            -moz-osx-font-smoothing: grayscale !important;
            text-rendering: optimizeLegibility !important;
          }

          /* Prevent rubber banding & drag ghosts */
          html, body {
            overscroll-behavior: none !important;
            overscroll-behavior-x: none !important;
            overscroll-behavior-y: none !important;
          }
          img {
            -webkit-user-drag: none !important;
          }

          /* Stop layer texture explosion across Discord */
          * {
            will-change: auto !important;
          }

          /* Eliminate expensive backdrop-filter offscreen blit textures */
          div[role="menu"],
          div[class*="menu_"],
          div[class*="contextMenu_"],
          div[class*="tooltip_"],
          div[class*="tooltipContent_"],
          div[role="dialog"][class*="modal_"],
          div[role="dialog"] [class*="root_"],
          div[class*="modal_"] > div[class*="inner_"] {
            backdrop-filter: none !important;
            -webkit-backdrop-filter: none !important;
          }

          /* Native desktop text selection rules */
          nav, header, [role="navigation"], [class*="sidebar_"], [class*="guilds_"], [class*="membersWrap_"], button {
            user-select: none !important;
            -webkit-user-select: none !important;
          }
          [class*="messageContent_"], [class*="markup_"], code, pre, input, textarea, [contenteditable="true"] {
            user-select: text !important;
            -webkit-user-select: text !important;
          }

          /* macOS overlay scrollbars */
          ::-webkit-scrollbar {
            width: 8px !important;
            height: 8px !important;
          }
          ::-webkit-scrollbar-track {
            background: transparent !important;
          }
          ::-webkit-scrollbar-thumb {
            background: rgba(255, 255, 255, 0.18) !important;
            border-radius: 9999px !important;
            border: 2px solid transparent !important;
            background-clip: padding-box !important;
          }
          ::-webkit-scrollbar-thumb:hover {
            background: rgba(255, 255, 255, 0.35) !important;
          }
          ::-webkit-scrollbar-corner {
            background: transparent !important;
          }

          /* Sleek Dark Context Menus & Popovers */
          div[role="menu"],
          div[class*="menu_"][class*="styleFixed_"],
          div[class*="contextMenu_"] {
            background: rgba(30, 31, 35, 0.96) !important;
            border-radius: 12px !important;
            border: 1px solid rgba(255, 255, 255, 0.12) !important;
            box-shadow: 0 12px 30px rgba(0, 0, 0, 0.45) !important;
            padding: 6px !important;
          }
          div[role="menu"] [role="menuitem"],
          div[class*="item_"][role="menuitem"] {
            border-radius: 6px !important;
            transition: background 0.12s ease, color 0.12s ease !important;
          }
          div[role="menu"] [role="menuitem"]:hover,
          div[class*="item_"][role="menuitem"]:hover,
          div[class*="item_"][role="menuitem"][class*="focused_"] {
            background: rgba(88, 101, 242, 0.9) !important;
            color: #ffffff !important;
          }

          /* Sleek Dark Tooltips */
          div[class*="tooltip_"],
          div[class*="tooltipContent_"] {
            background: rgba(22, 23, 27, 0.96) !important;
            border: 1px solid rgba(255, 255, 255, 0.14) !important;
            border-radius: 8px !important;
            box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4) !important;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif !important;
            font-weight: 500 !important;
          }

          /* Sleek Dark Modals & Dialogs */
          div[role="dialog"][class*="modal_"],
          div[role="dialog"] [class*="root_"],
          div[class*="modal_"] > div[class*="inner_"] {
            background: rgba(32, 34, 38, 0.96) !important;
            border: 1px solid rgba(255, 255, 255, 0.15) !important;
            border-radius: 16px !important;
            box-shadow: 0 24px 60px rgba(0, 0, 0, 0.6) !important;
          }
          div[role="dialog"] [class*="footer_"] {
            background: rgba(24, 25, 28, 0.90) !important;
            border-bottom-left-radius: 16px !important;
            border-bottom-right-radius: 16px !important;
          }

          /* Apple Liquid Glass Search Bar */
          [class*="searchBar_"] {
            background: rgba(0, 0, 0, 0.22) !important;
            border-radius: 8px !important;
            border: 1px solid rgba(255, 255, 255, 0.08) !important;
            transition: all 0.2s cubic-bezier(0.16, 1, 0.3, 1) !important;
          }
          [class*="searchBar_"]:focus-within {
            background: rgba(0, 0, 0, 0.38) !important;
            border-color: rgba(88, 101, 242, 0.6) !important;
            box-shadow: 0 0 0 2px rgba(88, 101, 242, 0.25) !important;
          }

          /* Permanently eradicate Discord web download nag banners & prompts */
          [class*="downloadApps_"],
          [class*="notice_"][class*="colorDefault_"],
          [class*="desktopAppBanner_"],
          [class*="webDownloadAppBanner_"],
          [class*="notice_"] button[class*="button_"],
          div[class*="base_"] > div[class*="notice_"],
          a[href*="/download"] {
            display: none !important;
          }

          /* macOS Traffic Light Safe Area Inset */
          nav[aria-label="Servers sidebar"],
          nav[class*="guilds_"],
          div[class*="guilds_"] {
            padding-top: 24px !important;
          }

          /* Zen Mode: Collapses server and channel sidebars to save a meaningful slice of DOM & rendering memory */
          html.nokocord-zen-mode nav[aria-label="Servers sidebar"],
          html.nokocord-zen-mode nav[class*="guilds_"],
          html.nokocord-zen-mode div[class*="guilds_"],
          html.nokocord-zen-mode div[class*="sidebar_"] {
            display: none !important;
          }

          /* Ultra-Snappy Channel, Guild, and Member Hover States (tightened from 200ms to 40ms) */
          div[class*="channel_"],
          div[class*="channelName_"],
          div[class*="listItem_"],
          div[class*="wrapper_"][role="listitem"],
          div[class*="member_"] {
            transition: background-color 0.04s ease-out, color 0.04s ease-out !important;
          }

          /* Instant Menu, Popout, and Tooltip Appearance */
          div[role="menu"],
          div[class*="menu_"],
          div[class*="contextMenu_"],
          div[class*="popout_"],
          div[class*="tooltip_"] {
            animation-duration: 0.05s !important;
            transition-duration: 0.05s !important;
          }

          /* Instant Message Actions Bar on Hover */
          [class*="buttons_"][class*="container_"] {
            transition: opacity 0.04s ease-out !important;
          }

          /* Eradicate Spellcheck, Autocorrect, and Red Squiggly Lines in Chat */
          [contenteditable="true"],
          textarea,
          input,
          [role="textbox"] {
            spellcheck: false !important;
          }

          /* Freeze Idle Background Infinite Keyframe Animations (saves GPU/CPU cycles) */
          [class*="shinyButton_"],
          [class*="premiumIcon_"],
          [class*="nitroTopDividerContainer_"],
          [class*="flowerStar_"] > path {
            animation: none !important;
          }
        `;
          target.appendChild(style);
        } catch (_) {}
      };
      injectStyles();

      // 2. Intercept Command+K, Command+T, Command+B, and Command+\ anywhere in Discord
      const handleNokoShortcuts = (e) => {
        if ((e.metaKey || e.ctrlKey) && !e.altKey) {
          const key = e.key ? e.key.toLowerCase() : '';
          if (key === 'k' && !e.shiftKey) {
            e.preventDefault();
            e.stopPropagation();
            e.stopImmediatePropagation();
            postApp({ action: 'toggleQuickSwitcher' });
          } else if (key === 'b' && e.shiftKey) {
            e.preventDefault();
            e.stopPropagation();
            e.stopImmediatePropagation();
            postApp({ action: 'toggleBookmarks' });
          } else if (key === 't' && !e.shiftKey) {
            e.preventDefault();
            e.stopPropagation();
            e.stopImmediatePropagation();
            postApp({ action: 'toggleTans' });
          } else if (key === '\\' && !e.shiftKey) {
            e.preventDefault();
            e.stopPropagation();
            e.stopImmediatePropagation();
            postApp({ action: 'toggleZenMode' });
          }
        }
      };
      window.addEventListener('keydown', handleNokoShortcuts, true);
      document.addEventListener('keydown', handleNokoShortcuts, true);

      // 3. Native macOS Notification Bridge (routes HTML5 notifications to UNUserNotificationCenter)
      if (!window.__nokoNotificationBridged) {
        window.__nokoNotificationBridged = true;
        class NokoNotification extends EventTarget {
          constructor(title, options = {}) {
            super();
            this.title = title;
            this.body = options.body || '';
            this.icon = options.icon || '';
            this.tag = options.tag || '';
            postApp({
              action: 'notification',
              title: String(title).slice(0, 128),
              body: String(options.body || '').slice(0, 512)
            });
          }
          static get permission() { return 'granted'; }
          static requestPermission(cb) {
            if (cb) cb('granted');
            return Promise.resolve('granted');
          }
          close() {}
        }
        window.Notification = NokoNotification;
      }

      // 4. In-Page Memory Hygiene & Offscreen Media / Attachment Virtualizer
      if (!window.__nokoMemoryHygieneActive) {
        window.__nokoMemoryHygieneActive = true;

        const BLANK_PIXEL = 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>';

        // Auto-pause offscreen media (videos, gifs, audios) to stop GPU decode loops
        // Voice and other live streams carry a srcObject; pausing those would
        // silence a call, so they are never tracked by the media observer.
        const isLiveStream = (el) => {
          try {
            const stream = el.srcObject;
            return stream != null && (typeof stream.getTracks === 'function' ? stream.getTracks().length > 0 : true);
          } catch (_) { return false; }
        };
        const mediaObserver = new IntersectionObserver((entries) => {
          for (const entry of entries) {
            const el = entry.target;
            if (entry.isIntersecting) {
              if (el.__nokoPaused) {
                el.__nokoPaused = false;
                if (typeof el.play === 'function') el.play().catch(() => {});
              }
            } else {
              if (typeof el.pause === 'function' && !el.paused) {
                el.__nokoPaused = true;
                el.pause();
              }
            }
          }
        }, { threshold: 0.05 });

        const optimizeAttachment = (img) => {
          try {
            if (!img || img.__nokoOptimized) return;
            img.__nokoOptimized = true;
            img.decoding = 'async';
            img.loading = 'lazy';
          } catch (_) {}
        };

        const trackElements = (scope = document) => {
          const container = scope && typeof scope.querySelectorAll === 'function' ? scope : document;
          const media = [];
          if (container.matches && container.matches('video, audio')) media.push(container);
          container.querySelectorAll('video, audio').forEach(el => media.push(el));
          media.forEach(el => {
            if (!el.__nokoTracked && !isLiveStream(el)) {
              el.__nokoTracked = true;
              mediaObserver.observe(el);
            }
          });
          if (container.matches && container.matches('img[src*="/attachments/"], img[src*="images-ext-"], div[class*="imageWrapper_"] img')) optimizeAttachment(container);
          container.querySelectorAll('img[src*="/attachments/"], img[src*="images-ext-"], div[class*="imageWrapper_"] img').forEach(el => {
            optimizeAttachment(el);
          });
        };

        let trackScheduled = false;
        let pendingTrackRoots = [];
        const scheduleTrackElements = (roots = [document]) => {
          pendingTrackRoots.push(...roots.slice(0, 64));
          if (trackScheduled) return;
          trackScheduled = true;
          requestAnimationFrame(() => {
            trackScheduled = false;
            const work = pendingTrackRoots;
            pendingTrackRoots = [];
            if (work.includes(document)) trackElements(document);
            else work.forEach(trackElements);
          });
        };

        const initObservers = () => {
          try {
            const root = document.documentElement || document.body;
            if (!root) {
              onReady(initObservers);
              return;
            }
            const domObserver = new MutationObserver((mutations) => {
              const addedRoots = [];
              for (let i = 0; i < mutations.length; i++) {
                const m = mutations[i];
                if (m.removedNodes && m.removedNodes.length > 0) {
                  for (let j = 0; j < m.removedNodes.length; j++) {
                    const node = m.removedNodes[j];
                    if (node.nodeType === 1) {
                      if (node.tagName === 'VIDEO' || node.tagName === 'AUDIO') {
                        mediaObserver.unobserve(node);
                      } else if (typeof node.querySelectorAll === 'function') {
                        node.querySelectorAll('video, audio').forEach(el => mediaObserver.unobserve(el));
                      }
                    }
                  }
                }
                // Ignore mutations inside text inputs, slate editors, or typing areas to prevent typing hitching
                if (m.target && m.target.nodeType === 1) {
                  if (m.target.isContentEditable || m.target.getAttribute('role') === 'textbox' || m.target.tagName === 'TEXTAREA' || m.target.tagName === 'INPUT') {
                    continue;
                  }
                }
                for (const node of m.addedNodes) if (node.nodeType === 1) addedRoots.push(node);
              }
              if (addedRoots.length > 0) scheduleTrackElements(addedRoots);
            });
            domObserver.observe(root, { childList: true, subtree: true });
            scheduleTrackElements([document]);
          } catch (_) {}
        };
        initObservers();

        // Safe Offscreen Media & Video Pausing
        const evictOffscreenMedia = () => {
          try {
            document.querySelectorAll('video, audio').forEach(el => {
              if (isLiveStream(el)) return;
              const r = el.getBoundingClientRect();
              if (r.bottom < 0 || r.top > window.innerHeight) {
                if (typeof el.pause === 'function') {
                  el.__nokoPaused = true;
                  el.pause();
                }
              }
            });
          } catch (_) {}
        };

        const onChannelNavigated = () => {
          evictOffscreenMedia();
          postApp({ action: 'channelChanged' });
        };

        // Hook History API for instant channel navigation detection
        let lastPath = location.pathname;
        const checkNavigation = () => {
          const cur = location.pathname;
          if (cur !== lastPath) {
            lastPath = cur;
            setTimeout(onChannelNavigated, 60);
          }
        };

        const origPushState = history.pushState;
        history.pushState = function(...args) {
          const res = origPushState.apply(this, args);
          checkNavigation();
          return res;
        };

        const origReplaceState = history.replaceState;
        history.replaceState = function(...args) {
          const res = origReplaceState.apply(this, args);
          checkNavigation();
          return res;
        };

        window.addEventListener('popstate', checkNavigation);

        // Memory purge & hibernation hooks called by Swift
        window.__nokoPurgeMemory = () => {
          try {
            evictOffscreenMedia();
            if (window.__SENTRY__?.hub?.getScope?.()?.clearBreadcrumbs) {
              window.__SENTRY__.hub.getScope().clearBreadcrumbs();
            }
          } catch (_) {}
        };

        window.__nokoHibernate = () => {
          try {
            evictOffscreenMedia();
            document.querySelectorAll('video, audio').forEach((el) => {
              if (isLiveStream(el)) return;
              if (typeof el.pause === 'function') el.pause();
            });
          } catch (_) {}
        };

        window.__nokoResume = () => {
          try {
            scheduleTrackElements();
          } catch (_) {}
        };
      }

      // 5. Native Media Lightbox Interceptor (Bypasses Discord's heavy React modal allocation)
      document.addEventListener('click', (e) => {
        const target = e.target instanceof Element ? e.target : e.target?.parentElement;
        if (!target || !target.closest) return;

        // Never intercept buttons or interactive controls (favorite, copy link, options, menus, etc.)
        if (target.closest('button, [role="button"], [role="menu"], [role="menuitem"], [role="tab"], [aria-haspopup="true"], [data-action], a:not([class*="originalLink_"]):not([class*="imageWrapper_"])')) {
          return;
        }

        // Never intercept favorite buttons or overlay action groups on media/GIFs
        if (target.closest('[class*="favButton" i], [class*="favorite" i], [class*="favourite" i], [class*="hoverButtonGroup" i], [class*="toolbar_" i], [class*="operations_" i], [class*="action_" i], [class*="altText_" i], [class*="badge_" i], [aria-label*="favorit" i], [aria-label*="star" i], [aria-label*="copy" i], [aria-label*="option" i], [aria-label*="more" i]')) {
          return;
        }

        // Never intercept inside pickers (GIF picker, emoji, stickers), popouts, dialogs, modals, or chat composer
        if (target.closest('[class*="picker" i], [class*="expressionPicker" i], [id*="gif-picker" i], [id*="picker" i], [class*="popout" i], [class*="modal" i], [role="dialog"], [class*="channelTextArea" i], form[class*="form_" i], [class*="upload_" i], [class*="drafts" i]')) {
          return;
        }

        // Never intercept unrevealed spoilers or video player controls
        if (target.closest('[class*="spoiler" i]:not([class*="revealed" i]), [class*="hiddenSpoiler" i], [class*="videoControls" i], [class*="mediaBar" i], [class*="playButton" i]')) {
          return;
        }

        // Target must be inside an image wrapper/content container or direct media link
        const mediaContainer = target.closest('div[class*="imageWrapper_"], div[class*="imageContent_"], a[class*="originalLink_"], div[class*="video_"]');
        const mediaLink = target.closest('a[href*="cdn.discordapp.com/attachments/"], a[href*="media.discordapp.net/attachments/"]');
        if (!mediaContainer && !mediaLink) return;

        // Ensure the clicked element is actually the media itself (img, video, canvas, or direct wrapper)
        const isDirectMediaTarget = target.tagName === 'IMG' ||
          target.tagName === 'VIDEO' ||
          target.tagName === 'CANVAS' ||
          target === mediaContainer ||
          target.closest('a[class*="originalLink_"]') !== null ||
          target.matches('div[class*="imageWrapper_"], div[class*="imageContent_"], div[class*="video_"]');
        if (!isDirectMediaTarget) return;

        let mediaUrl = null;
        let isVideo = false;

        if (mediaContainer) {
          const video = mediaContainer.querySelector('video') || (mediaContainer.tagName === 'VIDEO' ? mediaContainer : null);
          const img = mediaContainer.querySelector('img') || (mediaContainer.tagName === 'IMG' ? mediaContainer : null);
          const parentA = (mediaContainer.tagName === 'A' ? mediaContainer : null) || mediaContainer.closest('a');

          if (video) {
            mediaUrl = video.currentSrc || video.src;
            isVideo = true;
          } else if (img) {
            mediaUrl = (img.currentSrc && !img.currentSrc.startsWith('data:')) ? img.currentSrc : (img.__nokoOriginalSrc || img.src);
          } else if (parentA && parentA.href && (parentA.href.includes('discordapp.com') || parentA.href.includes('discordapp.net'))) {
            mediaUrl = parentA.href;
          }
        } else if (mediaLink) {
          mediaUrl = mediaLink.href;
          isVideo = mediaUrl.endsWith('.mp4') || mediaUrl.endsWith('.mov') || mediaUrl.endsWith('.webm');
        }

        if (mediaUrl && (mediaUrl.includes('discordapp.com') || mediaUrl.includes('discordapp.net'))) {
          // Ignore emojis, avatars, stickers, badges
          if (mediaUrl.includes('/emojis/') || mediaUrl.includes('/avatars/') || mediaUrl.includes('/stickers/') || mediaUrl.includes('/badges/')) {
            return;
          }
          e.preventDefault();
          e.stopPropagation();
          postApp({
            action: 'openMedia',
            url: mediaUrl,
            isVideo: isVideo
          });
        }
      }, true);

      // 6. External image keys for activities. Discord only renders images that
      // are application assets or media-proxy keys, so image URLs are resolved
      // through the client's own authenticated endpoint before dispatch.
      if (!window.__nokoResolveExternalAssets) {
        window.__nokoResolveExternalAssets = async (applicationId, urls) => {
          const slots = Array.isArray(urls) ? urls : [];
          const list = slots.filter((value) => typeof value === 'string' && /^https?:\/\//.test(value));
          if (list.length === 0) return slots;
          const chunk = window.webpackChunkdiscord_app;
          if (!chunk || typeof chunk.push !== 'function') return urls ?? [];
          const requires = [];
          for (let i = 0; i < 3; i++) {
            try {
              chunk.push([[Symbol()], {}, (require) => { if (requires.indexOf(require) === -1) requires.push(require); }]);
            } catch (_) {}
          }
          for (const require of requires) {
            const factories = require && require.m ? require.m : null;
            if (!factories) continue;
            for (const id of Object.keys(factories)) {
              let source = '';
              try { source = Function.prototype.toString.call(factories[id]); } catch (_) { continue; }
              if (source.indexOf('external_asset_path') === -1) continue;
              let exported = null;
              try { exported = require(id); } catch (_) { continue; }
              for (const candidate of Object.values(exported ?? {})) {
                if (typeof candidate !== 'function' || candidate.length < 2) continue;
                try {
                  const resolved = await candidate(String(applicationId), list);
                  if (Array.isArray(resolved) && resolved.some((value) => typeof value === 'string' && value.startsWith('mp:'))) {
                    // Map results back onto the caller's slots so an image that
                    // was not requested can never take another's place.
                    let cursor = 0;
                    return slots.map((value) => {
                      const needed = typeof value === 'string' && /^https?:\/\//.test(value);
                      const result = needed ? resolved[cursor++] : null;
                      return typeof result === 'string' && result.startsWith('mp:') ? result : value;
                    });
                  }
                } catch (_) {}
              }
            }
          }
          return urls ?? [];
        };
      }

      // 7. Native Spacebar Quick Look & ⌘S Quick Bookmark Handler
      let currentHoveredMedia = null;
      let currentHoveredMessage = null;

      const saveMessageBookmark = (msgEl) => {
        try {
          const msgId = msgEl.id ? msgEl.id.replace(/^chat-messages-/, '') : (msgEl.getAttribute('data-list-item-id') || String(Date.now()));
          const authorEl = msgEl.querySelector('span[class*="username_"], span[id*="message-username-"]');
          const authorName = authorEl ? authorEl.textContent.trim() : 'Discord User';
          const avatarEl = msgEl.querySelector('img[class*="avatar_"]');
          const authorAvatarURL = avatarEl ? (avatarEl.currentSrc || avatarEl.src) : null;
          const contentEl = msgEl.querySelector('div[class*="messageContent_"], div[id*="message-content-"]');
          const content = contentEl ? contentEl.textContent.trim() : '';
          const imgEl = msgEl.querySelector('div[class*="imageWrapper_"] img');
          const mediaURL = imgEl ? (imgEl.currentSrc || imgEl.src) : null;

          const title = document.title || '';
          let channelName = 'general';
          let serverName = '';
          if (title.includes('|')) {
            const parts = title.split('|');
            channelName = parts[1] ? parts[1].replace(/^[#\s]+/, '').trim() : 'general';
            serverName = parts[2] ? parts[2].trim() : (parts[0] ? parts[0].trim() : '');
          }

          const messageURL = location.origin + location.pathname + '/' + msgId;

          postApp({
            action: 'saveBookmark',
            messageId: msgId,
            authorName: authorName,
            authorAvatarURL: authorAvatarURL,
            channelName: channelName,
            serverName: serverName,
            content: content,
            mediaURL: mediaURL,
            messageURL: messageURL
          });
        } catch (_) {}
      };

      document.addEventListener('mouseover', (e) => {
        const target = e.target instanceof Element ? e.target : e.target?.parentElement;
        if (!target) return;

        // Track hovered message for ⌘S bookmarking
        const msgItem = target.closest('li[class*="messageListItem_"], div[id^="chat-messages-"]');
        if (msgItem) {
          currentHoveredMessage = msgItem;
          // Inject subtle bookmark button if buttons container is mounted
          const buttonsGroup = msgItem.querySelector('div[class*="buttons_"], div[class*="buttonContainer_"]');
          if (buttonsGroup && !buttonsGroup.querySelector('.nokocord-bookmark-btn')) {
            const btn = document.createElement('button');
            btn.className = 'nokocord-bookmark-btn';
            btn.setAttribute('aria-label', 'Save to NokoCord Bookmarks (⌘S)');
            btn.title = 'Save to NokoCord Bookmarks (⌘S)';
            btn.style.cssText = 'background:none;border:none;cursor:pointer;padding:4px 6px;color:#b5bac1;display:flex;align-items:center;justify-content:center;border-radius:4px;transition:color 0.1s,background-color 0.1s;';
            btn.innerHTML = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M19 21l-7-5-7 5V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z"></path></svg>';
            btn.onmouseenter = () => { btn.style.color = '#fff'; btn.style.backgroundColor = 'rgba(255,255,255,0.08)'; };
            btn.onmouseleave = () => { btn.style.color = '#b5bac1'; btn.style.backgroundColor = 'transparent'; };
            btn.onclick = (ev) => {
              ev.preventDefault();
              ev.stopPropagation();
              saveMessageBookmark(msgItem);
              btn.innerHTML = '<svg width="18" height="18" viewBox="0 0 24 24" fill="#3ba55d" stroke="#3ba55d" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>';
              setTimeout(() => {
                btn.innerHTML = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M19 21l-7-5-7 5V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z"></path></svg>';
              }, 1500);
            };
            buttonsGroup.prepend(btn);
          }
        }

        // Track hovered media for Spacebar Quick Look
        const mediaContainer = target.closest('div[class*="imageWrapper_"], div[class*="imageContent_"], div[class*="video_"]');
        const mediaImg = target.tagName === 'IMG' ? target : (mediaContainer?.querySelector('img') || null);
        const mediaVideo = target.tagName === 'VIDEO' ? target : (mediaContainer?.querySelector('video') || null);

        if (mediaVideo) {
          const src = mediaVideo.currentSrc || mediaVideo.src;
          if (src && (src.includes('discordapp.com') || src.includes('discordapp.net'))) {
            currentHoveredMedia = { url: src, isVideo: true };
            return;
          }
        }
        if (mediaImg) {
          const src = (mediaImg.currentSrc && !mediaImg.currentSrc.startsWith('data:')) ? mediaImg.currentSrc : (mediaImg.__nokoOriginalSrc || mediaImg.src);
          if (src && (src.includes('discordapp.com') || src.includes('discordapp.net')) &&
              !src.includes('/emojis/') && !src.includes('/avatars/') && !src.includes('/stickers/') && !src.includes('/badges/')) {
            currentHoveredMedia = { url: src, isVideo: false };
            return;
          }
        }
        if (!mediaContainer) {
          currentHoveredMedia = null;
        }
      }, true);

      document.addEventListener('keydown', (e) => {
        const active = document.activeElement;
        const isTyping = active && (active.isContentEditable || active.getAttribute('role') === 'textbox' || active.tagName === 'TEXTAREA' || active.tagName === 'INPUT');

        // Spacebar Native Quick Look on Hovered Media
        if (e.code === 'Space' && !e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey) {
          if (!isTyping && currentHoveredMedia) {
            e.preventDefault();
            e.stopPropagation();
            postApp({
              action: 'openMedia',
              url: currentHoveredMedia.url,
              isVideo: currentHoveredMedia.isVideo
            });
            return;
          }
        }

        // ⌘S: Save Hovered Message to Bookmarks
        if ((e.metaKey || e.ctrlKey) && (e.key === 's' || e.key === 'S')) {
          if (!isTyping && currentHoveredMessage) {
            e.preventDefault();
            e.stopPropagation();
            saveMessageBookmark(currentHoveredMessage);
            return;
          }
        }
      }, true);
    })();
    """# }
}

@MainActor
private final class NokoAppMessageHandler: NSObject, WKScriptMessageHandler {
    weak var runtime: TanRuntime?
    init(runtime: TanRuntime) { self.runtime = runtime }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let runtime,
              message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url,
              TanRuntime.accepts(url, origin: runtime.allowedOrigin),
              message.frameInfo.securityOrigin.protocol == url.scheme,
              message.frameInfo.securityOrigin.host == url.host,
              (message.frameInfo.securityOrigin.port == 0 ? 443 : message.frameInfo.securityOrigin.port) == (url.port ?? 443),
              let body = message.body as? [String: Any],
              case .allowed(let action) = TanRuntime.validateAppBridgeRequest(body, runtimeNonce: runtime.runtimeNonce) else { return }
        switch action {
        case .toggleTans:
            runtime.onToggleTans?()
        case .toggleQuickSwitcher:
            runtime.onToggleQuickSwitcher?()
        case .toggleBookmarks:
            runtime.onToggleBookmarks?()
        case .toggleZenMode:
            runtime.onToggleZenMode?()
        case .channelChanged:
            runtime.onChannelChanged?()
        case .saveBookmark:
            if let msgId = body["messageId"] as? String,
               let author = body["authorName"] as? String,
               let channel = body["channelName"] as? String,
               let server = body["serverName"] as? String,
               let content = body["content"] as? String,
               let msgUrl = body["messageURL"] as? String {
                guard let messageURL = URL(string: msgUrl), BrowserPolicy.isDiscordOrigin(messageURL) else { return }
                let avatar = body["authorAvatarURL"] as? String
                let media = body["mediaURL"] as? String
                let bookmark = NokoBookmark(
                    messageId: msgId,
                    authorName: author,
                    authorAvatarURL: avatar,
                    channelName: channel,
                    serverName: server,
                    content: content,
                    mediaURL: media,
                    messageURL: messageURL.absoluteString
                )
                guard BookmarkStore.shared.add(
                    messageId: msgId,
                    authorName: author,
                    authorAvatarURL: avatar,
                    channelName: channel,
                    serverName: server,
                    content: content,
                    mediaURL: media,
                    messageURL: messageURL.absoluteString
                ) else { return }
                runtime.onSaveBookmark?(bookmark)
            }
        case .openMedia:
            if let urlStr = body["url"] as? String,
               let url = URL(string: urlStr),
               BrowserPolicy.isDiscordMediaURL(url) {
                let isVideo = body["isVideo"] as? Bool ?? false
                runtime.onOpenMedia?(url, isVideo)
            }
        case .notification:
            if let title = body["title"] as? String {
                let notifBody = body["body"] as? String ?? ""
                let cleanTitle = title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
                let cleanBody = notifBody.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
                let boundedTitle = String(cleanTitle.prefix(128))
                let boundedBody = String(cleanBody.prefix(512))
                guard !boundedTitle.isEmpty else { return }
                Task { @MainActor in
                    await NotificationService.shared.deliverWebNotification(title: boundedTitle, body: boundedBody)
                }
            }
        }
    }
}

@MainActor
private final class TanMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var runtime: TanRuntime?
    let package: TanPackage
    let fingerprint: String
    private var interval = Date()
    private var count = 0
    init(runtime: TanRuntime, package: TanPackage) { self.runtime = runtime; self.package = package; self.fingerprint = package.contentHash }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        if Date().timeIntervalSince(interval) > 1 { interval = Date(); count = 0 }
        count += 1
        guard count <= 20, let runtime else { replyHandler(nil, "Request limit reached"); return }
        runtime.receive(message, package: package, fingerprint: fingerprint, reply: replyHandler)
    }
}
