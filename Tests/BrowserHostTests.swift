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
        XCTAssertFalse(first.isInspectable)
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
}
