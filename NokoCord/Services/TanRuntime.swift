import AppKit
import WebKit
import CryptoKit

@MainActor
final class TanRuntime {
    let manager: TanManager
    private weak var view: WKWebView?
    private var controller: WKUserContentController?
    private var configured: [TanPackage] = []
    private let optimizesMaomao: Bool
    private var configuredSafeMode: Bool?
    private var preparedSources: [String: String] = [:]
    private var worlds: [String: WKContentWorld] = [:]
    private var activeHashes: [String: String] = [:]
    private var appliedReloadScripts: [String: String]?
    private var pendingReloadScripts: [String: String]?
    var retainedWorldCount: Int { worlds.count }
    private var handlers: [TanMessageHandler] = []
    private var generation = UUID()
    private var documentGeneration = UUID()
    private var transitionTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var livePackages: [String: TanPackage] = [:]
    private let allowedOrigin: String

    init(manager: TanManager, allowedOrigin: String = "https://discord.com",
         editionID: String? = EditionIdentity.current?.id) {
        self.manager = manager; self.allowedOrigin = allowedOrigin
        optimizesMaomao = editionID == "maomao"
    }
    func prepare(_ controller: WKUserContentController) {
        if optimizesMaomao, self.controller !== controller { configuredSafeMode = nil }
        self.controller = controller
        configureScripts()
    }
    func attach(_ view: WKWebView) { self.view = view }
    func detach() {
        documentGeneration = UUID()
        generation = UUID()
        transitionTask?.cancel(); transitionTask = nil
        resumeTask?.cancel(); resumeTask = nil
        clearHandlers()
        controller?.removeAllUserScripts()
        controller = nil; view = nil; configured = []; livePackages = [:]
        configuredSafeMode = nil; preparedSources.removeAll()
        worlds.removeAll(); activeHashes.removeAll()
        appliedReloadScripts = nil; pendingReloadScripts = nil
        manager.reloadRequired = false
    }
    @discardableResult
    func configurationChanged() -> Bool {
        let old = configured
        guard configureScripts() else { return false }
        updateReloadRequirement()
        if manager.safeMode, view?.url != nil {
            // Page-world code is trusted and may not be fully reversible. A new
            // document with no scripts is the reliable plain-Discord fallback.
            generation = UUID(); transitionTask?.cancel(); transitionTask = nil
            resumeTask?.cancel(); resumeTask = nil
            livePackages.removeAll(); worlds.removeAll()
            view?.reload()
            return true
        }
        applyLive(stopping: old, starting: manager.scriptActive.filter { $0.manifest.target != .page && !$0.manifest.requiresReload })
        return true
    }
    func documentNavigationStarted() {
        documentGeneration = UUID()
        // WebKit captures these scripts for the new document. A later Tan change
        // must not be mistaken for code that has already run in that document.
        pendingReloadScripts = reloadScriptHashes()
    }
    func pageDidLoad() {
        if let url = view?.url, Self.accepts(url, origin: allowedOrigin) {
            appliedReloadScripts = pendingReloadScripts ?? reloadScriptHashes()
        } else {
            appliedReloadScripts = [:]
        }
        pendingReloadScripts = nil
        updateReloadRequirement()
        // DOM Tans also work when Discord moves from /app to /channels during
        // startup. Registration replaces its own prior instance, never a view.
        applyLive(stopping: [], starting: manager.scriptActive.filter { $0.manifest.target != .page && !$0.manifest.requiresReload })
    }
    func locationChanged() {
        guard let url = view?.url else { return }
        if !Self.accepts(url, origin: allowedOrigin) {
            applyLive(stopping: configured + Array(livePackages.values), starting: [])
        } else {
            applyLive(stopping: [], starting: manager.scriptActive.filter { $0.manifest.target != .page && !$0.manifest.requiresReload })
        }
        updateReloadRequirement()
    }
    func didWake() {
        guard let view, let url = view.url, Self.accepts(url, origin: allowedOrigin), !manager.safeMode else { return }
        resumeTask?.cancel()
        let current = generation
        let document = documentGeneration
        let packages = manager.scriptActive
        let pendingTransition = transitionTask
        resumeTask = Task { @MainActor [weak self, weak view] in
            await pendingTransition?.value
            guard let self, let view else { return }
            defer { if self.generation == current { self.resumeTask = nil } }
            for package in packages {
                guard !Task.isCancelled, self.generation == current else { return }
                let key = Self.quote(Self.key(package))
                // Live-safe Tans can recover a missing document instance.
                // Page-world/reload-only packages still require navigation.
                let recoverable = package.manifest.target != .page && !package.manifest.requiresReload
                if self.optimizesMaomao {
                    let probe = self.probe("const state = globalThis[\(key)]; if (!state) return false; state.resume?.(); return true;")
                    do {
                        let resumed = try await self.evaluateProbe(probe, view: view, world: self.world(package))
                        guard !Task.isCancelled, self.generation == current, self.documentGeneration == document,
                              self.view === view, !self.manager.safeMode, let url = view.url,
                              Self.accepts(url, origin: self.allowedOrigin) else { return }
                        if !resumed && recoverable { try await self.evaluate(self.preparedSource(package), view: view, world: self.world(package)) }
                    } catch { /* Resume failures retain their existing best-effort behavior. */ }
                } else {
                    let recovery = recoverable ? "else {\n\(self.preparedSource(package))\n}" : ""
                    try? await self.evaluate("if (globalThis[\(key)]) { globalThis[\(key)].resume?.(); } \(recovery)", view: view, world: self.world(package))
                }
            }
        }
    }
    private func reloadScriptHashes() -> [String: String] {
        Dictionary(uniqueKeysWithValues: configured.compactMap { package in
            guard package.manifest.target == .page || package.manifest.requiresReload,
                  let hash = activeHashes[package.id] else { return nil }
            return (package.id, hash)
        })
    }
    private func updateReloadRequirement() {
        guard let url = view?.url, Self.accepts(url, origin: allowedOrigin),
              let appliedReloadScripts else { manager.reloadRequired = false; return }
        manager.reloadRequired = appliedReloadScripts != reloadScriptHashes()
    }
    @discardableResult
    private func configureScripts() -> Bool {
        guard let controller else { return false }
        let next = manager.scriptActive
        // Native Maomao providers own their separate document lifecycle.
        // Preserve script registrations and instances when their set is equal.
        if optimizesMaomao, configuredSafeMode == manager.safeMode,
           configured.count == next.count, zip(configured, next).allSatisfy({ MaomaoTanContent.matches($0, $1) }) { return false }
        let previous = optimizesMaomao ? Dictionary(uniqueKeysWithValues: configured.map { ($0.id, $0) }) : [:]
        let previousHashes = activeHashes
        let previousSources = preparedSources
        clearHandlers(); controller.removeAllUserScripts()
        configured = next
        if optimizesMaomao {
            configuredSafeMode = manager.safeMode
            activeHashes.removeAll(keepingCapacity: true)
            preparedSources.removeAll(keepingCapacity: true)
            for package in configured {
                let unchanged = previous[package.id].map { MaomaoTanContent.matches($0, package) } ?? false
                activeHashes[package.id] = unchanged ? previousHashes[package.id] ?? package.contentHash : package.contentHash
                preparedSources[package.id] = unchanged ? previousSources[package.id] ?? Self.source(package, allowedOrigin: allowedOrigin)
                    : Self.source(package, allowedOrigin: allowedOrigin)
            }
        } else {
            activeHashes = Dictionary(uniqueKeysWithValues: configured.map { ($0.id, $0.contentHash) })
        }
        for package in configured {
            let world = world(package)
            let handler = TanMessageHandler(runtime: self, package: package,
                                            fingerprint: optimizesMaomao ? activeHashes[package.id] : nil)
            controller.addScriptMessageHandler(handler, contentWorld: world, name: Self.handlerName(package))
            handlers.append(handler)
            controller.addUserScript(WKUserScript(source: preparedSource(package), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        }
        return true
    }
    private func preparedSource(_ package: TanPackage) -> String {
        preparedSources[package.id] ?? Self.source(package, allowedOrigin: allowedOrigin)
    }
    private func clearHandlers() {
        for package in configured { controller?.removeScriptMessageHandler(forName: Self.handlerName(package), contentWorld: world(package)) }
        handlers.removeAll()
    }
    private func applyLive(stopping: [TanPackage], starting: [TanPackage]) {
        resumeTask?.cancel(); resumeTask = nil
        generation = UUID(); let current = generation
        let document = documentGeneration
        guard let view else { return }
        let next = Dictionary(uniqueKeysWithValues: starting.map { ($0.id, $0) })
        let pendingStops = Dictionary((stopping + Array(livePackages.values)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values.filter { old in
            guard let replacement = next[old.id] else { return true }
            return !MaomaoTanContent.matches(old, replacement)
        }
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
                do {
                    if self.optimizesMaomao {
                        let key = Self.quote(Self.key(package))
                        let fingerprint = Self.quote(self.activeHashes[package.id] ?? package.contentHash)
                        // A rejected navigation hook may have side effects.
                        // Stop that exact instance here so the full wrapper
                        // cannot invoke its hook a second time during recovery.
                        let reused = try await self.evaluateProbe(self.probe("const state = globalThis[\(key)]; if (state?.fingerprint !== \(fingerprint)) return false; if (state.refreshLocation?.() === true) return true; state.stop(); return false;"), view: view, world: self.world(package))
                        guard !Task.isCancelled, self.generation == current, self.documentGeneration == document,
                              self.view === view, !self.manager.safeMode, let url = view.url,
                              Self.accepts(url, origin: self.allowedOrigin) else { return }
                        if reused { continue }
                    }
                    try await self.evaluate(self.preparedSource(package), view: view, world: self.world(package))
                }
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
    private func probe(_ body: String) -> String {
        "(() => { if (location.origin !== \(Self.quote(allowedOrigin)) || (location.origin === 'https://discord.com' && location.pathname !== '/app' && !location.pathname.startsWith('/channels/'))) return false; \(body) })()"
    }
    private func evaluateProbe(_ source: String, view: WKWebView, world: WKContentWorld) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(source, in: nil, in: world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? Bool == true)
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
        if request.type == "status", let state = request.state, let event = TanLifecycleEvent(rawValue: state), event != .rejected {
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
        precondition(package.manifest.target != .native, "Native Tans cannot be injected into WebKit")
        let nativeAllowed = package.manifest.target == .isolated && package.manifest.capabilities.contains(.appearanceRead)
        return #"""
        (() => {
          'use strict';
          if (location.origin !== \#(quote(allowedOrigin))) return;
          const allowed = () => location.origin === \#(quote(allowedOrigin)) &&
            (location.origin !== 'https://discord.com' || location.pathname === '/app' || location.pathname.startsWith('/channels/'));
          if (!allowed()) return;
          const key = \#(quote(key(package)));
          const fingerprint = \#(quote(package.contentHash));
          // A route change or didFinish callback can revisit the same live
          // document. Keep its listeners/state when the package is unchanged.
          if (globalThis[key]?.fingerprint === fingerprint && globalThis[key].refreshLocation?.()) return;
          globalThis[key]?.stop();
          let definition = null, cleanup = null, style = null, stopped = false;
          let documentLocation = location.href;
          const send = body => window.webkit.messageHandlers[\#(quote(handlerName(package)))].postMessage(body);
          const report = state => { try { send({type:'status', state}).catch(() => {}); } catch {} };
          const disposers = new Set();
          const own = dispose => {
            if (stopped || disposers.size >= 256) { dispose(); throw new Error('Resource limit reached'); }
            disposers.add(dispose);
            return () => { if (disposers.delete(dispose)) dispose(); };
          };
          const state = {
            fingerprint,
            refreshLocation() {
              if (stopped || !allowed()) return false;
              if (documentLocation === location.href) return true;
              // Legacy packages may attach directly to the old page's nodes.
              // Only an explicit navigation hook opts out of their restart.
              if (typeof definition?.navigationChanged !== 'function') return false;
              try {
                const result = definition.navigationChanged();
                if (result && typeof result.then === 'function') return false;
                documentLocation = location.href;
                return true;
              } catch { return false; }
            },
            resume() {
              if (stopped || !allowed()) return;
              try {
                const result = definition?.resume?.();
                if (result && typeof result.then === 'function') throw new Error('Async lifecycle is not supported in schema 1');
              } catch { report('failed'); }
            },
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
    init(runtime: TanRuntime, package: TanPackage, fingerprint: String? = nil) {
        self.runtime = runtime; self.package = package; self.fingerprint = fingerprint ?? package.contentHash
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        if Date().timeIntervalSince(interval) > 1 { interval = Date(); count = 0 }
        count += 1
        guard count <= 20, let runtime else { replyHandler(nil, "Request limit reached"); return }
        runtime.receive(message, package: package, fingerprint: fingerprint, reply: replyHandler)
    }
}
