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
    var onOpenMedia: ((URL, Bool) -> Void)?
    var onToggleZenMode: (() -> Void)?
    var onChannelChanged: (() -> Void)?

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

      // 0. Completely eradicate Autocorrect, Spellcheck, Autocapitalize, and Autocomplete
      try {
        const targets = [
          HTMLElement.prototype,
          HTMLInputElement.prototype,
          HTMLTextAreaElement.prototype
        ];
        targets.forEach((proto) => {
          ['spellcheck', 'autocorrect', 'autocapitalize', 'autocomplete'].forEach((prop) => {
            try {
              Object.defineProperty(proto, prop, {
                get() { return prop === 'spellcheck' ? false : 'off'; },
                set(_) {},
                configurable: true
              });
            } catch (_) {}
          });
        });

        const origSetAttribute = Element.prototype.setAttribute;
        Element.prototype.setAttribute = function(name, value) {
          const lower = String(name).toLowerCase();
          if (lower === 'spellcheck') {
            return origSetAttribute.call(this, 'spellcheck', 'false');
          }
          if (lower === 'autocorrect') {
            return origSetAttribute.call(this, 'autocorrect', 'off');
          }
          if (lower === 'autocapitalize') {
            return origSetAttribute.call(this, 'autocapitalize', 'off');
          }
          if (lower === 'autocomplete') {
            return origSetAttribute.call(this, 'autocomplete', 'off');
          }
          return origSetAttribute.call(this, name, value);
        };

        const enforceNoAutocorrect = (el) => {
          if (!el || !(el instanceof HTMLElement)) return;
          if (el.isContentEditable || el.tagName === 'TEXTAREA' || el.tagName === 'INPUT' || el.getAttribute('role') === 'textbox') {
            try {
              el.spellcheck = false;
              origSetAttribute.call(el, 'spellcheck', 'false');
              origSetAttribute.call(el, 'autocorrect', 'off');
              origSetAttribute.call(el, 'autocapitalize', 'off');
              origSetAttribute.call(el, 'autocomplete', 'off');
              origSetAttribute.call(el, 'data-gramm', 'false');
              origSetAttribute.call(el, 'data-enable-grammarly', 'false');
            } catch (_) {}
          }
        };

        window.addEventListener('focusin', (e) => enforceNoAutocorrect(e.target), true);
        window.addEventListener('pointerdown', (e) => {
          enforceNoAutocorrect(e.target);
          if (e.target && e.target.closest) {
            const ed = e.target.closest('[contenteditable="true"], textarea, input, [role="textbox"]');
            if (ed) enforceNoAutocorrect(ed);
          }
        }, true);
        window.addEventListener('keydown', (e) => {
          enforceNoAutocorrect(e.target);
        }, true);
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

          /* Zen Mode: Collapses server and channel sidebars to save ~40% DOM & rendering memory */
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

      // 2. Intercept Command+K, Command+T, and Command+\ anywhere in Discord
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
          } else if (key === '\\') {
            e.preventDefault();
            e.stopPropagation();
            try {
              window.webkit?.messageHandlers?.nokoCordApp?.postMessage({ action: 'toggleZenMode' });
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
                title: String(title).slice(0, 128),
                body: String(options.body || '').slice(0, 512)
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

      // 4. In-Page Memory Hygiene & Offscreen Media / Attachment Virtualizer
      if (!window.__nokoMemoryHygieneActive) {
        window.__nokoMemoryHygieneActive = true;

        const BLANK_PIXEL = 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>';

        // Auto-pause offscreen media (videos, gifs, audios) to stop GPU decode loops
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

        const trackElements = () => {
          document.querySelectorAll('video, audio').forEach(el => {
            if (!el.__nokoTracked) {
              el.__nokoTracked = true;
              mediaObserver.observe(el);
            }
          });
          document.querySelectorAll('img[src*="/attachments/"], img[src*="images-ext-"], div[class*="imageWrapper_"] img').forEach(el => {
            optimizeAttachment(el);
          });
        };

        let trackScheduled = false;
        const scheduleTrackElements = () => {
          if (trackScheduled) return;
          trackScheduled = true;
          requestAnimationFrame(() => {
            trackScheduled = false;
            trackElements();
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
              let hasRelevantNode = false;
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
                if (m.addedNodes.length > 0) {
                  hasRelevantNode = true;
                }
              }
              if (hasRelevantNode) {
                scheduleTrackElements();
              }
            });
            domObserver.observe(root, { childList: true, subtree: true });
            trackElements();
          } catch (_) {}
        };
        initObservers();

        // Discord Internal Stores Access for Memory Reclamation
        let discordMessageStore = null;
        let discordSelectedChannelStore = null;
        let discordDispatcher = null;
        const recentChannelIds = [];

        const getDiscordStores = () => {
          if (discordMessageStore && discordSelectedChannelStore) return true;
          try {
            const chunk = window.webpackChunkdiscord_app;
            if (!chunk || typeof chunk.push !== 'function') return false;
            let req;
            chunk.push([[Symbol()], {}, (r) => { req = r; }]);
            if (!req || !req.c) return false;
            const modules = Object.values(req.c);
            for (let i = 0; i < modules.length; i++) {
              const exp = modules[i]?.exports;
              if (!exp) continue;
              const candidates = [exp, exp.default, exp.Z, exp.ZP].filter(Boolean);
              for (const c of candidates) {
                if (typeof c === 'object' && c !== null) {
                  if (typeof c.getName === 'function') {
                    const name = c.getName();
                    if (name === 'MessageStore') discordMessageStore = c;
                    else if (name === 'SelectedChannelStore') discordSelectedChannelStore = c;
                  }
                  if (c.dispatch && c.subscribe && !discordDispatcher) {
                    discordDispatcher = c;
                  }
                }
              }
              if (discordMessageStore && discordSelectedChannelStore && discordDispatcher) break;
            }
            return Boolean(discordMessageStore);
          } catch (_) {
            return false;
          }
        };

        const pruneInactiveChannels = () => {
          try {
            getDiscordStores();
            if (!discordMessageStore) return;

            let activeChannelId = null;
            if (discordSelectedChannelStore && typeof discordSelectedChannelStore.getChannelId === 'function') {
              activeChannelId = discordSelectedChannelStore.getChannelId();
            }
            if (!activeChannelId) {
              const match = location.pathname.match(/\/channels\/[^\/]+\/(\d+)/);
              if (match) activeChannelId = match[1];
            }
            if (!activeChannelId) return;

            // Maintain small LRU ring of 3 most recent channels (~600 KB total memory)
            // for instant zero-latency back-and-forth channel navigation
            const activeStr = String(activeChannelId);
            const idx = recentChannelIds.indexOf(activeStr);
            if (idx !== -1) recentChannelIds.splice(idx, 1);
            recentChannelIds.unshift(activeStr);
            while (recentChannelIds.length > 3) {
              recentChannelIds.pop();
            }

            // Prune unmounted channels from Discord MessageStore outside our 3-channel ring
            const mapNames = ['_channelMessages', 'channelMessages', '_messages'];
            for (const mapName of mapNames) {
              const storeMap = discordMessageStore[mapName];
              if (storeMap && typeof storeMap === 'object') {
                if (storeMap instanceof Map) {
                  for (const key of Array.from(storeMap.keys())) {
                    if (!recentChannelIds.includes(String(key))) {
                      storeMap.delete(key);
                    }
                  }
                } else {
                  for (const key of Object.keys(storeMap)) {
                    if (!recentChannelIds.includes(String(key))) {
                      delete storeMap[key];
                    }
                  }
                }
              }
            }
          } catch (_) {}
        };

        const evictOffscreenMedia = () => {
          try {
            // Pause out of view videos
            document.querySelectorAll('video, audio').forEach(el => {
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
          pruneInactiveChannels();
          try {
            window.webkit?.messageHandlers?.nokoCordApp?.postMessage({ action: 'channelChanged' });
          } catch (_) {}
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

        // Also subscribe to Discord Flux Dispatcher CHANNEL_SELECT
        let fluxSubscribed = false;
        const trySubscribeFlux = () => {
          if (fluxSubscribed) return true;
          if (getDiscordStores() && discordDispatcher && typeof discordDispatcher.subscribe === 'function') {
            try {
              discordDispatcher.subscribe('CHANNEL_SELECT', () => {
                setTimeout(onChannelNavigated, 80);
              });
              fluxSubscribed = true;
              return true;
            } catch (_) {}
          }
          return false;
        };
        if (!trySubscribeFlux()) {
          let fluxAttempts = 0;
          const fluxTimer = setInterval(() => {
            fluxAttempts++;
            if (trySubscribeFlux() || fluxAttempts >= 30) clearInterval(fluxTimer);
          }, 1500);
        }

        // Memory purge hook called by Swift
        window.__nokoPurgeMemory = () => {
          try {
            pruneInactiveChannels();
            evictOffscreenMedia();
            if (window.__SENTRY__?.hub?.getScope?.()?.clearBreadcrumbs) {
              window.__SENTRY__.hub.getScope().clearBreadcrumbs();
            }
          } catch (_) {}
        };
      }

      // 5. Native Media Lightbox Interceptor (Bypasses Discord's heavy React modal allocation)
      document.addEventListener('click', (e) => {
        const mediaContainer = e.target.closest('div[class*="imageWrapper_"], div[class*="imageContent_"], a[class*="originalLink_"], div[class*="video_"]');
        const mediaLink = e.target.closest('a[href*="cdn.discordapp.com/attachments/"], a[href*="media.discordapp.net/attachments/"]');

        let mediaUrl = null;
        let isVideo = false;

        if (mediaContainer) {
          const video = mediaContainer.querySelector('video') || (mediaContainer.tagName === 'VIDEO' ? mediaContainer : null);
          const img = mediaContainer.querySelector('img') || (mediaContainer.tagName === 'IMG' ? mediaContainer : null);
          const parentA = mediaContainer.closest('a') || mediaContainer.querySelector('a');

          if (video) {
            mediaUrl = video.currentSrc || video.src;
            isVideo = true;
          } else if (parentA && parentA.href && (parentA.href.includes('discordapp.com') || parentA.href.includes('discordapp.net'))) {
            mediaUrl = parentA.href;
          } else if (img) {
            mediaUrl = (img.currentSrc && !img.currentSrc.startsWith('data:')) ? img.currentSrc : (img.__nokoOriginalSrc || img.src);
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
          try {
            window.webkit?.messageHandlers?.nokoCordApp?.postMessage({
              action: 'openMedia',
              url: mediaUrl,
              isVideo: isVideo
            });
          } catch (_) {}
        }
      }, true);
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
        } else if action == "toggleZenMode" {
            runtime.onToggleZenMode?()
        } else if action == "channelChanged" {
            runtime.onChannelChanged?()
        } else if action == "openMedia" {
            if let urlStr = body["url"] as? String,
               let url = URL(string: urlStr),
               BrowserPolicy.isDiscordMediaURL(url) {
                let isVideo = body["isVideo"] as? Bool ?? false
                runtime.onOpenMedia?(url, isVideo)
            }
        } else if action == "notification" {
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
