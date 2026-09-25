import Foundation
import XCTest
@testable import NokoCordCore

private enum ConversationDraftStorageError: Error {
    case loadFailed
    case saveFailed
}

private actor ControlledDraftStorage: DraftPersisting {
    private struct SaveRecord {
        let draft: Draft
        let accountID: String
        let conversationID: String
    }
    private var loadContinuation: CheckedContinuation<Draft?, Error>?
    private var loadWaiter: CheckedContinuation<Void, Never>?
    private var loadStarted = false
    private var loadCalls = 0
    private var loadIsDelayed: Bool
    private let initialDraft: Draft?
    private let failLoad: Bool
    private let blockedSaveCount: Int
    private let failSave: Bool
    private var saveContinuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var saves: [SaveRecord] = []
    private var completedSaves: [SaveRecord] = []
    private var clearCalls = 0
    private var saveWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(initialDraft: Draft? = nil, delayedLoad: Bool = false, failLoad: Bool = false,
         blockedSaveCount: Int = 0, failSave: Bool = false) {
        self.initialDraft = initialDraft
        self.loadIsDelayed = delayedLoad
        self.failLoad = failLoad
        self.blockedSaveCount = blockedSaveCount
        self.failSave = failSave
    }

    func load(accountID: String, conversationID: String) async throws -> Draft? {
        loadCalls += 1
        loadStarted = true
        loadWaiter?.resume()
        loadWaiter = nil
        if loadIsDelayed {
            return try await withCheckedThrowingContinuation { continuation in
                loadContinuation = continuation
            }
        }
        if failLoad { throw ConversationDraftStorageError.loadFailed }
        return initialDraft
    }

    func waitForLoad() async {
        guard !loadStarted else { return }
        await withCheckedContinuation { loadWaiter = $0 }
    }

    func finishLoad() {
        guard let loadContinuation else { return }
        self.loadContinuation = nil
        if failLoad { loadContinuation.resume(throwing: ConversationDraftStorageError.loadFailed) }
        else { loadContinuation.resume(returning: initialDraft) }
    }

    func save(_ draft: Draft, accountID: String, conversationID: String) async throws {
        saves.append(SaveRecord(draft: draft, accountID: accountID, conversationID: conversationID))
        let number = saves.count
        let ready = saveWaiters.filter { $0.target <= number }
        saveWaiters.removeAll { $0.target <= number }
        ready.forEach { $0.continuation.resume() }
        if number <= blockedSaveCount {
            try await withCheckedThrowingContinuation { saveContinuations[number] = $0 }
        }
        if failSave { throw ConversationDraftStorageError.saveFailed }
        completedSaves.append(saves[number - 1])
    }

    func clear(accountID: String, conversationID: String) async throws {
        clearCalls += 1
    }

    func waitForSave(_ target: Int) async {
        guard saves.count < target else { return }
        await withCheckedContinuation { saveWaiters.append((target: target, continuation: $0)) }
    }

    func finishSave(_ number: Int) {
        saveContinuations.removeValue(forKey: number)?.resume()
    }

    func completedDrafts() -> [Draft] { completedSaves.map(\.draft) }
    func completedKeys() -> [(String, String)] { completedSaves.map { ($0.accountID, $0.conversationID) } }
    func clearCount() -> Int { clearCalls }
    func loadCount() -> Int { loadCalls }
}

private actor CompletionProbe {
    private var completed = false

    func markCompleted() { completed = true }
    func value() -> Bool { completed }
}

@MainActor
final class ConversationDraftTests: XCTestCase {
    private let accountID = "test-account"
    private let conversationID = "test-conversation"

    private func makeDraft(_ text: String, replyTo: String? = nil) -> Draft {
        Draft(text: text, replyTo: replyTo, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testDelayedRestoreDoesNotOverwriteEdit() async {
        let storage = ControlledDraftStorage(initialDraft: makeDraft("saved"), delayedLoad: true)
        let draft = ConversationDraft(accountID: accountID, conversationID: conversationID, storage: storage)
        let restore = Task { await draft.restore() }
        await storage.waitForLoad()

        draft.update(text: "local edit", replyTo: "reply")
        await storage.finishLoad()
        await restore.value
        await draft.flush()

        XCTAssertEqual(draft.text, "local edit")
        XCTAssertEqual(draft.replyTo, "reply")
    }

    func testUpdateBeforeFirstRestoreIsPreserved() async {
        let storage = ControlledDraftStorage(initialDraft: makeDraft("saved"), delayedLoad: true)
        let draft = ConversationDraft(accountID: accountID, conversationID: conversationID, storage: storage)
        draft.update(text: "local edit", replyTo: "reply")

        await draft.restore()
        await draft.flush()

        let loads = await storage.loadCount()
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(draft.text, "local edit")
        XCTAssertEqual(draft.replyTo, "reply")
    }

    func testFlushAwaitsRestoreWithoutClearingExistingDraft() async {
        let storage = ControlledDraftStorage(initialDraft: makeDraft("saved"), delayedLoad: true)
        let draft = ConversationDraft(accountID: accountID, conversationID: conversationID, storage: storage)
        let flush = Task { await draft.flush() }
        await storage.waitForLoad()
        await storage.finishLoad()
        await flush.value

        let saves = await storage.completedDrafts()
        let clears = await storage.clearCount()
        XCTAssertEqual(draft.text, "saved")
        XCTAssertTrue(saves.isEmpty)
        XCTAssertEqual(clears, 0)
    }

    func testFlushAfterFailedRestoreDoesNotWriteOrClear() async {
        let storage = ControlledDraftStorage(delayedLoad: true, failLoad: true)
        let draft = ConversationDraft(accountID: accountID, conversationID: conversationID, storage: storage)
        let flush = Task { await draft.flush() }
        await storage.waitForLoad()
        await storage.finishLoad()
        await flush.value

        let saves = await storage.completedDrafts()
        let clears = await storage.clearCount()
        XCTAssertNotNil(draft.persistenceError)
        XCTAssertTrue(saves.isEmpty)
        XCTAssertEqual(clears, 0)
    }

    func testWritesSerializeWhenOlderSaveIgnoresCancellation() async {
        let storage = ControlledDraftStorage(blockedSaveCount: 2)
        let draft = ConversationDraft(accountID: accountID, conversationID: conversationID, storage: storage)
        let completion = CompletionProbe()
        draft.update(text: "older")
        let firstFlush = Task {
            await draft.flush()
            await completion.markCompleted()
        }
        await storage.waitForSave(1)

        draft.update(text: "newer")
        await storage.finishSave(1)
        await storage.waitForSave(2)
        let completedBeforeReplacement = await completion.value()
        let draftsBeforeReplacement = await storage.completedDrafts()
        XCTAssertFalse(completedBeforeReplacement)
        XCTAssertEqual(draftsBeforeReplacement.map(\.text), ["older"])
        await storage.finishSave(2)
        await firstFlush.value
        await draft.flush()

        let saves = await storage.completedDrafts()
        let keys = await storage.completedKeys()
        XCTAssertEqual(saves.map(\.text), ["older", "newer", "newer"])
        XCTAssertEqual(keys.count, 3)
        XCTAssertTrue(keys.allSatisfy { $0.0 == accountID && $0.1 == conversationID })
        XCTAssertEqual(draft.text, "newer")
    }

    func testSaveFailureKeepsTextAndReportsError() async {
        let storage = ControlledDraftStorage(failSave: true)
        let draft = ConversationDraft(accountID: accountID, conversationID: conversationID, storage: storage)
        draft.update(text: "keep this")
        await draft.flush()

        XCTAssertEqual(draft.text, "keep this")
        XCTAssertNotNil(draft.persistenceError)
    }

    func testEmptyDraftClearsPersistedConversation() async {
        let storage = ControlledDraftStorage()
        let draft = ConversationDraft(accountID: accountID, conversationID: conversationID, storage: storage)
        draft.update(text: "saved")
        await draft.flush()
        draft.update(text: "")
        await draft.flush()

        let clears = await storage.clearCount()
        XCTAssertEqual(clears, 1)
        XCTAssertEqual(draft.text, "")
    }
}
