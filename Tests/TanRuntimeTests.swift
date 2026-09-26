import AppKit
import WebKit
import XCTest
@testable import NokoCordCore

@MainActor
final class TanRuntimeTests: XCTestCase {
    private let fixtureOrigin = "https://fixture.invalid"

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NokoCord-TanRuntimeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeView(runtime: TanRuntime) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        runtime.prepare(configuration.userContentController)
        let view = WKWebView(frame: .zero, configuration: configuration)
        runtime.attach(view)
        return view
    }

    private func javascriptPackage(id: String, source: String) -> TanPackage {
        let manifest = TanManifest(schemaVersion: 1,
                                   id: id,
                                   name: "Fixture \(id)",
                                   version: "1.0.0",
                                   description: "A local runtime fixture.",
                                   authors: ["fixture-author"],
                                   target: .isolated,
                                   entry: "main.js",
                                   stylesheet: nil,
                                   capabilities: [],
                                   requiresReload: false,
                                   source: nil,
                                   license: "MIT")
        return TanPackage(manifest: manifest, javascript: source, css: nil, origin: "Local fixture")
    }

    private func loadFixture(_ view: WKWebView, runtime: TanRuntime) async throws {
        view.loadHTMLString("<html><head></head><body><main id='fixture'>Fixture</main></body></html>",
                            baseURL: URL(string: fixtureOrigin + "/app")!)
        for _ in 0..<100 {
            if let ready = try? await view.evaluateJavaScript("document.readyState === 'complete' && document.getElementById('fixture') !== null") as? Bool,
               ready {
                runtime.pageDidLoad()
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Fixture page did not finish loading")
        runtime.pageDidLoad()
    }

    private func waitForCount(_ view: WKWebView, _ expression: String, expected: Int) async throws -> Int {
        var last = -1
        for _ in 0..<100 {
            if let result = try? await view.evaluateJavaScript(expression) as? Int {
                last = result
                if result == expected { return result }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return last
    }

    func testOriginalClearFocusAddsAndRemovesStyleWithEnableLifecycle() async throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TanManager(root: root)
        let original = try XCTUnwrap(TanPackage.originals.first(where: { $0.id == "noko.clear-focus" }))
        try manager.install(original)
        manager.setEnabled(original.id, true)
        let runtime = TanRuntime(manager: manager, allowedOrigin: fixtureOrigin)
        manager.onChange = { runtime.configurationChanged() }
        let view = makeView(runtime: runtime)
        try await loadFixture(view, runtime: runtime)

        let added = try await waitForCount(view, "document.querySelectorAll('style[data-noko-tan=\\\"noko.clear-focus\\\"]').length", expected: 1)
        XCTAssertEqual(added, 1)

        manager.setEnabled(original.id, false)
        let removed = try await waitForCount(view, "document.querySelectorAll('style[data-noko-tan=\\\"noko.clear-focus\\\"]').length", expected: 0)
        XCTAssertEqual(removed, 0)
    }

    func testScrollToolsCreatesAndRemovesItsOwnElement() async throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TanManager(root: root)
        let original = try XCTUnwrap(TanPackage.originals.first(where: { $0.id == "noko.scroll-tools" }))
        try manager.install(original)
        manager.setEnabled(original.id, true)
        let runtime = TanRuntime(manager: manager, allowedOrigin: fixtureOrigin)
        manager.onChange = { runtime.configurationChanged() }
        let view = makeView(runtime: runtime)
        try await loadFixture(view, runtime: runtime)

        let created = try await waitForCount(view, "document.querySelectorAll('[data-noko-scroll-tools]').length", expected: 1)
        XCTAssertEqual(created, 1)

        manager.setEnabled(original.id, false)
        let removed = try await waitForCount(view, "document.querySelectorAll('[data-noko-scroll-tools]').length", expected: 0)
        XCTAssertEqual(removed, 0)
    }

    func testSafeModeLeavesFixturePageUnmodifiedAndNoUserScripts() async throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = TanManager(root: root)
        let original = try XCTUnwrap(TanPackage.originals.first(where: { $0.id == "noko.scroll-tools" }))
        try seeded.install(original)
        seeded.setEnabled(original.id, true)

        let manager = TanManager(root: root, launchSafeMode: true)
        XCTAssertTrue(manager.safeMode)
        XCTAssertTrue(manager.active.isEmpty)
        let runtime = TanRuntime(manager: manager, allowedOrigin: fixtureOrigin)
        let view = makeView(runtime: runtime)
        XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
        try await loadFixture(view, runtime: runtime)

        let elementCount = try await waitForCount(view, "document.querySelectorAll('[data-noko-scroll-tools], style[data-noko-tan]').length", expected: 0)
        XCTAssertEqual(elementCount, 0)
        XCTAssertEqual(manager.enabledIDs, Set([original.id]))
    }

    func testEnteringSafeModeWhilePageIsAliveStopsActiveTanAndRemovesScripts() async throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TanManager(root: root)
        let original = try XCTUnwrap(TanPackage.originals.first(where: { $0.id == "noko.scroll-tools" }))
        try manager.install(original)
        manager.setEnabled(original.id, true)
        let runtime = TanRuntime(manager: manager, allowedOrigin: fixtureOrigin)
        manager.onChange = { runtime.configurationChanged() }
        let view = makeView(runtime: runtime)
        try await loadFixture(view, runtime: runtime)
        let startedCount = try await waitForCount(view, "document.querySelectorAll('[data-noko-scroll-tools]').length", expected: 1)
        XCTAssertEqual(startedCount, 1)
        XCTAssertFalse(view.configuration.userContentController.userScripts.isEmpty)

        manager.setSafeMode(true)
        XCTAssertTrue(manager.safeMode)
        // Safe Mode deliberately reloads the document. Replace that fixture.invalid
        // navigation with the same deterministic local HTML instead of contacting a host.
        try await loadFixture(view, runtime: runtime)
        let safeCount = try await waitForCount(view, "document.querySelectorAll('[data-noko-scroll-tools], style[data-noko-tan]').length", expected: 0)
        XCTAssertEqual(safeCount, 0)
        XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
        XCTAssertEqual(manager.enabledIDs, Set([original.id]))
    }

    func testPageTanRunsAtDocumentStartAndDisablingRequiresReload() async throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = TanManifest(schemaVersion: 1,
                                   id: "fixture.page-tan",
                                   name: "Fixture Page Tan",
                                   version: "1.0.0",
                                   description: "A page-world fixture.",
                                   authors: ["fixture-author"],
                                   target: .page,
                                   entry: "main.js",
                                   stylesheet: nil,
                                   capabilities: [],
                                   requiresReload: false,
                                   source: nil,
                                   license: "MIT")
        let package = TanPackage(manifest: manifest,
                                 javascript: "document.documentElement.setAttribute('data-fixture-page-tan', 'active');",
                                 css: nil,
                                 origin: "Local fixture")
        let manager = TanManager(root: root)
        try manager.install(package)
        manager.setEnabled(package.id, true)
        let runtime = TanRuntime(manager: manager, allowedOrigin: fixtureOrigin)
        manager.onChange = { runtime.configurationChanged() }
        let view = makeView(runtime: runtime)
        try await loadFixture(view, runtime: runtime)

        let marker = try await view.evaluateJavaScript("document.documentElement.getAttribute('data-fixture-page-tan')") as? String
        XCTAssertEqual(marker, "active")
        XCTAssertFalse(manager.reloadRequired)

        manager.setEnabled(package.id, false)
        XCTAssertTrue(manager.reloadRequired)
        XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
    }

    func testRapidEnableDisableEnableThenDisableLeavesOneCleanupTrackedElement() async throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TanManager(root: root)
        let original = try XCTUnwrap(TanPackage.originals.first(where: { $0.id == "noko.clear-focus" }))
        try manager.install(original)
        let runtime = TanRuntime(manager: manager, allowedOrigin: fixtureOrigin)
        manager.onChange = { runtime.configurationChanged() }
        let view = makeView(runtime: runtime)
        try await loadFixture(view, runtime: runtime)

        manager.setEnabled(original.id, true)
        manager.setEnabled(original.id, false)
        manager.setEnabled(original.id, true)
        let rapidEnabledCount = try await waitForCount(view, "document.querySelectorAll('style[data-noko-tan]').length", expected: 1)
        XCTAssertEqual(rapidEnabledCount, 1)
        manager.setEnabled(original.id, false)
        let rapidDisabledCount = try await waitForCount(view, "document.querySelectorAll('style[data-noko-tan]').length", expected: 0)
        XCTAssertEqual(rapidDisabledCount, 0)
        XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
    }

    func testRepeatedEnableDisableAndUninstallReleasesAllRetainedWorlds() async throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TanManager(root: root)
        let runtime = TanRuntime(manager: manager, allowedOrigin: fixtureOrigin)
        manager.onChange = { runtime.configurationChanged() }
        let view = makeView(runtime: runtime)
        try await loadFixture(view, runtime: runtime)

        let original = try XCTUnwrap(TanPackage.originals.first(where: { $0.id == "noko.clear-focus" }))
        for cycle in 0..<24 {
            let manifest = TanManifest(schemaVersion: original.manifest.schemaVersion,
                                       id: "fixture.cycle-\(cycle)",
                                       name: original.manifest.name,
                                       version: original.manifest.version,
                                       description: original.manifest.description,
                                       authors: original.manifest.authors,
                                       target: original.manifest.target,
                                       entry: original.manifest.entry,
                                       stylesheet: original.manifest.stylesheet,
                                       capabilities: original.manifest.capabilities,
                                       requiresReload: original.manifest.requiresReload,
                                       source: original.manifest.source,
                                       license: original.manifest.license)
            let package = TanPackage(manifest: manifest, javascript: original.javascript, css: original.css, origin: original.origin)
            try manager.install(package)
            manager.setEnabled(package.id, true)
            let enabledCount = try await waitForCount(view, "document.querySelectorAll('style[data-noko-tan]').length", expected: 1)
            XCTAssertEqual(enabledCount, 1)
            manager.setEnabled(package.id, false)
            let disabledCount = try await waitForCount(view, "document.querySelectorAll('style[data-noko-tan]').length", expected: 0)
            XCTAssertEqual(disabledCount, 0)
            XCTAssertEqual(runtime.retainedWorldCount, 0)
            try manager.uninstall(package.id)
            XCTAssertEqual(runtime.retainedWorldCount, 0)
        }
        XCTAssertTrue(manager.installed.isEmpty)
        XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
    }

    func testManagedTimerListenerAndMountedElementAreRemovedOnDisable() async throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = #"""
        NokoTan.register({
          start(api) {
            const mounted = document.createElement('div');
            mounted.setAttribute('data-fixture-mounted', 'true');
            api.mount(mounted);
            api.listen(window, 'fixture-event', () => {
              const fired = document.createElement('span');
              fired.setAttribute('data-fixture-listener-fired', 'true');
              document.body.append(fired);
            });
            api.interval(() => {
              const fired = document.createElement('span');
              fired.setAttribute('data-fixture-interval-fired', 'true');
              document.body.append(fired);
            }, 250);
            api.timeout(() => {
              const fired = document.createElement('span');
              fired.setAttribute('data-fixture-timeout-fired', 'true');
              document.body.append(fired);
            }, 500);
          }
        });
        """#
        let manager = TanManager(root: root)
        let package = javascriptPackage(id: "fixture.resources", source: source)
        try manager.install(package)
        manager.setEnabled(package.id, true)
        let runtime = TanRuntime(manager: manager, allowedOrigin: fixtureOrigin)
        manager.onChange = { runtime.configurationChanged() }
        let view = makeView(runtime: runtime)
        try await loadFixture(view, runtime: runtime)
        let mountedCount = try await waitForCount(view, "document.querySelectorAll('[data-fixture-mounted]').length", expected: 1)
        XCTAssertEqual(mountedCount, 1)

        manager.setEnabled(package.id, false)
        let removedCount = try await waitForCount(view, "document.querySelectorAll('[data-fixture-mounted]').length", expected: 0)
        XCTAssertEqual(removedCount, 0)
        let listenerCount = try await view.evaluateJavaScript("window.dispatchEvent(new Event('fixture-event')); document.querySelectorAll('[data-fixture-listener-fired]').length") as? Int
        XCTAssertEqual(listenerCount, 0)
        try await Task.sleep(nanoseconds: 650_000_000)
        let timerCount = try await view.evaluateJavaScript("document.querySelectorAll('[data-fixture-interval-fired], [data-fixture-timeout-fired]').length") as? Int
        XCTAssertEqual(timerCount, 0)
    }

    func testFailingStartCleansManagedResources() async throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = #"""
        NokoTan.register({
          start(api) {
            document.body.setAttribute('data-fixture-failed-attempt', 'true');
            const mounted = document.createElement('div');
            mounted.setAttribute('data-fixture-failed-mounted', 'true');
            api.mount(mounted);
            api.listen(window, 'fixture-failed-event', () => {
              const fired = document.createElement('span');
              fired.setAttribute('data-fixture-failed-listener', 'true');
              document.body.append(fired);
            });
            api.interval(() => {
              const fired = document.createElement('span');
              fired.setAttribute('data-fixture-failed-timer', 'true');
              document.body.append(fired);
            }, 100);
            throw new Error('fixture start failure');
          }
        });
        """#
        let manager = TanManager(root: root)
        let package = javascriptPackage(id: "fixture.failing", source: source)
        try manager.install(package)
        manager.setEnabled(package.id, true)
        let runtime = TanRuntime(manager: manager, allowedOrigin: fixtureOrigin)
        manager.onChange = { runtime.configurationChanged() }
        let view = makeView(runtime: runtime)
        try await loadFixture(view, runtime: runtime)
        let attemptedCount = try await waitForCount(view, "document.body.getAttribute('data-fixture-failed-attempt') === 'true' ? 1 : 0", expected: 1)
        XCTAssertEqual(attemptedCount, 1)
        let failedMountCount = try await waitForCount(view, "document.querySelectorAll('[data-fixture-failed-mounted]').length", expected: 0)
        XCTAssertEqual(failedMountCount, 0)
        let listenerCount = try await view.evaluateJavaScript("window.dispatchEvent(new Event('fixture-failed-event')); document.querySelectorAll('[data-fixture-failed-listener]').length") as? Int
        XCTAssertEqual(listenerCount, 0)
        try await Task.sleep(nanoseconds: 250_000_000)
        let timerCount = try await view.evaluateJavaScript("document.querySelectorAll('[data-fixture-failed-timer]').length") as? Int
        XCTAssertEqual(timerCount, 0)
    }

    func testMediaLightboxInterceptorIgnoresActionButtonsAndPickers() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        final class MockHandler: NSObject, WKScriptMessageHandler {
            var messages: [[String: Any]] = []
            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
                if let body = message.body as? [String: Any] { messages.append(body) }
            }
        }
        let handler = MockHandler()
        configuration.userContentController.add(handler, name: "nokoCordApp")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)

        let html = """
        <!DOCTYPE html><html><body>
            <div id="chat-messages-123">
                <div class="imageWrapper_abc imageContent_def">
                    <img id="gif-img" src="https://media.discordapp.net/attachments/123/456/sample.gif" />
                    <button id="fav-btn" class="favButton_123" aria-label="Add to Favorites">
                        <svg><path id="fav-path" d="M10 10"></path></svg>
                    </button>
                </div>
            </div>
            <div class="gifPicker_container">
                <img id="picker-gif" src="https://media.discordapp.net/attachments/123/456/picker.gif" />
            </div>
        </body></html>
        """
        _ = view.loadHTMLString(html, baseURL: nil)
        for _ in 0..<50 {
            if let ready = try? await view.evaluateJavaScript("document.getElementById('fav-btn') !== null && document.getElementById('picker-gif') !== null") as? Bool, ready { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }

        var script = TanRuntime.discordInjectedScript
        script = script.replacingOccurrences(of: "if (location.origin !== 'https://discord.com') return;", with: "// bypassed for test")
        _ = try await view.evaluateJavaScript(script)

        func click(_ id: String) async throws {
            _ = try await view.evaluateJavaScript("""
            (() => {
                const el = document.getElementById('\(id)');
                el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
            })()
            """)
        }

        handler.messages.removeAll()
        try await click("fav-path")
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(handler.messages.isEmpty, "Favorite button path click must not trigger openMedia")

        try await click("fav-btn")
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(handler.messages.isEmpty, "Favorite button click must not trigger openMedia")

        try await click("picker-gif")
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(handler.messages.isEmpty, "Picker GIF click must not trigger openMedia")

        try await click("gif-img")
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(handler.messages.count, 1)
        XCTAssertEqual(handler.messages.first?["action"] as? String, "openMedia")
        XCTAssertEqual(handler.messages.first?["url"] as? String, "https://media.discordapp.net/attachments/123/456/sample.gif")
    }
}
