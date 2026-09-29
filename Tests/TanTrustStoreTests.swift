import Foundation
import XCTest
@testable import NokoCordCore

final class TanTrustStoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NokoCord-TanTrustTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func package(id: String = "fixture.trusted", version: String = "1.0.0", css: String = ".fixture {}") -> TanPackage {
        let manifest = TanManifest(
            schemaVersion: 1,
            id: id,
            name: "Fixture Trusted Tan",
            version: version,
            description: "A trust-store fixture.",
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

    private func fileURL(in root: URL) -> URL {
        root.appendingPathComponent("trust.json")
    }

    func testApprovalIsBoundToContentHashAndCapabilities() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = package()
        let changed = package(version: "1.0.1", css: ".changed {}")
        let store = try TanTrustStore(fileURL: fileURL(in: root))

        try store.approve(original, at: Date(timeIntervalSince1970: 100))
        let approved = try XCTUnwrap(store.record(for: original.id))
        XCTAssertEqual(approved.contentHash, original.contentHash)
        XCTAssertEqual(approved.approvedCapabilities, original.manifest.capabilities)
        XCTAssertNotNil(approved.approvedAt)
        XCTAssertTrue(approved.matches(original))

        let invalidated = try store.invalidateIfHashChanged(changed, at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(invalidated.contentHash, changed.contentHash)
        XCTAssertNil(invalidated.approvedAt)
        XCTAssertTrue(invalidated.approvedCapabilities.isEmpty)
        XCTAssertEqual(invalidated.health, .awaitingApproval)
        XCTAssertFalse(invalidated.matches(changed))
        XCTAssertEqual(invalidated.lastKnownGoodVersion, original.manifest.version)
    }

    func testMalformedPrimaryStorageRecoversFromPreviousValidSnapshot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = package()
        let changed = package(version: "1.0.1", css: ".changed {}")
        let primaryURL = fileURL(in: root)
        let store = try TanTrustStore(fileURL: primaryURL)
        try store.approve(original, at: Date(timeIntervalSince1970: 100))
        try store.approve(changed, at: Date(timeIntervalSince1970: 200))
        let previousSnapshot = try Data(contentsOf: store.recoveryURL)

        try Data("{malformed".utf8).write(to: primaryURL)

        let recovered = try TanTrustStore(fileURL: primaryURL)
        XCTAssertEqual(try XCTUnwrap(recovered.record(for: original.id)).contentHash, original.contentHash)
        XCTAssertEqual(try Data(contentsOf: primaryURL), previousSnapshot)
    }

    func testMalformedStorageWithoutRecoverySnapshotIsRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let primaryURL = fileURL(in: root)
        try Data("{malformed".utf8).write(to: primaryURL)

        XCTAssertThrowsError(try TanTrustStore(fileURL: primaryURL))
    }

    func testAtomicReplacementKeepsPreviousValidEnvelopeAndLeavesNoTemporaryFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = package()
        let changed = package(version: "1.0.1", css: ".changed {}")
        let primaryURL = fileURL(in: root)
        let store = try TanTrustStore(fileURL: primaryURL)

        try store.approve(original, at: Date(timeIntervalSince1970: 100))
        let originalEnvelope = try Data(contentsOf: primaryURL)
        try store.approve(changed, at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(try Data(contentsOf: store.recoveryURL), originalEnvelope)
        XCTAssertEqual(try XCTUnwrap(store.record(for: changed.id)).contentHash, changed.contentHash)
        let leftovers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testStagedReplacementCanCommitOrRestorePreviousTrust() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = package()
        let changed = package(version: "1.0.1", css: ".changed {}")
        let store = try TanTrustStore(fileURL: fileURL(in: root))
        try store.approve(original, at: Date(timeIntervalSince1970: 100))

        try store.stageReplacement(changed, previous: original, at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.pendingReplacement(for: original.id)?.replacementContentHash, changed.contentHash)
        try store.restorePrevious(original.id, at: Date(timeIntervalSince1970: 201))
        XCTAssertNil(store.pendingReplacement(for: original.id))
        XCTAssertTrue(try XCTUnwrap(store.record(for: original.id)).matches(original))

        try store.stageReplacement(changed, previous: original, at: Date(timeIntervalSince1970: 300))
        try store.commitReplacement(changed, previous: original, at: Date(timeIntervalSince1970: 301))
        let committed = try XCTUnwrap(store.record(for: changed.id))
        XCTAssertEqual(committed.contentHash, changed.contentHash)
        XCTAssertEqual(committed.health, .awaitingApproval)
        XCTAssertNil(committed.approvedAt)
        XCTAssertEqual(committed.lastKnownGoodVersion, original.manifest.version)
        XCTAssertNil(store.pendingReplacement(for: changed.id))
    }

    func testRepeatedFailuresPersistQuarantineAndExplicitRecoveryClearsConsent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = package()
        let store = try TanTrustStore(fileURL: fileURL(in: root))
        try store.approve(original, at: Date(timeIntervalSince1970: 100))

        for index in 1...3 {
            let record = try store.recordFailure(original, reason: "startup failure", at: Date(timeIntervalSince1970: Double(100 + index)))
            XCTAssertEqual(record.failureCount, index)
        }

        let quarantined = try XCTUnwrap(store.record(for: original.id))
        XCTAssertEqual(quarantined.health, .quarantined)
        XCTAssertEqual(quarantined.quarantineReason, "startup failure")
        XCTAssertFalse(quarantined.matches(original))

        let restarted = try TanTrustStore(fileURL: fileURL(in: root))
        XCTAssertEqual(try XCTUnwrap(restarted.record(for: original.id)).health, .quarantined)
        let recovered = try restarted.recover(original, at: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(recovered.health, .awaitingApproval)
        XCTAssertNil(recovered.approvedAt)
        XCTAssertEqual(recovered.failureCount, 0)
        XCTAssertNil(recovered.quarantineReason)
    }

    func testConcurrentApprovalsNeverProduceMalformedStorage() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let primaryURL = fileURL(in: root)
        let store = try TanTrustStore(fileURL: primaryURL)
        let packages = (0..<32).map { index in
            package(version: "1.0.\(index)", css: ".fixture-\(index) {}")
        }
        let errorLock = NSLock()
        var errors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: packages.count) { index in
            do {
                try store.approve(packages[index], at: Date(timeIntervalSince1970: Double(index)))
            } catch {
                errorLock.lock()
                errors.append(error)
                errorLock.unlock()
            }
        }

        XCTAssertTrue(errors.isEmpty, "Concurrent trust updates failed: \(errors)")
        let reopened = try TanTrustStore(fileURL: primaryURL)
        let record = try XCTUnwrap(reopened.record(for: packages[0].id))
        XCTAssertTrue(packages.contains { $0.contentHash == record.contentHash })
    }
}
