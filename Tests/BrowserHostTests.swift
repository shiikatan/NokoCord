import AppKit
import WebKit
import XCTest
@testable import NokoCordCore

@MainActor
final class BrowserHostTests: XCTestCase {
    func testBrowserIsLazyAndRetainsOneUnmodifiedViewAcrossHomeTransitions() {
        _ = NSApplication.shared
        let engine = WKBrowserEngine(dataStore: .nonPersistent())
        XCTAssertNil(engine.browserView)
        engine.showHome()
        XCTAssertNil(engine.browserView)
        let first = engine.prepareBrowser()
        XCTAssertTrue(first === engine.prepareBrowser())
        engine.showHome()
        XCTAssertTrue(first === engine.prepareBrowser())
        XCTAssertNil(first.url) // Configuration checks never contact Discord.
        XCTAssertTrue(first.customUserAgent?.isEmpty ?? true)
        XCTAssertTrue(first.configuration.userContentController.userScripts.isEmpty)
        #if DEBUG
        XCTAssertTrue(first.isInspectable)
        #else
        XCTAssertFalse(first.isInspectable)
        #endif
        XCTAssertFalse(first.configuration.websiteDataStore.isPersistent)
    }
    func testProductionProfileConfigurationIsPersistentWithoutLoadingPage() {
        _ = NSApplication.shared
        let engine = WKBrowserEngine()
        let view = engine.prepareBrowser()
        XCTAssertTrue(view.configuration.websiteDataStore.isPersistent)
        XCTAssertNil(view.url)
    }
    func testClearingAnIsolatedProfileDisposesViewAndAllowsOneReplacement() async {
        _ = NSApplication.shared
        let engine = WKBrowserEngine(dataStore: .nonPersistent())
        let previous = engine.prepareBrowser()
        await engine.clearProfile()
        XCTAssertNil(engine.browserView)
        XCTAssertEqual(engine.lifecycle.phase, .dormant)
        XCTAssertFalse(engine.lifecycle.isVisible)
        XCTAssertFalse(engine.canGoBack)
        XCTAssertTrue(engine.downloads.records.isEmpty)
        let replacement = engine.prepareBrowser()
        XCTAssertFalse(replacement === previous)
        XCTAssertTrue(replacement === engine.prepareBrowser())
        XCTAssertNil(replacement.url)
    }
    func testTemporaryCacheResetPreservesCookiesAndCreatesOneFreshView() async {
        _ = NSApplication.shared
        let store = WKWebsiteDataStore.nonPersistent()
        let engine = WKBrowserEngine(dataStore: store)
        let cookie = HTTPCookie(properties: [
            .domain: "discord.com", .path: "/", .name: "nokocord-test",
            .value: "keep", .secure: "TRUE"
        ])!
        await store.httpCookieStore.setCookie(cookie)
        var previous: WKWebView? = engine.prepareBrowser()
        for _ in 0..<3 {
            await engine.resetTemporaryCache(reopen: false)
            XCTAssertNil(engine.browserView)
            XCTAssertEqual(engine.lifecycle.phase, .dormant)
            let replacement = engine.prepareBrowser()
            XCTAssertFalse(previous === replacement)
            XCTAssertTrue(replacement === engine.prepareBrowser())
            XCTAssertTrue(replacement.configuration.websiteDataStore === store)
            previous = replacement
        }
        let cookies = await store.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.contains { $0.name == cookie.name && $0.value == cookie.value })
    }

    func testTemporaryCacheResetReleasesTheOldWebView() async {
        _ = NSApplication.shared
        let engine = WKBrowserEngine(dataStore: .nonPersistent())
        weak var oldView: WKWebView?
        autoreleasepool { oldView = engine.prepareBrowser() }
        XCTAssertNotNil(oldView)
        await engine.resetTemporaryCache(reopen: false)
        for _ in 0..<50 where oldView != nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(oldView)
        XCTAssertNil(engine.browserView)
    }
}
