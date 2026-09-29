import XCTest
@testable import NokoCordCore

final class DiscordCompatibilityTests: XCTestCase {
    func testSupportedDiscordRoutesAreLimitedToApplicationSurfaces() {
        XCTAssertEqual(DiscordCompatibilityService.route(for: URL(string: "https://discord.com/app"), origin: "https://discord.com"), "app")
        XCTAssertEqual(DiscordCompatibilityService.route(for: URL(string: "https://discord.com/channels/123/456"), origin: "https://discord.com"), "channels")
        XCTAssertTrue(DiscordCompatibilityService.accepts(URL(string: "https://discord.com/channels/123/456"), origin: "https://discord.com"))
        XCTAssertFalse(DiscordCompatibilityService.accepts(URL(string: "https://discord.com/settings"), origin: "https://discord.com"))
        XCTAssertFalse(DiscordCompatibilityService.accepts(URL(string: "https://discord.com/login"), origin: "https://discord.com"))
    }

    func testOriginAndCredentialsAreRejected() {
        XCTAssertFalse(DiscordCompatibilityService.accepts(URL(string: "https://evil.example/app"), origin: "https://discord.com"))
        XCTAssertFalse(DiscordCompatibilityService.accepts(URL(string: "https://user:pass@discord.com/app"), origin: "https://discord.com"))
        XCTAssertFalse(DiscordCompatibilityService.accepts(URL(string: "http://discord.com/app"), origin: "https://discord.com"))
    }

    func testFixtureOriginRemainsAvailableForDeterministicRuntimeFixtures() {
        XCTAssertEqual(DiscordCompatibilityService.route(for: URL(string: "https://fixture.invalid/app"), origin: "https://fixture.invalid"), "fixture")
        XCTAssertTrue(DiscordCompatibilityService.accepts(URL(string: "https://fixture.invalid/app"), origin: "https://fixture.invalid"))
    }

    func testUnsupportedRouteFailsOpenPerFeature() {
        let generation = UUID()
        let snapshot = DiscordCompatibilityService.snapshot(for: URL(string: "https://discord.com/settings"), origin: "https://discord.com", generation: generation)
        XCTAssertEqual(snapshot.generation, generation)
        XCTAssertEqual(snapshot.route, "settings")
        XCTAssertEqual(snapshot.probeVersion, DiscordCompatibilityService.probeVersion)
        XCTAssertTrue(DiscordFeature.allCases.allSatisfy { snapshot.state(for: $0) == .unsupported })
    }
}
