import Foundation
import XCTest
@testable import NokoCordCore

@MainActor
final class TanCapabilityTests: XCTestCase {
    private func package(
        id: String = "fixture.capability",
        target: TanTarget = .isolated,
        capabilities: [TanCapability] = [.appearanceRead]
    ) -> TanPackage {
        let manifest = TanManifest(
            schemaVersion: 1,
            id: id,
            name: "Capability Fixture",
            version: "1.0.0",
            description: "A bounded capability fixture.",
            authors: ["fixture-author"],
            target: target,
            entry: target == .css ? nil : "main.js",
            stylesheet: nil,
            capabilities: capabilities,
            requiresReload: false,
            source: nil,
            license: "MIT"
        )
        return TanPackage(
            manifest: manifest,
            javascript: target == .css ? nil : "NokoTan.register({ start() {} });",
            css: nil,
            origin: "Local fixture"
        )
    }

    func testAppearanceReadRequiresBoundIdentityHashAndRuntimeNonce() {
        let tan = package()
        let valid: [String: Any] = [
            "type": "capability",
            "tanID": tan.id,
            "contentHash": tan.contentHash,
            "runtimeNonce": "runtime-fixture",
            "capability": TanCapability.appearanceRead.rawValue
        ]

        XCTAssertEqual(
            TanRuntime.validateTanBridgeRequest(valid, package: tan, runtimeNonce: "runtime-fixture"),
            .appearanceRead
        )

        var missingNonce = valid
        missingNonce.removeValue(forKey: "runtimeNonce")
        XCTAssertEqual(
            TanRuntime.validateTanBridgeRequest(missingNonce, package: tan, runtimeNonce: "runtime-fixture"),
            .rejected
        )

        var wrongHash = valid
        wrongHash["contentHash"] = String(repeating: "0", count: 64)
        XCTAssertEqual(
            TanRuntime.validateTanBridgeRequest(wrongHash, package: tan, runtimeNonce: "runtime-fixture"),
            .rejected
        )

        var wrongIdentity = valid
        wrongIdentity["tanID"] = "fixture.other"
        XCTAssertEqual(
            TanRuntime.validateTanBridgeRequest(wrongIdentity, package: tan, runtimeNonce: "runtime-fixture"),
            .rejected
        )

        var extraPayload = valid
        extraPayload["payload"] = String(repeating: "x", count: 5_000)
        XCTAssertEqual(
            TanRuntime.validateTanBridgeRequest(extraPayload, package: tan, runtimeNonce: "runtime-fixture"),
            .rejected
        )
    }

    func testPageWorldTanCannotUseAppearanceReadEvenWithAValidRequest() {
        let tan = package(target: .page, capabilities: [])
        let request: [String: Any] = [
            "type": "capability",
            "tanID": tan.id,
            "contentHash": tan.contentHash,
            "runtimeNonce": "runtime-fixture",
            "capability": TanCapability.appearanceRead.rawValue
        ]

        XCTAssertEqual(
            TanRuntime.validateTanBridgeRequest(request, package: tan, runtimeNonce: "runtime-fixture"),
            .rejected
        )
    }

    func testStatusRequestsUseTheSameIdentityBoundary() {
        let tan = package()
        let request: [String: Any] = [
            "type": "status",
            "tanID": tan.id,
            "contentHash": tan.contentHash,
            "runtimeNonce": "runtime-fixture",
            "state": "started"
        ]

        XCTAssertEqual(
            TanRuntime.validateTanBridgeRequest(request, package: tan, runtimeNonce: "runtime-fixture"),
            .status(.started)
        )

        var stale = request
        stale["runtimeNonce"] = "stale-runtime"
        XCTAssertEqual(
            TanRuntime.validateTanBridgeRequest(stale, package: tan, runtimeNonce: "runtime-fixture"),
            .rejected
        )
    }

    func testPrivateAppBridgeRequiresNonceAndAllowsOnlyKnownBoundedActions() {
        XCTAssertEqual(TanRuntime.appBridgeContentWorldName, "NokoCord.App")

        XCTAssertEqual(
            TanRuntime.validateAppBridgeRequest(
                ["action": "toggleTans", "runtimeNonce": "runtime-fixture"],
                runtimeNonce: "runtime-fixture"
            ),
            .allowed(.toggleTans)
        )

        XCTAssertEqual(
            TanRuntime.validateAppBridgeRequest(
                ["action": "writeBookmark", "runtimeNonce": "runtime-fixture"],
                runtimeNonce: "runtime-fixture"
            ),
            .rejected
        )

        XCTAssertEqual(
            TanRuntime.validateAppBridgeRequest(
                ["action": "toggleTans"],
                runtimeNonce: "runtime-fixture"
            ),
            .rejected
        )

        XCTAssertEqual(
            TanRuntime.validateAppBridgeRequest(
                [
                    "action": "notification",
                    "runtimeNonce": "runtime-fixture",
                    "title": "A bounded title",
                    "body": String(repeating: "x", count: 513)
                ],
                runtimeNonce: "runtime-fixture"
            ),
            .rejected
        )
    }

    func testTanSourceCarriesIdentityAndKeepsResourcesBounded() {
        let tan = package()
        let source = TanRuntime.source(tan, allowedOrigin: "https://discord.com", runtimeNonce: "runtime-fixture")

        XCTAssertTrue(source.contains(tan.id))
        XCTAssertTrue(source.contains(tan.contentHash))
        XCTAssertTrue(source.contains("runtime-fixture"))
        XCTAssertTrue(source.contains("Resource limit reached"))
        XCTAssertTrue(source.contains("timerCount >= 64"))
        XCTAssertTrue(source.contains("listenerCount >= 128"))
        XCTAssertTrue(source.contains("mountCount >= 64"))
        XCTAssertFalse(source.contains("nokoCordApp"))
    }

    func testAppScriptCarriesNonceAndDoesNotAdvertisePageWorldBridge() {
        let source = TanRuntime.discordInjectedScript(nonce: "runtime-fixture")

        XCTAssertTrue(source.contains("runtime-fixture"))
        XCTAssertTrue(source.contains("postApp"))
        XCTAssertFalse(source.contains("messageHandlers?.nokoCordApp?.postMessage({ action:"))
    }
}
