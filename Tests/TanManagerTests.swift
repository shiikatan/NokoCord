import Foundation
import XCTest
@testable import NokoCordCore

@MainActor
final class TanManagerTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NokoCord-TanManagerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func package(id: String = "fixture.manager-trust", version: String = "1.0.0", css: String = ".fixture {}") -> TanPackage {
        let manifest = TanManifest(
            schemaVersion: 1,
            id: id,
            name: "Fixture Manager Trust",
            version: version,
            description: "A manager trust fixture.",
            authors: ["fixture-author"],
            target: .css,
            entry: nil,
            stylesheet: "style.css",
            capabilities: [],
            requiresReload: false,
            source: nil,
            license: "MIT"
        )
        return TanPackage(manifest: manifest, javascript: nil, css: css, origin: "Local fixture")
    }

    func testEnablementApprovesCurrentHashAndReplacementRequiresReapproval() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = package()
        let replacement = package(version: "1.0.1", css: ".replacement {}")
        let manager = TanManager(root: root)

        try manager.install(original)
        manager.setEnabled(original.id, true)
        let approved = try XCTUnwrap(manager.trustRecord(for: original.id))
        XCTAssertTrue(approved.matches(original))
        XCTAssertEqual(manager.enabledIDs, Set([original.id]))

        manager.setDeveloperMode(true)
        try manager.replaceFromLocalFolder(replacement)
        let changed = try XCTUnwrap(manager.trustRecord(for: original.id))
        XCTAssertEqual(changed.contentHash, replacement.contentHash)
        XCTAssertNil(changed.approvedAt)
        XCTAssertFalse(manager.enabledIDs.contains(original.id))
        XCTAssertTrue(manager.active.isEmpty)

        manager.setEnabled(original.id, true)
        XCTAssertTrue(try XCTUnwrap(manager.trustRecord(for: original.id)).matches(replacement))
        XCTAssertTrue(manager.enabledIDs.contains(original.id))
    }

    func testQuarantinePersistsAcrossRestartAndRecoveryRequiresFreshApproval() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = package()
        let manager = TanManager(root: root)
        try manager.install(fixture)
        manager.setEnabled(fixture.id, true)

        manager.record(fixture.id, event: .failed)
        manager.record(fixture.id, event: .failed)
        manager.record(fixture.id, event: .failed)
        XCTAssertEqual(manager.trustRecord(for: fixture.id)?.health, .quarantined)
        XCTAssertFalse(manager.enabledIDs.contains(fixture.id))

        let restarted = TanManager(root: root)
        XCTAssertEqual(restarted.trustRecord(for: fixture.id)?.health, .quarantined)
        XCTAssertFalse(restarted.enabledIDs.contains(fixture.id))

        restarted.recoverQuarantined(fixture.id)
        XCTAssertEqual(restarted.trustRecord(for: fixture.id)?.health, .awaitingApproval)
        XCTAssertNil(restarted.trustRecord(for: fixture.id)?.approvedAt)
        restarted.setEnabled(fixture.id, true)
        XCTAssertEqual(restarted.trustRecord(for: fixture.id)?.health, .healthy)
        XCTAssertTrue(restarted.enabledIDs.contains(fixture.id))
    }

    func testInterruptedReplacementRestoresPreviousPackageAndTrustRecordOnStartup() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = package()
        let replacement = package(version: "1.0.1", css: ".replacement {}")
        let manager = TanManager(root: root)
        try manager.install(original)
        manager.setEnabled(original.id, true)

        let trust = try TanTrustStore(fileURL: root.appendingPathComponent("trust.json"))
        try trust.stageReplacement(replacement, previous: original, at: Date(timeIntervalSince1970: 200))
        let encoder = JSONEncoder()
        try encoder.encode(original).write(to: root.appendingPathComponent("\(original.id).previous.tan.json"), options: [.atomic])
        try encoder.encode(replacement).write(to: root.appendingPathComponent("\(replacement.id).tan.json"), options: [.atomic])

        let restarted = TanManager(root: root)
        XCTAssertEqual(restarted.installed.first?.contentHash, original.contentHash)
        XCTAssertTrue(restarted.enabledIDs.contains(original.id))
        XCTAssertTrue(try XCTUnwrap(restarted.trustRecord(for: original.id)).matches(original))

        let recoveredTrust = try TanTrustStore(fileURL: root.appendingPathComponent("trust.json"))
        XCTAssertNil(recoveredTrust.pendingReplacement(for: original.id))
    }

    func testMalformedTrustStorageForcesSafeModeWithoutActivatingTans() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = package()
        let seed = TanManager(root: root)
        try seed.install(fixture)
        seed.setEnabled(fixture.id, true)
        try Data("{malformed".utf8).write(to: root.appendingPathComponent("trust.json"))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("trust.previous.json"))

        let restored = TanManager(root: root)
        XCTAssertTrue(restored.safeMode)
        XCTAssertTrue(restored.active.isEmpty)
        XCTAssertFalse(restored.enabledIDs.contains(fixture.id))
    }
}
