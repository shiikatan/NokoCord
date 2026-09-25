import Foundation
import Observation

protocol DraftPersisting: Sendable {
    func load(accountID: String, conversationID: String) async throws -> Draft?
    func save(_ draft: Draft, accountID: String, conversationID: String) async throws
    func clear(accountID: String, conversationID: String) async throws
}
extension DraftStore: DraftPersisting {}

/// A single account/conversation's editable draft. Identity never changes while
/// asynchronous restoration or persistence is in flight.
@MainActor @Observable
final class ConversationDraft {
    let accountID: String
    let conversationID: String
    private(set) var text = ""
    private(set) var replyTo: String?
    private(set) var persistenceError: String?
    @ObservationIgnored private let storage: any DraftPersisting
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var writeGeneration = 0

    init(accountID: String, conversationID: String, storage: any DraftPersisting = DraftStore.shared) {
        self.accountID = accountID; self.conversationID = conversationID; self.storage = storage
    }

    func restore() async {
        if let restoreTask { await restoreTask.value; return }
        guard revision == 0 else { return }
        let expected = revision
        let storage = storage, accountID = accountID, conversationID = conversationID
        let task = Task { [weak self] in
            do {
                let saved = try await storage.load(accountID: accountID, conversationID: conversationID)
                guard let self, self.revision == expected, !Task.isCancelled else { return }
                self.text = saved?.text ?? ""; self.replyTo = saved?.replyTo
                self.persistenceError = nil
            } catch {
                guard let self, self.revision == expected, !Task.isCancelled else { return }
                self.persistenceError = String(localized: "The saved draft could not be restored.")
            }
        }
        restoreTask = task
        await task.value
    }

    func update(text: String, replyTo: String? = nil) {
        guard text != self.text || replyTo != self.replyTo else { return }
        self.text = text; self.replyTo = replyTo
        revision += 1
        scheduleWrite(debounce: true)
    }

    /// Await the latest persistence attempt; failures remain in persistenceError.
    func flush() async {
        await restore()
        guard revision > 0 else { return }
        scheduleWrite(debounce: false)
        while let task = writeTask {
            let generation = writeGeneration
            await task.value
            if generation == writeGeneration { return }
        }
    }

    private func scheduleWrite(debounce: Bool) {
        writeGeneration += 1
        let previous = writeTask
        previous?.cancel()
        let expected = revision
        let draft = Draft(text: text, replyTo: replyTo)
        let storage = storage, accountID = accountID, conversationID = conversationID
        writeTask = Task { [weak self] in
            // A storage implementation may ignore cancellation. Await it so an
            // older write can never overwrite a newer saved draft.
            await previous?.value
            do {
                if debounce { try await Task.sleep(for: .milliseconds(300)) }
                try Task.checkCancellation()
                if draft.text.isEmpty && draft.replyTo == nil {
                    try await storage.clear(accountID: accountID, conversationID: conversationID)
                } else {
                    try await storage.save(draft, accountID: accountID, conversationID: conversationID)
                }
                guard !Task.isCancelled, let self, self.revision == expected else { return }
                self.persistenceError = nil
            } catch {
                guard !Task.isCancelled, let self, self.revision == expected else { return }
                self.persistenceError = String(localized: "The draft could not be saved. Your text is still available in this window.")
            }
        }
    }
}
