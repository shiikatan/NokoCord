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
    private let allowedOrigin: String

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
    }
    private func clearHandlers() {
        for package in configured { controller?.removeScriptMessageHandler(forName: Self.handlerName(package), contentWorld: world(package)) }
        handlers.removeAll()
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
