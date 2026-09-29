import Foundation
import XCTest
@testable import NokoCordCore

final class DiscordCompatibilityTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Compatibility")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testProbeFactsReduceToFeatureDiagnosticsWithoutPageData() throws {
        let generation = UUID()
        let probeTime = Date(timeIntervalSince1970: 1_790_000_000)
        let facts = DiscordProbeFacts(
            generation: generation,
            documentReady: true,
            features: [
                .messages: DiscordFeatureProbeFacts(
                    anchors: [.messageList: .present, .messageRow: .present],
                    capabilities: [:]
                ),
                .composer: DiscordFeatureProbeFacts(
                    anchors: [.composer: .present],
                    capabilities: [:]
                )
            ],
            matchedFallbackIDs: [],
            timedOut: false,
            capturedAt: probeTime
        )

        let snapshot = try XCTUnwrap(DiscordCompatibilityService.snapshot(
            for: URL(string: "https://discord.com/channels/123/456"),
            origin: "https://discord.com",
            generation: generation,
            facts: facts,
            currentGeneration: generation,
            now: probeTime
        ))

        XCTAssertEqual(snapshot.state(for: .messages), .healthy)
        XCTAssertEqual(snapshot.diagnostic(for: .messages)?.reason, .healthy)
        XCTAssertEqual(snapshot.state(for: .composer), .healthy)
        XCTAssertEqual(snapshot.state(for: .calls), .unknown)
        XCTAssertEqual(snapshot.diagnostic(for: .calls)?.reason, .awaitingProbe)
        XCTAssertEqual(snapshot.lastProbeAt, probeTime)
        XCTAssertTrue(snapshot.diagnostics.values.allSatisfy { $0.matchedFallbacks.isEmpty })
    }

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

    func testRouteMatrixKeepsProtectedAndLookalikeSurfacesOutsideTheProbeBoundary() {
        let cases: [(String, String, Bool)] = [
            ("https://discord.com/", "app", true),
            ("https://discord.com/app/", "app", true),
            ("https://discord.com/channels/123/456", "channels", true),
            ("https://discord.com/login", "login", false),
            ("https://discord.com/register", "auth", false),
            ("https://discord.com/settings/appearance", "settings", false),
            ("https://discord.com/oauth2/authorize", "oauth", false),
            ("https://discord.com/invite/fixture", "invite", false),
            ("https://discord.com/download", "downloads", false),
            ("https://discord.com/not-a-discord-surface", "unknown", false),
            ("https://discord.com:8443/app", "unknown", false),
            ("https://discord.com.evil.example/app", "unknown", false),
            ("https://fixture.invalid/app", "fixture", true),
            ("http://fixture.invalid/app", "unknown", false),
            ("https://fixture.invalid/settings", "settings", false)
        ]

        for (urlString, expectedRoute, accepted) in cases {
            let url = URL(string: urlString)
            XCTAssertEqual(DiscordCompatibilityService.route(for: url, origin: urlString.hasPrefix("https://fixture.invalid") ? "https://fixture.invalid" : "https://discord.com"), expectedRoute, urlString)
            XCTAssertEqual(DiscordCompatibilityService.accepts(url, origin: urlString.hasPrefix("https://fixture.invalid") ? "https://fixture.invalid" : "https://discord.com"), accepted, urlString)
        }
    }

    func testSelectorDriftUsesNamedHashedFallbackAndDegradesOnlyMessages() throws {
        let fallback = try XCTUnwrap(DiscordCompatibilityService.fallbackMetadata.first { $0.id == "messages.legacy-row-class" })
        XCTAssertEqual(fallback.feature, .messages)
        XCTAssertEqual(fallback.anchor, .messageRow)
        XCTAssertEqual(fallback.selectorSHA256, "a03bc5acfb3bae90fe120c74d382e1cac35961663a5b44b4ed6c407ba3be1880")
        XCTAssertTrue(DiscordCompatibilityService.fallbackMetadata.allSatisfy { $0.selectorSHA256.count == 64 })
        XCTAssertTrue(DiscordCompatibilityService.fallbackMetadata.allSatisfy { $0.selectorSHA256.allSatisfy { $0.isHexDigit } })

        let generation = UUID()
        let facts = DiscordProbeFacts(
            generation: generation,
            documentReady: true,
            features: [
                .messages: DiscordFeatureProbeFacts(
                    anchors: [.messageList: .present, .messageRow: .missing]
                ),
                .composer: DiscordFeatureProbeFacts(
                    anchors: [.composer: .present]
                )
            ],
            matchedFallbackIDs: [fallback.id],
            capturedAt: Date(timeIntervalSince1970: 1_790_000_001)
        )

        let snapshot = try XCTUnwrap(DiscordCompatibilityService.snapshot(
            for: URL(string: "https://discord.com/channels/123/456"),
            origin: "https://discord.com",
            generation: generation,
            facts: facts,
            currentGeneration: generation,
            now: facts.capturedAt!
        ))

        XCTAssertEqual(snapshot.state(for: .messages), .degraded)
        XCTAssertEqual(snapshot.diagnostic(for: .messages)?.reason, .hashedFallbackInUse)
        XCTAssertEqual(snapshot.diagnostic(for: .messages)?.matchedFallbacks, [fallback])
        XCTAssertEqual(snapshot.state(for: .composer), .healthy)
        XCTAssertEqual(snapshot.state(for: .calls), .unknown)
    }

    func testMissingAnchorFixtureDisablesOnlyTheAffectedFeature() throws {
        let fixture = try fixture("missing-anchor.html")
        XCTAssertTrue(fixture.contains("data-noko-probe=\"message-list\""))
        XCTAssertFalse(fixture.contains("data-noko-probe=\"message-row\""))

        let generation = UUID()
        let facts = DiscordProbeFacts(
            generation: generation,
            documentReady: true,
            features: [
                .messages: DiscordFeatureProbeFacts(
                    anchors: [.messageList: .present, .messageRow: .missing]
                ),
                .composer: DiscordFeatureProbeFacts(
                    anchors: [.composer: .present]
                )
            ]
        )
        let snapshot = try XCTUnwrap(DiscordCompatibilityService.snapshot(
            for: URL(string: "https://discord.com/channels/123/456"),
            origin: "https://discord.com",
            generation: generation,
            facts: facts,
            currentGeneration: generation
        ))

        XCTAssertEqual(snapshot.state(for: .messages), .unsupported)
        XCTAssertEqual(snapshot.diagnostic(for: .messages)?.reason, .requiredAnchorMissing)
        XCTAssertEqual(snapshot.state(for: .composer), .healthy)
    }

    func testTimedOutProbeLeavesSupportedFeaturesUnknown() throws {
        let generation = UUID()
        let capturedAt = Date(timeIntervalSince1970: 1_790_000_002)
        let facts = DiscordProbeFacts(generation: generation,
                                      documentReady: true,
                                      timedOut: true,
                                      capturedAt: capturedAt)
        let snapshot = try XCTUnwrap(DiscordCompatibilityService.snapshot(
            for: URL(string: "https://discord.com/app"),
            origin: "https://discord.com",
            generation: generation,
            facts: facts,
            currentGeneration: generation,
            now: capturedAt
        ))

        XCTAssertTrue(DiscordFeature.allCases.allSatisfy { snapshot.state(for: $0) == .unknown })
        XCTAssertTrue(DiscordFeature.allCases.allSatisfy { snapshot.diagnostic(for: $0)?.reason == .probeTimedOut })
        XCTAssertEqual(snapshot.lastProbeAt, capturedAt)
    }

    func testOldOrMalformedProbeIsRejectedWithSanitizedDiagnostics() throws {
        let generation = UUID()
        let facts = DiscordProbeFacts(
            generation: generation,
            probeVersion: DiscordCompatibilityService.probeVersion - 1,
            documentReady: true,
            features: [.messages: DiscordFeatureProbeFacts(anchors: [.messageList: .present, .messageRow: .present])],
            capturedAt: Date(timeIntervalSince1970: 1_790_000_003)
        )
        let snapshot = try XCTUnwrap(DiscordCompatibilityService.snapshot(
            for: URL(string: "https://discord.com/app"),
            origin: "https://discord.com",
            generation: generation,
            facts: facts,
            currentGeneration: generation
        ))

        XCTAssertTrue(DiscordFeature.allCases.allSatisfy { snapshot.state(for: $0) == .unknown })
        XCTAssertTrue(DiscordFeature.allCases.allSatisfy { snapshot.diagnostic(for: $0)?.reason == .invalidProbe })
        XCTAssertFalse(snapshot.diagnostic(for: .messages)?.sanitizedMessage.contains("secret") ?? true)
    }

    func testStaleProbeResultIsIgnoredForTheCurrentDocumentGeneration() {
        let currentGeneration = UUID()
        let staleFacts = DiscordProbeFacts(
            generation: UUID(),
            documentReady: true,
            features: [.composer: DiscordFeatureProbeFacts(anchors: [.composer: .present])]
        )

        let snapshot = DiscordCompatibilityService.snapshot(
            for: URL(string: "https://discord.com/app"),
            origin: "https://discord.com",
            generation: currentGeneration,
            facts: staleFacts,
            currentGeneration: currentGeneration
        )
        XCTAssertNil(snapshot)
    }

    func testProbeScriptAndFixturesDoNotExposePageContent() throws {
        let script = DiscordCompatibilityService.probeScript(for: UUID())
        XCTAssertTrue(script.contains("matchedFallbackIDs"))
        XCTAssertTrue(script.contains("document.readyState"))
        for forbidden in ["textContent", "innerText", "innerHTML", "document.cookie", "localStorage", "sessionStorage"] {
            XCTAssertFalse(script.contains(forbidden), forbidden)
        }

        let supported = try fixture("supported.html")
        let drift = try fixture("selector-drift.html")
        XCTAssertTrue(supported.contains("data-noko-probe=\"message-row\""))
        XCTAssertTrue(drift.contains("message-legacy_fixture-hash"))
        XCTAssertFalse(drift.contains("role=\"article\""))
    }

    func testProbePayloadDecoderAcceptsOnlyBoundedTypedFacts() throws {
        let generation = UUID()
        let capturedAt = Date(timeIntervalSince1970: 1_790_000_004)
        let raw: [String: Any] = [
            "probeVersion": DiscordCompatibilityService.probeVersion,
            "generation": generation.uuidString,
            "documentReady": true,
            "features": [
                "messages": [
                    "anchors": ["messageList": "present", "messageRow": "present"],
                    "capabilities": [:]
                ]
            ],
            "matchedFallbackIDs": [],
            "timedOut": false
        ]

        let facts = try XCTUnwrap(DiscordCompatibilityService.probeFacts(
            from: raw,
            generation: generation,
            capturedAt: capturedAt
        ))
        XCTAssertEqual(facts.generation, generation)
        XCTAssertEqual(facts.features[.messages]?.observation(for: .messageRow), .present)
        XCTAssertEqual(facts.capturedAt, capturedAt)

        let stale = DiscordCompatibilityService.probeFacts(
            from: raw,
            generation: UUID(),
            capturedAt: capturedAt
        )
        XCTAssertNil(stale)
    }

    func testProbePayloadDecoderRejectsPageContentAndOversizedPayloads() {
        let generation = UUID()
        let oversized: [String: Any] = [
            "probeVersion": DiscordCompatibilityService.probeVersion,
            "generation": generation.uuidString,
            "documentReady": true,
            "features": [:],
            "matchedFallbackIDs": [],
            "timedOut": false,
            "unexpected": String(repeating: "x", count: DiscordCompatibilityService.maxProbePayloadBytes)
        ]
        XCTAssertNil(DiscordCompatibilityService.probeFacts(from: oversized, generation: generation))
        XCTAssertNil(DiscordCompatibilityService.probeFacts(from: "not-json", generation: generation))
    }
}
