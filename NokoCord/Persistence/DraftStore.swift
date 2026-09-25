import Foundation

struct Draft: Codable, Equatable, Sendable {
    let text: String
    let replyTo: String?
    let updatedAt: Date

    init(text: String, replyTo: String? = nil, updatedAt: Date = Date()) {
        self.text = text
        self.replyTo = replyTo
        self.updatedAt = updatedAt
    }
}

enum DraftStoreError: Error, Equatable {
    case invalidKey
    case textTooLarge
    case tooManyDrafts
    case aggregateTooLarge
    case invalidDraft
    case corrupted
    case unsupportedVersion
}

actor DraftStore {
    static let shared = DraftStore()
    static let maximumDrafts = 128
    static let maximumTextBytes = 32 * 1024
    static let maximumAggregateBytes = 4 * 1024 * 1024
    static let maximumEncodedBytes = 32 * 1024 * 1024
    static let expiration: TimeInterval = 30 * 24 * 60 * 60

    private struct Envelope: Codable {
        let version: Int
        var drafts: [String: [String: Draft]]
    }

    private let file: URL
    private let now: @Sendable () -> Date

    init(directory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.nokocord.NokoCord", isDirectory: true)
        file = base.appendingPathComponent("drafts-v1.json")
        self.now = now
    }

    func load(accountID: String, conversationID: String) throws -> Draft? {
        try validate(key: accountID)
        try validate(key: conversationID)
        var envelope = try read()
        var changed = purgeExpired(&envelope)
        let draft = envelope.drafts[accountID]?[conversationID]
        if draft == nil, envelope.drafts[accountID]?.isEmpty == true {
            envelope.drafts.removeValue(forKey: accountID)
            changed = true
        }
        if changed { try write(envelope) }
        return draft
    }

    func save(_ draft: Draft, accountID: String, conversationID: String) throws {
        try Task.checkCancellation()
        try validate(key: accountID)
        try validate(key: conversationID)
        try validate(draft)
        var envelope = try read()
        _ = purgeExpired(&envelope)
        var account = envelope.drafts[accountID, default: [:]]
        let isNew = account[conversationID] == nil
        if isNew && draftCount(envelope) >= Self.maximumDrafts { throw DraftStoreError.tooManyDrafts }
        account[conversationID] = draft
        envelope.drafts[accountID] = account
        guard aggregateTextBytes(envelope) <= Self.maximumAggregateBytes else { throw DraftStoreError.aggregateTooLarge }
        try Task.checkCancellation()
        try write(envelope)
    }

    func clear(accountID: String, conversationID: String) throws {
        try Task.checkCancellation()
        try validate(key: accountID)
        try validate(key: conversationID)
        var envelope = try read()
        guard envelope.drafts[accountID]?[conversationID] != nil else { return }
        envelope.drafts[accountID]?.removeValue(forKey: conversationID)
        if envelope.drafts[accountID]?.isEmpty == true { envelope.drafts.removeValue(forKey: accountID) }
        try Task.checkCancellation()
        try write(envelope)
    }

    func clear(accountID: String) throws {
        try Task.checkCancellation()
        try validate(key: accountID)
        var envelope = try read()
        guard envelope.drafts.removeValue(forKey: accountID) != nil else { return }
        try Task.checkCancellation()
        try write(envelope)
    }

    func clearAll() throws {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    private func read() throws -> Envelope {
        guard FileManager.default.fileExists(atPath: file.path) else { return Envelope(version: 1, drafts: [:]) }
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maximumEncodedBytes + 1) ?? Data()
            guard data.count <= Self.maximumEncodedBytes else { throw DraftStoreError.corrupted }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1 else { throw DraftStoreError.unsupportedVersion }
            guard envelope.drafts.count <= Self.maximumDrafts,
                  envelope.drafts.values.reduce(0, { $0 + $1.count }) <= Self.maximumDrafts,
                  aggregateTextBytes(envelope) <= Self.maximumAggregateBytes,
                  envelope.drafts.keys.allSatisfy(Self.validKey),
                  envelope.drafts.values.allSatisfy({ $0.keys.allSatisfy(Self.validKey) && $0.values.allSatisfy(validDraft) }) else {
                throw DraftStoreError.corrupted
            }
            return envelope
        } catch let error as DraftStoreError { throw error }
        catch { throw DraftStoreError.corrupted }
    }

    private func write(_ envelope: Envelope) throws {
        try Task.checkCancellation()
        let data: Data
        do { data = try JSONEncoder().encode(envelope) }
        catch { throw DraftStoreError.corrupted }
        guard data.count <= Self.maximumEncodedBytes else { throw DraftStoreError.aggregateTooLarge }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try Task.checkCancellation()
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var resource = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resource.setResourceValues(values)
    }

    private func purgeExpired(_ envelope: inout Envelope) -> Bool {
        let cutoff = now().addingTimeInterval(-Self.expiration)
        var changed = false
        for accountID in Array(envelope.drafts.keys) {
            guard let account = envelope.drafts[accountID] else { continue }
            let kept = account.filter { $0.value.updatedAt >= cutoff }
            changed = changed || kept.count != account.count
            envelope.drafts[accountID] = kept
            if envelope.drafts[accountID]?.isEmpty == true {
                envelope.drafts.removeValue(forKey: accountID)
                changed = true
            }
        }
        return changed
    }

    private func validate(key: String) throws {
        guard Self.validKey(key) else { throw DraftStoreError.invalidKey }
    }
    private static func validKey(_ key: String) -> Bool { !key.isEmpty && key.utf8.count <= 128 }
    private func validate(_ draft: Draft) throws {
        guard draft.text.utf8.count <= Self.maximumTextBytes else { throw DraftStoreError.textTooLarge }
        guard draft.updatedAt.timeIntervalSince1970.isFinite,
              draft.replyTo.map({ Self.validKey($0) }) ?? true else { throw DraftStoreError.invalidDraft }
    }
    private func validDraft(_ draft: Draft) -> Bool {
        draft.text.utf8.count <= Self.maximumTextBytes &&
        draft.updatedAt.timeIntervalSince1970.isFinite &&
        (draft.replyTo.map(Self.validKey) ?? true)
    }
    private func draftCount(_ envelope: Envelope) -> Int { envelope.drafts.values.reduce(0) { $0 + $1.count } }
    private func aggregateTextBytes(_ envelope: Envelope) -> Int { envelope.drafts.values.flatMap(\.values).reduce(0) { $0 + $1.text.utf8.count } }
}
