import XCTest
@testable import NokoCordCore

final class BrowserPolicyTests: XCTestCase {
    func testWorkspaceOriginRejectsLookalikesCredentialsAndNonstandardPorts() {
        for value in ["https://discord.com/app", "https://discord.com:443/login"] {
            XCTAssertTrue(BrowserPolicy.isDiscordOrigin(URL(string: value)))
        }
        for value in ["http://discord.com/app", "https://discord.com.example.com/app", "https://discord.com:8443/app",
                      "https://discord.com@evil.example/app", "https://user@discord.com/app", "file:///app", "https://discord.com./app"] {
            XCTAssertFalse(BrowserPolicy.isDiscordOrigin(URL(string: value)), value)
        }
    }
    func testExternalNavigationRequiresUserActionAndSafeScheme() {
        let link = URL(string: "https://example.com/document")!
        XCTAssertEqual(BrowserPolicy.route(link, isMainFrame: true, userActivated: true), .external)
        XCTAssertEqual(BrowserPolicy.route(link, isMainFrame: true, userActivated: false), .deny)
        for scheme in ["file", "javascript", "discord", "data"] {
            XCTAssertEqual(BrowserPolicy.route(URL(string: "\(scheme):payload"), isMainFrame: true, userActivated: true), .deny)
        }
        XCTAssertEqual(BrowserPolicy.route(URL(string: "https://user:secret@example.com"), isMainFrame: true, userActivated: true), .deny)
    }
    func testIframeResourcesAreNotRestrictedByDiscordHostList() {
        XCTAssertEqual(BrowserPolicy.route(URL(string: "https://challenge.example/frame"), isMainFrame: false, userActivated: false), .workspace)
    }
    func testMediaOriginMustMatchFrameAndTopLevel() {
        let discord = BrowserPolicy.home
        XCTAssertTrue(BrowserPolicy.permitsMediaPrompt(scheme: "https", host: "discord.com", port: 443, frameURL: discord, topURL: discord))
        XCTAssertFalse(BrowserPolicy.permitsMediaPrompt(scheme: "https", host: "discord.com", port: 443, frameURL: URL(string: "https://other.example"), topURL: discord))
        XCTAssertFalse(BrowserPolicy.permitsMediaPrompt(scheme: "https", host: "discord.com", port: 443, frameURL: discord, topURL: URL(string: "https://other.example")))
        XCTAssertFalse(BrowserPolicy.permitsMediaPrompt(scheme: "http", host: "discord.com", port: 80, frameURL: discord, topURL: discord))
        XCTAssertFalse(BrowserPolicy.permitsMediaPrompt(scheme: "https", host: "discord.com", port: 8443, frameURL: discord, topURL: discord))
    }
    func testSuggestedDownloadFilenameCannotSelectPathOrContainControlCharacters() {
        XCTAssertEqual(BrowserPolicy.filename("../../file.txt"), "file.txt")
        XCTAssertEqual(BrowserPolicy.filename("\u{0}name\n.txt"), "name.txt")
        XCTAssertEqual(BrowserPolicy.filename(".."), "Download")
        XCTAssertLessThanOrEqual(BrowserPolicy.filename(String(repeating: "x", count: 1000)).count, 180)
    }
    func testHideAndSleepDoNotUnloadOrReloadReadyWorkspace() {
        var lifecycle = BrowserLifecycle()
        lifecycle.show(); lifecycle.loading(); lifecycle.ready()
        lifecycle.hide(); lifecycle.sleep(); lifecycle.wake()
        XCTAssertEqual(lifecycle.phase, .ready)
        XCTAssertFalse(lifecycle.isVisible)
        XCTAssertFalse(lifecycle.isAsleep)
        lifecycle.show()
        XCTAssertEqual(lifecycle.phase, .ready)
        lifecycle.crash(); lifecycle.hide(); lifecycle.show()
        XCTAssertEqual(lifecycle.phase, .crashed)
        lifecycle.loading(); lifecycle.ready()
        XCTAssertEqual(lifecycle.phase, .ready)
    }
}
