import Foundation

enum TanTrustStoreError: LocalizedError, Equatable {
    case malformedStorage
    case unsupportedVersion(Int)
    case invalidStoragePath
    case invalidRecord
    case invalidReplacement
    case missingRecord(String)
    case missingReplacement(String)
    case storageTooLarge
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .malformedStorage: return "Tan trust storage is malformed."
        case .unsupportedVersion(let version): return "Tan trust storage version \(version) is unsupported."
        case .invalidStoragePath: return "Tan trust storage is not a regular private file."
        case .invalidRecord: return "Tan trust storage contains an invalid record."
        case .invalidReplacement: return "Tan trust storage contains an invalid replacement marker."
        case .missingRecord(let id): return "No trust record exists for Tan \(id)."
        case .missingReplacement(let id): return "No staged replacement exists for Tan \(id)."
        case .storageTooLarge: return "Tan trust storage is too large."
        case .writeFailed(let message): return "Tan trust storage could not be saved: \(message)"
        }
    }
}

/// Versioned, private, process-safe storage for Tan consent and recovery state.
///
/// The primary envelope is replaced only after a complete temporary file has
/// been written. Before each replacement the last valid primary envelope is
/// copied to `recoveryURL`, so a damaged or interrupted primary can be
/// restored without guessing at trust state.
final class TanTrustStore: @unchecked Sendable {
    static let currentVersion = 1
    static let maximumRecords = 64
    static let maximumEncodedBytes = 512 * 1024

    private struct Envelope: Codable {
        let version: Int
        let records: [String: TanTrustRecord]
        let pendingReplacements: [String: TanTrustReplacement]
    }

    let fileURL: URL
    let recoveryURL: URL

    private var values: [String: TanTrustRecord]
    private var pending: [String: TanTrustReplacement]

    // TanManager is main-actor isolated, but recovery tests and future
    // maintenance work can legitimately access one store from worker queues.
    // A process-wide lock also protects two store instances targeting the same
    // file from interleaving their read-modify-write cycles.
    private static let processLock = NSLock()

    init(fileURL: URL) throws {
        self.fileURL = fileURL.standardizedFileURL
        self.recoveryURL = Self.recoveryURL(for: fileURL.standardizedFileURL)
        self.values = [:]
        self.pending = [:]

        try withProcessLock {
            try prepareDirectory()
            let envelope = try loadEnvelopeLocked()
            values = envelope.records
            pending = envelope.pendingReplacements
        }
    }

    @discardableResult
    func load() throws -> [TanTrustRecord] {
        try withProcessLock {
            let envelope = try loadEnvelopeLocked()
            values = envelope.records
            pending = envelope.pendingReplacements
            return values.values.sorted { $0.tanID < $1.tanID }
        }
    }

    func recordsSnapshot() -> [String: TanTrustRecord] {
        withProcessLock { values }
    }

    func record(for tanID: String) -> TanTrustRecord? {
        withProcessLock { values[tanID] }
    }

    func pendingReplacement(for tanID: String) -> TanTrustReplacement? {
        withProcessLock { pending[tanID] }
    }

    func pendingReplacementsSnapshot() -> [String: TanTrustReplacement] {
        withProcessLock { pending }
    }

    @discardableResult
    func record(_ package: TanPackage, at date: Date = Date()) throws -> TanTrustRecord {
        try package.validate()
        return try mutate { values, pending in
            if let existing = values[package.id], existing.contentHash == package.contentHash {
                return existing
            }
            let existing = values[package.id]
            let next = TanTrustRecord(
                tanID: package.id,
                contentHash: package.contentHash,
                lastKnownGoodVersion: existing?.lastKnownGoodVersion,
                lastKnownGoodHash: existing?.lastKnownGoodHash,
                health: .awaitingApproval
            )
            values[package.id] = next
            pending.removeValue(forKey: package.id)
            return next
        }
    }

    @discardableResult
    func approve(_ package: TanPackage, at date: Date = Date()) throws -> TanTrustRecord {
        try package.validate()
        return try mutate { values, pending in
            let next = TanTrustRecord(
                tanID: package.id,
                contentHash: package.contentHash,
                approvedCapabilities: package.manifest.capabilities,
                approvedAt: date,
                lastKnownGoodVersion: package.manifest.version,
                lastKnownGoodHash: package.contentHash,
                health: .healthy,
                failureCount: 0
            )
            values[package.id] = next
            pending.removeValue(forKey: package.id)
            return next
        }
    }

    @discardableResult
    func invalidateIfHashChanged(_ package: TanPackage, at date: Date = Date()) throws -> TanTrustRecord {
        try package.validate()
        return try mutate { values, _ in
            if let existing = values[package.id], existing.contentHash == package.contentHash {
                return existing
            }
            let existing = values[package.id]
            let next = TanTrustRecord(
                tanID: package.id,
                contentHash: package.contentHash,
                lastKnownGoodVersion: existing?.lastKnownGoodVersion,
                lastKnownGoodHash: existing?.lastKnownGoodHash,
                health: .awaitingApproval
            )
            values[package.id] = next
            return next
        }
    }

    @discardableResult
    func recordFailure(_ package: TanPackage, reason: String? = nil, at date: Date = Date()) throws -> TanTrustRecord {
        try package.validate()
        return try mutate { values, _ in
            let current = values[package.id].flatMap { $0.contentHash == package.contentHash ? $0 : nil }
                ?? TanTrustRecord(tanID: package.id, contentHash: package.contentHash)
            let count = current.failureCount + 1
            let quarantine = count >= 3
            let next = TanTrustRecord(
                tanID: package.id,
                contentHash: package.contentHash,
                approvedCapabilities: current.approvedCapabilities,
                approvedAt: current.approvedAt,
                lastKnownGoodVersion: current.lastKnownGoodVersion,
                lastKnownGoodHash: current.lastKnownGoodHash,
                health: quarantine ? .quarantined : .failed,
                failureCount: count,
                quarantineReason: quarantine ? sanitizedReason(reason) : nil
            )
            values[package.id] = next
            return next
        }
    }

    @discardableResult
    func quarantine(_ tanID: String, reason: String, at date: Date = Date()) throws -> TanTrustRecord {
        try mutate { values, _ in
            guard let current = values[tanID] else { throw TanTrustStoreError.missingRecord(tanID) }
            let next = TanTrustRecord(
                tanID: current.tanID,
                contentHash: current.contentHash,
                approvedCapabilities: current.approvedCapabilities,
                approvedAt: current.approvedAt,
                lastKnownGoodVersion: current.lastKnownGoodVersion,
                lastKnownGoodHash: current.lastKnownGoodHash,
                health: .quarantined,
                failureCount: current.failureCount,
                quarantineReason: sanitizedReason(reason) ?? "Tan was quarantined."
            )
            values[tanID] = next
            return next
        }
    }

    @discardableResult
    func recover(_ package: TanPackage, at date: Date = Date()) throws -> TanTrustRecord {
        try package.validate()
        return try mutate { values, pending in
            let current = values[package.id]
            let next = TanTrustRecord(
                tanID: package.id,
                contentHash: package.contentHash,
                lastKnownGoodVersion: current?.lastKnownGoodVersion,
                lastKnownGoodHash: current?.lastKnownGoodHash,
                health: .awaitingApproval
            )
            values[package.id] = next
            pending.removeValue(forKey: package.id)
            return next
        }
    }

    func stageReplacement(_ replacement: TanPackage, previous: TanPackage, at date: Date = Date()) throws {
        try replacement.validate()
        try previous.validate()
        guard replacement.id == previous.id else { throw TanTrustStoreError.invalidReplacement }

        try mutate { values, pending in
            pending[replacement.id] = TanTrustReplacement(
                tanID: replacement.id,
                previousRecord: values[replacement.id],
                previousContentHash: previous.contentHash,
                previousVersion: previous.manifest.version,
                replacementContentHash: replacement.contentHash,
                replacementVersion: replacement.manifest.version,
                stagedAt: date
            )
        }
    }

    @discardableResult
    func commitReplacement(_ replacement: TanPackage, previous: TanPackage, at date: Date = Date()) throws -> TanTrustRecord {
        try replacement.validate()
        try previous.validate()
        guard replacement.id == previous.id else { throw TanTrustStoreError.invalidReplacement }

        return try mutate { values, pending in
            guard let marker = pending[replacement.id],
                  marker.previousContentHash == previous.contentHash,
                  marker.replacementContentHash == replacement.contentHash else {
                throw TanTrustStoreError.missingReplacement(replacement.id)
            }
            let previousRecord = marker.previousRecord
            let next = TanTrustRecord(
                tanID: replacement.id,
                contentHash: replacement.contentHash,
                lastKnownGoodVersion: previousRecord?.lastKnownGoodVersion ?? previous.manifest.version,
                lastKnownGoodHash: previousRecord?.lastKnownGoodHash ?? previous.contentHash,
                health: .awaitingApproval
            )
            values[replacement.id] = next
            pending.removeValue(forKey: replacement.id)
            return next
        }
    }

    @discardableResult
    func restorePrevious(_ tanID: String, at date: Date = Date()) throws -> TanTrustRecord {
        try mutate { values, pending in
            guard let marker = pending[tanID] else { throw TanTrustStoreError.missingReplacement(tanID) }
            let restored = marker.previousRecord ?? TanTrustRecord(
                tanID: tanID,
                contentHash: marker.previousContentHash,
                lastKnownGoodVersion: marker.previousVersion,
                lastKnownGoodHash: marker.previousContentHash,
                health: .awaitingApproval
            )
            values[tanID] = restored
            pending.removeValue(forKey: tanID)
            return restored
        }
    }

    private func mutate<T>(_ body: (inout [String: TanTrustRecord], inout [String: TanTrustReplacement]) throws -> T) throws -> T {
        try withProcessLock {
            let envelope = try loadEnvelopeLocked()
            var nextValues = envelope.records
            var nextPending = envelope.pendingReplacements
            let result = try body(&nextValues, &nextPending)
            try persistLocked(records: nextValues, pending: nextPending)
            values = nextValues
            pending = nextPending
            return result
        }
    }

    private func withProcessLock<T>(_ body: () throws -> T) rethrows -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        return try body()
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw TanTrustStoreError.invalidStoragePath }
        } catch let error as TanTrustStoreError {
            throw error
        } catch {
            throw TanTrustStoreError.writeFailed(error.localizedDescription)
        }
    }

    private func loadEnvelopeLocked() throws -> Envelope {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                return try readEnvelope(from: fileURL)
            } catch let error as TanTrustStoreError where error == .invalidStoragePath {
                throw error
            } catch {
                guard FileManager.default.fileExists(atPath: recoveryURL.path) else {
                    throw error is TanTrustStoreError ? error : TanTrustStoreError.malformedStorage
                }
                do {
                    let recovered = try readEnvelope(from: recoveryURL)
                    if let data = try? Data(contentsOf: recoveryURL) {
                        try? writeFileAtomically(data, to: fileURL)
                    }
                    return recovered
                } catch {
                    throw TanTrustStoreError.malformedStorage
                }
            }
        }

        guard FileManager.default.fileExists(atPath: recoveryURL.path) else {
            return Envelope(version: Self.currentVersion, records: [:], pendingReplacements: [:])
        }
        let recovered = try readEnvelope(from: recoveryURL)
        if let data = try? Data(contentsOf: recoveryURL) {
            try? writeFileAtomically(data, to: fileURL)
        }
        return recovered
    }

    private func readEnvelope(from url: URL) throws -> Envelope {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw TanTrustStoreError.invalidStoragePath }
            guard (values.fileSize ?? Int.max) <= Self.maximumEncodedBytes else { throw TanTrustStoreError.storageTooLarge }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(Envelope.self, from: data)
            try validate(envelope)
            return envelope
        } catch let error as TanTrustStoreError {
            throw error
        } catch {
            throw TanTrustStoreError.malformedStorage
        }
    }

    private func validate(_ envelope: Envelope) throws {
        guard envelope.version == Self.currentVersion else { throw TanTrustStoreError.unsupportedVersion(envelope.version) }
        guard envelope.records.count <= Self.maximumRecords,
              envelope.pendingReplacements.count <= Self.maximumRecords else {
            throw TanTrustStoreError.storageTooLarge
        }
        for (id, record) in envelope.records {
            guard id == record.tanID,
                  id.range(of: "^[a-z0-9][a-z0-9.-]{2,79}$", options: .regularExpression) != nil,
                  Self.isHash(record.contentHash),
                  Set(record.approvedCapabilities).count == record.approvedCapabilities.count,
                  record.failureCount >= 0,
                  record.quarantineReason?.count ?? 0 <= 512 else {
                throw TanTrustStoreError.invalidRecord
            }
            if record.health == .quarantined && record.quarantineReason?.isEmpty != false {
                throw TanTrustStoreError.invalidRecord
            }
        }
        for (id, marker) in envelope.pendingReplacements {
            guard id == marker.tanID,
                  Self.isHash(marker.previousContentHash),
                  Self.isHash(marker.replacementContentHash),
                  marker.previousRecord?.tanID == nil || marker.previousRecord?.tanID == id else {
                throw TanTrustStoreError.invalidReplacement
            }
        }
    }

    private func persistLocked(records: [String: TanTrustRecord], pending: [String: TanTrustReplacement]) throws {
        try prepareDirectory()
        let envelope = Envelope(version: Self.currentVersion, records: records, pendingReplacements: pending)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw TanTrustStoreError.writeFailed(error.localizedDescription)
        }
        guard data.count <= Self.maximumEncodedBytes else { throw TanTrustStoreError.storageTooLarge }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let current = try Data(contentsOf: fileURL)
                try writeFileAtomically(current, to: recoveryURL)
            } catch let error as TanTrustStoreError {
                throw error
            } catch {
                throw TanTrustStoreError.writeFailed(error.localizedDescription)
            }
        }
        try writeFileAtomically(data, to: fileURL)
    }

    private func writeFileAtomically(_ data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        try prepareDirectory()
        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw TanTrustStoreError.invalidStoragePath }
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch let error as TanTrustStoreError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw TanTrustStoreError.writeFailed(error.localizedDescription)
        }
    }

    private static func recoveryURL(for fileURL: URL) -> URL {
        let base = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension
        let name = ext.isEmpty ? "\(base).previous" : "\(base).previous.\(ext)"
        return fileURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    private static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private func sanitizedReason(_ reason: String?) -> String? {
        guard let reason else { return nil }
        let clean = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return String(clean.prefix(512))
    }
}
