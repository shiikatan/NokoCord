import Foundation

enum TanHealth: String, Codable, CaseIterable, Equatable {
    case awaitingApproval
    case healthy
    case failed
    case quarantined
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
        quarantineReason: String? = nil
    ) {
        self.tanID = tanID
        self.contentHash = contentHash
        self.approvedCapabilities = approvedCapabilities.sorted { $0.rawValue < $1.rawValue }
        self.approvedAt = approvedAt
        self.lastKnownGoodVersion = lastKnownGoodVersion
        self.lastKnownGoodHash = lastKnownGoodHash
        self.health = health
        self.failureCount = failureCount
        self.quarantineReason = quarantineReason
    }

    var isApproved: Bool {
        approvedAt != nil && health != .quarantined
    }

    func matches(_ package: TanPackage) -> Bool {
        tanID == package.id
            && contentHash == package.contentHash
            && Set(approvedCapabilities) == Set(package.manifest.capabilities)
            && isApproved
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
