import Foundation

enum TanHealth: String, Codable, CaseIterable, Equatable {
    case awaitingApproval
    case healthy
    case failed
    case quarantined
}

/// A bounded, user-facing failure classification. Raw helper or JavaScript
/// errors are deliberately never persisted in the trust ledger.
enum TanFailureCategory: String, Codable, CaseIterable, Equatable {
    case startup
    case runtime
    case rejected
    case storageQuota
    case translationQuota
    case helperUnavailable
    case helperDenied
    case unknown

    var displayName: String {
        switch self {
        case .startup: return "Startup failure"
        case .runtime: return "Runtime failure"
        case .rejected: return "Rejected request"
        case .storageQuota: return "Storage limit reached"
        case .translationQuota: return "Translation archive limit reached"
        case .helperUnavailable: return "Helper unavailable"
        case .helperDenied: return "Helper permission denied"
        case .unknown: return "Unclassified failure"
        }
    }

    init(sanitizing raw: String?) {
        let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        switch normalized {
        case "startup", "startup-failure": self = .startup
        case "runtime", "runtime-failure": self = .runtime
        case "rejected", "rejected-request", "bridge-rejected": self = .rejected
        case "storage", "storage-quota", "storage-limit": self = .storageQuota
        case "translation", "translation-quota", "translation-archive-quota": self = .translationQuota
        case "helper-unavailable", "helper-missing": self = .helperUnavailable
        case "helper-denied", "automation-denied": self = .helperDenied
        case "unknown": self = .unknown
        default: self = .unknown
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self.init(sanitizing: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct TanTrustRecord: Codable, Equatable, Identifiable {
    let tanID: String
    let contentHash: String
    let approvedCapabilities: [TanCapability]
    let approvedAt: Date?
    let lastKnownGoodVersion: String?
    let lastKnownGoodHash: String?
    let health: TanHealth
    let failureCount: Int
    let quarantineReason: String?
    /// Optional for records written before C1.3.5. Missing identity metadata
    /// is intentionally treated as untrusted until the package is re-approved.
    let target: TanTarget?
    let trustOrigin: String?
    let enabled: Bool
    let lastFailureCategory: TanFailureCategory?
    let lastFailureAt: Date?

    private enum CodingKeys: String, CodingKey {
        case tanID, contentHash, approvedCapabilities, approvedAt
        case lastKnownGoodVersion, lastKnownGoodHash, health, failureCount
        case quarantineReason, target, trustOrigin, enabled
        case lastFailureCategory, lastFailureAt
    }

    var id: String { tanID }

    init(
        tanID: String,
        contentHash: String,
        approvedCapabilities: [TanCapability] = [],
        approvedAt: Date? = nil,
        lastKnownGoodVersion: String? = nil,
        lastKnownGoodHash: String? = nil,
        health: TanHealth = .awaitingApproval,
        failureCount: Int = 0,
        quarantineReason: String? = nil,
        target: TanTarget? = nil,
        trustOrigin: String? = nil,
        enabled: Bool = false,
        lastFailureCategory: TanFailureCategory? = nil,
        lastFailureAt: Date? = nil
    ) {
        self.tanID = tanID
        self.contentHash = contentHash
        self.approvedCapabilities = approvedCapabilities.sorted { $0.rawValue < $1.rawValue }
        self.approvedAt = approvedAt
        self.lastKnownGoodVersion = lastKnownGoodVersion
        self.lastKnownGoodHash = lastKnownGoodHash
        self.health = health
        self.failureCount = failureCount
        self.quarantineReason = quarantineReason.map { TanFailureCategory(sanitizing: $0).displayName }
        self.target = target
        self.trustOrigin = Self.sanitizeDisplayText(trustOrigin, maximumLength: 200)
        self.enabled = enabled && approvedAt != nil && health == .healthy && target != nil && trustOrigin != nil
        self.lastFailureCategory = lastFailureCategory
        self.lastFailureAt = lastFailureAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tanID = try container.decode(String.self, forKey: .tanID)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        approvedCapabilities = (try? container.decode([TanCapability].self, forKey: .approvedCapabilities)) ?? []
        approvedAt = try? container.decode(Date.self, forKey: .approvedAt)
        lastKnownGoodVersion = try? container.decode(String.self, forKey: .lastKnownGoodVersion)
        lastKnownGoodHash = try? container.decode(String.self, forKey: .lastKnownGoodHash)
        health = (try? container.decode(TanHealth.self, forKey: .health)) ?? .awaitingApproval
        failureCount = (try? container.decode(Int.self, forKey: .failureCount)) ?? 0
        let reason = try? container.decode(String.self, forKey: .quarantineReason)
        quarantineReason = reason.map { TanFailureCategory(sanitizing: $0).displayName }
        target = try? container.decode(TanTarget.self, forKey: .target)
        let origin = try? container.decode(String.self, forKey: .trustOrigin)
        trustOrigin = Self.sanitizeDisplayText(origin, maximumLength: 200)
        let decodedEnabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? false
        let rawCategory = try? container.decode(String.self, forKey: .lastFailureCategory)
        lastFailureCategory = rawCategory.map { TanFailureCategory(sanitizing: $0) }
        lastFailureAt = try? container.decode(Date.self, forKey: .lastFailureAt)
        enabled = decodedEnabled && approvedAt != nil && health == .healthy && target != nil && trustOrigin != nil
    }

    var isApproved: Bool {
        approvedAt != nil && health != .quarantined
    }

    func matches(_ package: TanPackage) -> Bool {
        tanID == package.id
            && contentHash == package.contentHash
            && Set(approvedCapabilities) == Set(package.manifest.capabilities)
            && target == package.manifest.target
            && trustOrigin == package.origin
            && enabled
            && health == .healthy
            && isApproved
    }

    private static func sanitizeDisplayText(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let filtered = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let clean = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return String(clean.prefix(maximumLength))
    }
}

enum TanTrustField: String, CaseIterable, Equatable {
    case contentHash
    case target
    case capabilities
    case trustOrigin

    var title: String {
        switch self {
        case .contentHash: return "Approved code"
        case .target: return "Target"
        case .capabilities: return "Capabilities"
        case .trustOrigin: return "Trust origin"
        }
    }
}

struct TanTrustDiffItem: Identifiable, Equatable {
    let field: TanTrustField
    let previousValue: String
    let currentValue: String
    var id: String { field.rawValue }
}

struct TanTrustDiff: Equatable {
    let items: [TanTrustDiffItem]

    var requiresApproval: Bool { !items.isEmpty }

    static func make(package: TanPackage, record: TanTrustRecord?) -> TanTrustDiff {
        let previousHash = record?.contentHash
        let oldHash = redactedHash(previousHash)
        let newHash = redactedHash(package.contentHash)
        let oldTarget = record?.target?.rawValue ?? "Not recorded"
        let newTarget = package.manifest.target.rawValue
        let oldCapabilities = capabilityText(record?.approvedCapabilities ?? [])
        let newCapabilities = capabilityText(package.manifest.capabilities)
        let oldOrigin = record?.trustOrigin ?? "Not recorded"
        let newOrigin = package.origin
        var items: [TanTrustDiffItem] = []
        if previousHash != package.contentHash { items.append(TanTrustDiffItem(field: .contentHash, previousValue: oldHash, currentValue: newHash)) }
        if oldTarget != newTarget { items.append(TanTrustDiffItem(field: .target, previousValue: oldTarget, currentValue: newTarget)) }
        if oldCapabilities != newCapabilities { items.append(TanTrustDiffItem(field: .capabilities, previousValue: oldCapabilities, currentValue: newCapabilities)) }
        if oldOrigin != newOrigin { items.append(TanTrustDiffItem(field: .trustOrigin, previousValue: oldOrigin, currentValue: newOrigin)) }
        return TanTrustDiff(items: items)
    }

    private static func capabilityText(_ capabilities: [TanCapability]) -> String {
        let values = capabilities.map(\.rawValue).sorted()
        return values.isEmpty ? "None" : values.joined(separator: ", ")
    }

    private static func redactedHash(_ hash: String?) -> String {
        guard let hash, hash.count > 12 else { return hash ?? "Not recorded" }
        return String(hash.prefix(12)) + "…"
    }
}

/// A durable marker written before an installed package is replaced. Keeping
/// the previous record here lets startup recover a package update interrupted
/// between the package-file swap and the trust-ledger commit.
struct TanTrustReplacement: Codable, Equatable {
    let tanID: String
    let previousRecord: TanTrustRecord?
    let previousContentHash: String
    let previousVersion: String
    let replacementContentHash: String
    let replacementVersion: String
    let stagedAt: Date
}
