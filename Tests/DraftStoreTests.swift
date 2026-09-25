import Foundation
import XCTest
@testable import NokoCordCore

final class DraftStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> (DraftStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NokoCord-Drafts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clock = now
        return (DraftStore(directory: directory, now: { clock }), directory)
    }

    private func draft(_ text: String = "hello", updatedAt: Date? = nil) -> Draft {
        Draft(text: text, replyTo: "message-1", updatedAt: updatedAt ?? now)
    }

    func testRoundTripAndReplyMetadata() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = draft()

        try await store.save(expected, accountID: "account-1", conversationID: "conversation-1")

        let loaded = try await store.load(accountID: "account-1", conversationID: "conversation-1")
        XCTAssertEqual(loaded, expected)
    }

    func testAccountAndConversationIsolation() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(draft("one"), accountID: "account-1", conversationID: "conversation-1")
        try await store.save(draft("two"), accountID: "account-2", conversationID: "conversation-1")

        let first = try await store.load(accountID: "account-1", conversationID: "conversation-1")
        let missing = try await store.load(accountID: "account-1", conversationID: "conversation-2")
        let second = try await store.load(accountID: "account-2", conversationID: "conversation-1")
        XCTAssertEqual(first?.text, "one")
        XCTAssertNil(missing)
        XCTAssertEqual(second?.text, "two")
    }

    func testInvalidKeysAreRejected() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        for key in ["", String(repeating: "x", count: 129)] {
            do { try await store.save(draft(), accountID: key, conversationID: "conversation"); XCTFail("Expected invalid key") }
            catch { XCTAssertEqual(error as? DraftStoreError, .invalidKey) }
        }
    }

    func testReplyToAndTimestampAreValidated() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidReply = Draft(text: "hello", replyTo: String(repeating: "x", count: 129), updatedAt: now)
        do { try await store.save(invalidReply, accountID: "account", conversationID: "conversation"); XCTFail("Expected invalid draft") }
        catch { XCTAssertEqual(error as? DraftStoreError, .invalidDraft) }
        let invalidDate = Draft(text: "hello", updatedAt: Date(timeIntervalSince1970: .infinity))
        do { try await store.save(invalidDate, accountID: "account", conversationID: "conversation"); XCTFail("Expected invalid draft") }
        catch { XCTAssertEqual(error as? DraftStoreError, .invalidDraft) }
    }

    func testTextAndDraftCountBounds() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        do { try await store.save(draft(String(repeating: "x", count: 32 * 1024 + 1)), accountID: "account", conversationID: "conversation"); XCTFail("Expected text bound") }
        catch { XCTAssertEqual(error as? DraftStoreError, .textTooLarge) }
        for index in 0..<128 {
            try await store.save(draft("draft-\(index)"), accountID: "account", conversationID: "conversation-\(index)")
        }
        do { try await store.save(draft(), accountID: "account", conversationID: "conversation-129"); XCTFail("Expected draft count bound") }
        catch { XCTAssertEqual(error as? DraftStoreError, .tooManyDrafts) }
    }

    func testClearConversationAccountAndAll() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(draft("one"), accountID: "account-1", conversationID: "conversation-1")
        try await store.save(draft("two"), accountID: "account-1", conversationID: "conversation-2")
        try await store.save(draft("three"), accountID: "account-2", conversationID: "conversation-1")

        try await store.clear(accountID: "account-1", conversationID: "conversation-1")
        let deletedConversation = try await store.load(accountID: "account-1", conversationID: "conversation-1")
        let remainingConversation = try await store.load(accountID: "account-1", conversationID: "conversation-2")
        XCTAssertNil(deletedConversation)
        XCTAssertNotNil(remainingConversation)
        try await store.clear(accountID: "account-1")
        let deletedAccount = try await store.load(accountID: "account-1", conversationID: "conversation-2")
        let remainingAccount = try await store.load(accountID: "account-2", conversationID: "conversation-1")
        XCTAssertNil(deletedAccount)
        XCTAssertNotNil(remainingAccount)
        try await store.clearAll()
        let deletedAll = try await store.load(accountID: "account-2", conversationID: "conversation-1")
        XCTAssertNil(deletedAll)
    }

    func testCorruptedStoreThrowsTypedError() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("drafts-v1.json"))

        do { _ = try await store.load(accountID: "account", conversationID: "conversation"); XCTFail("Expected corruption") }
        catch { XCTAssertEqual(error as? DraftStoreError, .corrupted) }
    }

    func testOversizedStoreIsRejectedBeforeFullRead() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oversized = Data(repeating: 0x20, count: DraftStore.maximumEncodedBytes + 1)
        try oversized.write(to: directory.appendingPathComponent("drafts-v1.json"))

        do { _ = try await store.load(accountID: "account", conversationID: "conversation"); XCTFail("Expected oversized store") }
        catch { XCTAssertEqual(error as? DraftStoreError, .corrupted) }
    }

    func testStoreAndDirectoryPermissionsArePrivate() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(draft(), accountID: "account", conversationID: "conversation")
        let file = directory.appendingPathComponent("drafts-v1.json")
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testExpiredDraftIsPurgedUsingInjectedClock() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(draft("old", updatedAt: now.addingTimeInterval(-30 * 24 * 60 * 60 - 1)), accountID: "account", conversationID: "conversation")

        let loaded = try await store.load(accountID: "account", conversationID: "conversation")
        XCTAssertNil(loaded)
    }

    func testCancelledSaveDoesNotCreateStore() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task {
            try Task.checkCancellation()
            try await store.save(draft(), accountID: "account", conversationID: "conversation")
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("drafts-v1.json").path))
    }
}
