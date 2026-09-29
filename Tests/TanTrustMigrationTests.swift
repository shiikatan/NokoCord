import Foundation
import XCTest
@testable import NokoCordCore

final class TanTrustMigrationTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NokoCord-TanTrustMigrationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func package(
        id: String = "fixture.migration",
        target: TanTarget = .css,
        origin: String = "Local fixture",
        capabilities: [TanCapability] = [],
        css: String = ".fixture {}"
    ) -> TanPackage {
        let manifest = TanManifest(
            schemaVersion: 1,
            id: id,
            name: "Migration Fixture",
            version: "1.0.0",
            description: "A migration fixture.",
            authors: ["fixture-author"],
            target: target,
            entry: target == .css ? nil : "main.js",
            stylesheet: target == .css ? "style.css" : nil,
            capabilities: capabilities,
            requiresReload: false,
            source: nil,
            license: "MIT"
        )
        return TanPackage(
            manifest: manifest,
            javascript: target == .css ? nil : "NokoTan.register({ start() {} });",
            css: target == .css ? css : nil,
            origin: origin
        )
    }

    func testOldTrustRecordsDecodeWithSafeDefaultsAndRequireFreshApproval() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = package()
        let oldRecord: [String: Any] = [
            "tanID": fixture.id,
            "contentHash": fixture.contentHash,
            "approvedCapabilities": [],
            "approvedAt": "1970-01-01T00:01:40Z",
            "lastKnownGoodVersion": "1.0.0",
            "lastKnownGoodHash": fixture.contentHash,
            "health": "healthy",
            "failureCount": 0,
            "quarantineReason": NSNull()
        ]
        let envelope: [String: Any] = [
            "version": 1,
            "records": [fixture.id: oldRecord],
            "pendingReplacements": [:]
        ]
        try JSONSerialization.data(withJSONObject: envelope).write(to: root.appendingPathComponent("trust.json"))

        let store = try TanTrustStore(fileURL: root.appendingPathComponent("trust.json"))
        let migrated = try XCTUnwrap(store.record(for: fixture.id))
        XCTAssertNil(migrated.target)
        XCTAssertNil(migrated.trustOrigin)
        XCTAssertFalse(migrated.enabled)
        XCTAssertNil(migrated.lastFailureCategory)
        XCTAssertNil(migrated.lastFailureAt)
        XCTAssertFalse(migrated.matches(fixture), "old records must not inherit new trust")

        let refreshed = try store.invalidateIfHashChanged(fixture)
        XCTAssertEqual(refreshed.target, fixture.manifest.target)
        XCTAssertEqual(refreshed.trustOrigin, fixture.origin)
        XCTAssertFalse(refreshed.enabled)
        XCTAssertNil(refreshed.approvedAt)
        XCTAssertFalse(refreshed.matches(fixture))
    }

    func testInvalidFailureMetadataUsesBoundedSafeDefaults() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = package()
        let record: [String: Any] = [
            "tanID": fixture.id,
            "contentHash": fixture.contentHash,
            "approvedCapabilities": [],
            "approvedAt": NSNull(),
            "lastKnownGoodVersion": NSNull(),
            "lastKnownGoodHash": NSNull(),
            "health": "failed",
            "failureCount": 1,
            "quarantineReason": "raw helper error with private details",
            "lastFailureCategory": "raw helper error with private details",
            "lastFailureAt": "not-a-date",
            "enabled": true,
            "target": "css",
            "trustOrigin": "Local fixture"
        ]
        let envelope: [String: Any] = [
            "version": 1,
            "records": [fixture.id: record],
            "pendingReplacements": [:]
        ]
        try JSONSerialization.data(withJSONObject: envelope).write(to: root.appendingPathComponent("trust.json"))

        let store = try TanTrustStore(fileURL: root.appendingPathComponent("trust.json"))
        let restored = try XCTUnwrap(store.record(for: fixture.id))
        XCTAssertEqual(restored.lastFailureCategory, .unknown)
        XCTAssertNil(restored.lastFailureAt)
        XCTAssertFalse(restored.enabled, "a failed migrated record must not reactivate code")
        XCTAssertNotEqual(restored.quarantineReason, "raw helper error with private details")
    }

    func testTrustDiffIdentifiesHashTargetCapabilitiesAndOriginWithoutExposingFullHash() {
        let current = package(target: .isolated, origin: "Translated Tan", capabilities: [.appearanceRead])
        let previous = TanTrustRecord(
            tanID: current.id,
            contentHash: String(repeating: "a", count: 64),
            approvedCapabilities: [],
            approvedAt: Date(timeIntervalSince1970: 100),
            lastKnownGoodVersion: "0.9.0",
            lastKnownGoodHash: String(repeating: "a", count: 64),
            health: .healthy,
            failureCount: 0,
            quarantineReason: nil,
            target: .css,
            trustOrigin: "Local fixture",
            enabled: true
        )

        let diff = TanTrustDiff.make(package: current, record: previous)
        XCTAssertEqual(
            Set(diff.items.map(\.field)),
            Set([.contentHash, .target, .capabilities, .trustOrigin])
        )
        XCTAssertTrue(diff.requiresApproval)
        XCTAssertFalse(diff.items.contains { $0.currentValue.contains(current.contentHash) })
        XCTAssertTrue(diff.items.allSatisfy { $0.currentValue.count <= 80 })
    }

    func testFailureCategoryAndTimeArePersistedWithoutRawReasons() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = package()
        let store = try TanTrustStore(fileURL: root.appendingPathComponent("trust.json"))

        try store.approve(fixture, at: Date(timeIntervalSince1970: 100))
        let failed = try store.recordFailure(
            fixture,
            category: .helperUnavailable,
            reason: "private helper stderr and user data",
            at: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(failed.lastFailureCategory, .helperUnavailable)
        XCTAssertEqual(failed.lastFailureAt, Date(timeIntervalSince1970: 200))
        XCTAssertNotEqual(failed.quarantineReason, "private helper stderr and user data")
    }

    func testExplicitEnabledStateSurvivesDisableAndReapproval() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = package()
        let store = try TanTrustStore(fileURL: root.appendingPathComponent("trust.json"))

        let approved = try store.approve(fixture, at: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(approved.enabled)
        let disabled = try store.setEnabled(fixture, false, at: Date(timeIntervalSince1970: 200))
        XCTAssertFalse(disabled.enabled)
        XCTAssertTrue(disabled.isApproved)
        let reapproved = try store.setEnabled(fixture, true, at: Date(timeIntervalSince1970: 300))
        XCTAssertTrue(reapproved.enabled)
        XCTAssertTrue(reapproved.matches(fixture))
    }
}
