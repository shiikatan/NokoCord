import AppKit
import WebKit
import CryptoKit

@MainActor
final class TanRuntime {
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
    fileprivate let allowedOrigin: String
    private var appHandler: NokoAppMessageHandler?
    var onToggleTans: (() -> Void)?
    var onToggleQuickSwitcher: (() -> Void)?

    init(manager: TanManager, allowedOrigin: String = "https://discord.com") {
        self.manager = manager; self.allowedOrigin = allowedOrigin
    }
    func prepare(_ controller: WKUserContentController) {
        self.controller = controller
        configureScripts()
    }
    func attach(_ view: WKWebView) { self.view = view; view.isInspectable = manager.developerMode }
    func detach() {
        generation = UUID()
        transitionTask = nil
        clearHandlers()
        controller?.removeAllUserScripts()
        controller = nil; view = nil; configured = []; livePackages = [:]
        worlds.removeAll(); activeHashes.removeAll()
    }
    func configurationChanged() {
        let old = configured
        let needsReload = (old + manager.active).contains { $0.manifest.target == .page || $0.manifest.requiresReload }
        configureScripts()
        view?.isInspectable = manager.developerMode
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
        // DOM Tans also work when Discord moves from /app to /channels during
        // startup. Registration replaces its own prior instance, never a view.
        applyLive(stopping: [], starting: manager.active.filter { $0.manifest.target != .page && !$0.manifest.requiresReload })
    }
    func locationChanged() {
        guard let url = view?.url else { return }
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
        configured = manager.active
        activeHashes = Dictionary(uniqueKeysWithValues: configured.map { ($0.id, $0.contentHash) })
        for package in configured {
            let world = world(package)
            let handler = TanMessageHandler(runtime: self, package: package)
            controller.addScriptMessageHandler(handler, contentWorld: world, name: Self.handlerName(package))
            handlers.append(handler)
            controller.addUserScript(WKUserScript(source: Self.source(package, allowedOrigin: allowedOrigin), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        }
        if allowedOrigin == "https://discord.com" {
            let app = NokoAppMessageHandler(runtime: self)
            controller.add(app, name: "nokoCordApp")
            appHandler = app
            controller.addUserScript(WKUserScript(source: Self.discordInjectedScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }
    private func clearHandlers() {
        for package in configured { controller?.removeScriptMessageHandler(forName: Self.handlerName(package), contentWorld: world(package)) }
        handlers.removeAll()
        if allowedOrigin == "https://discord.com" {
            controller?.removeScriptMessageHandler(forName: "nokoCordApp")
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
                do { try await self.evaluate(Self.source(package, allowedOrigin: self.allowedOrigin), view: view, world: self.world(package)) }
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
              let body = message.body as? [String: Any],
              let request = TanBridgeRequest.parse(body) else { reply(nil, "Request rejected"); return }
        if request.type == "status", let state = request.state, let event = TanDiagnostic.Event(rawValue: state), event != .rejected {
            manager.record(package.id, event: event); reply(["ok": true], nil)
        } else if request.permits(package.manifest) {
            let name = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            reply(["appearance": name == .darkAqua ? "dark" : "light"], nil)
        } else { manager.record(package.id, event: .rejected); reply(nil, "Capability not granted") }
    }
    static func accepts(_ url: URL, origin: String) -> Bool {
        guard let expected = URL(string: origin), url.scheme == expected.scheme, url.host == expected.host,
              (url.port ?? 443) == (expected.port ?? 443), url.user == nil, url.password == nil else { return false }
        return origin != "https://discord.com" || url.path == "/app" || url.path.hasPrefix("/channels/")
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
    static func source(_ package: TanPackage, allowedOrigin: String) -> String {
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
          const send = body => window.webkit.messageHandlers[\#(quote(handlerName(package)))].postMessage(body);
          const report = state => { try { send({type:'status', state}).catch(() => {}); } catch {} };
          const disposers = new Set();
          const own = dispose => {
            if (stopped || disposers.size >= 256) { dispose(); throw new Error('Resource limit reached'); }
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
              target.addEventListener(type, listener, options);
              const capture = typeof options === 'boolean' ? options : !!options?.capture;
              return own(() => target.removeEventListener(type, listener, capture));
            },
            interval(callback, milliseconds) {
              const timer = setInterval(() => { if (!stopped) callback(); }, Math.max(16, milliseconds));
              return own(() => clearInterval(timer));
            },
            timeout(callback, milliseconds) {
              let cancel;
              const timer = setTimeout(() => { cancel(); if (!stopped) callback(); }, Math.max(0, milliseconds));
              cancel = own(() => clearTimeout(timer)); return cancel;
            },
            mount(element, parent = document.body) { parent.append(element); return own(() => element.remove()); },
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
    static let discordInjectedScript: String = #"""
    (() => {
      'use strict';
      if (location.origin !== 'https://discord.com') return;
      if (window.__nokoCordAppInjected) return;
      window.__nokoCordAppInjected = true;

      // 1. Inject Native macOS App Styling (Traffic lights padding, overlay scrollbars, font smoothing, hide web nags)
      const injectStyles = () => {
        if (document.getElementById('nokocord-native-overrides')) return;
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

          /* Apple Liquid Glass Context Menus & Popovers */
          div[role="menu"],
          div[class*="menu_"][class*="styleFixed_"],
          div[class*="contextMenu_"] {
            background: rgba(30, 31, 35, 0.76) !important;
            backdrop-filter: blur(28px) saturate(190%) !important;
            -webkit-backdrop-filter: blur(28px) saturate(190%) !important;
            border-radius: 12px !important;
            border: 1px solid rgba(255, 255, 255, 0.12) !important;
            box-shadow: 0 16px 36px rgba(0, 0, 0, 0.48), 0 0 1px rgba(255, 255, 255, 0.2) inset !important;
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

          /* Apple Liquid Glass Tooltips */
          div[class*="tooltip_"],
          div[class*="tooltipContent_"] {
            background: rgba(22, 23, 27, 0.82) !important;
            backdrop-filter: blur(20px) saturate(180%) !important;
            -webkit-backdrop-filter: blur(20px) saturate(180%) !important;
            border: 1px solid rgba(255, 255, 255, 0.14) !important;
            border-radius: 8px !important;
            box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4) !important;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif !important;
            font-weight: 500 !important;
          }

          /* Apple Liquid Glass Modals & Dialogs */
          div[role="dialog"][class*="modal_"],
          div[role="dialog"] [class*="root_"],
          div[class*="modal_"] > div[class*="inner_"] {
            background: rgba(32, 34, 38, 0.85) !important;
            backdrop-filter: blur(36px) saturate(200%) !important;
            -webkit-backdrop-filter: blur(36px) saturate(200%) !important;
            border: 1px solid rgba(255, 255, 255, 0.15) !important;
            border-radius: 16px !important;
            box-shadow: 0 24px 60px rgba(0, 0, 0, 0.6) !important;
          }
          div[role="dialog"] [class*="footer_"] {
            background: rgba(24, 25, 28, 0.65) !important;
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
        `;
        (document.head || document.documentElement).appendChild(style);
      };
      injectStyles();

      // 2. Intercept Command+K and Command+T anywhere in Discord
      window.addEventListener('keydown', (e) => {
        if ((e.metaKey || e.ctrlKey) && !e.shiftKey && !e.altKey) {
          const key = e.key.toLowerCase();
          if (key === 't') {
            e.preventDefault();
            e.stopPropagation();
            try {
              window.webkit?.messageHandlers?.nokoCordApp?.postMessage({ action: 'toggleTans' });
            } catch (_) {}
          } else if (key === 'k') {
            e.preventDefault();
            e.stopPropagation();
            try {
              window.webkit?.messageHandlers?.nokoCordApp?.postMessage({ action: 'toggleQuickSwitcher' });
            } catch (_) {}
          }
        }
      }, true);

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
            try {
              window.webkit?.messageHandlers?.nokoCordApp?.postMessage({
                action: 'notification',
                title: String(title),
                body: String(options.body || '')
              });
            } catch (_) {}
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
    })();
    """#
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
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        if action == "toggleTans" {
            runtime.onToggleTans?()
        } else if action == "toggleQuickSwitcher" {
            runtime.onToggleQuickSwitcher?()
        } else if action == "notification" {
            if let title = body["title"] as? String {
                let notifBody = body["body"] as? String ?? ""
                Task { @MainActor in
                    await NotificationService.shared.deliverWebNotification(title: title, body: notifBody)
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
