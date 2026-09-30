import Foundation
import Security

struct DiscordSocialCredentials: Codable, Equatable, Sendable, CustomStringConvertible {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    var description: String { "DiscordSocialCredentials(<redacted>)" }
}

protocol DiscordSocialCredentialStoring: Sendable {
    func load() async throws -> DiscordSocialCredentials?
    func save(_ credentials: DiscordSocialCredentials) async throws
    func remove() async throws
}

enum DiscordSocialCredentialStoreError: Error, Equatable {
    case keychainStatus(Int32)
    case invalidCredentialData
}

/// Keeps OAuth access and refresh tokens in one Keychain item so refresh-token
/// rotation can replace the saved pair atomically. On macOS, the login Keychain
/// applies its native default accessibility policy; iOS-only accessibility
/// attributes are not valid for a traditional macOS Keychain item.
actor KeychainDiscordSocialCredentialStore: DiscordSocialCredentialStoring {
    static let productionService = "com.shiikatan.nokocord.maomao.discord-social-sdk"

    private let service: String
    private let account: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        service: String = KeychainDiscordSocialCredentialStore.productionService,
        account: String = "authorization"
    ) {
        self.service = service
        self.account = account
    }

    func load() async throws -> DiscordSocialCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw DiscordSocialCredentialStoreError.keychainStatus(status)
        }
        guard let data = result as? Data else {
            throw DiscordSocialCredentialStoreError.invalidCredentialData
        }
        do {
            return try decoder.decode(DiscordSocialCredentials.self, from: data)
        } catch {
            throw DiscordSocialCredentialStoreError.invalidCredentialData
        }
    }

    func save(_ credentials: DiscordSocialCredentials) async throws {
        let data = try encoder.encode(credentials)
        let update = [kSecValueData as String: data] as CFDictionary
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update)

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw DiscordSocialCredentialStoreError.keychainStatus(updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw DiscordSocialCredentialStoreError.keychainStatus(addStatus)
        }
    }

    func remove() async throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DiscordSocialCredentialStoreError.keychainStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum DiscordSocialPublicationMode: Equatable, Sendable {
    /// The SDK is not authenticated, so its supported desktop RPC fallback may be used.
    case desktopRPC
    /// Token update or gateway connection is in progress; do not race local RPC updates.
    case connecting
    /// The SDK is ready and activity updates use the authenticated connection.
    case authenticated
}

final class DiscordSocialPublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var mode: DiscordSocialPublicationMode = .desktopRPC
    private var sessionGeneration: UInt64 = 0
    private var activePublications = 0
    private var publicationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var deferredClearPending = false
    private var deferredClearInProgress = false

    func beginConnecting(sessionGeneration: UInt64) {
        lock.lock()
        guard sessionGeneration >= self.sessionGeneration else {
            lock.unlock()
            return
        }
        self.sessionGeneration = sessionGeneration
        mode = .connecting
        lock.unlock()
    }

    @discardableResult
    func markReady(sessionGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.sessionGeneration == sessionGeneration else { return false }
        mode = .authenticated
        return true
    }

    func useDesktopRPC(sessionGeneration: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard sessionGeneration >= self.sessionGeneration else { return }
        self.sessionGeneration = sessionGeneration
        mode = .desktopRPC
    }

    func currentMode() -> DiscordSocialPublicationMode {
        lock.lock()
        defer { lock.unlock() }
        return mode
    }

    /// Reserves an activity operation before it is placed on the SDK queue.
    /// Closing the gate prevents later work and lets disconnect wait until all
    /// already-reserved work has reached that serial queue.
    func beginPublication() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard mode != .connecting, !deferredClearPending else { return false }
        activePublications += 1
        return true
    }

    /// A provider may stop while the SDK is reconnecting. Remember that clear
    /// so Ready/fallback can send it before activity publication resumes.
    func deferClearIfBlocked() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard mode == .connecting || deferredClearPending else { return false }
        deferredClearPending = true
        return true
    }

    func beginDeferredClear() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard mode != .connecting, deferredClearPending, !deferredClearInProgress else { return false }
        deferredClearInProgress = true
        activePublications += 1
        return true
    }

    func finishDeferredClear(succeeded: Bool) {
        lock.lock()
        if succeeded { deferredClearPending = false }
        deferredClearInProgress = false
        activePublications = max(0, activePublications - 1)
        let waiters = activePublications == 0 ? publicationDrainWaiters : []
        if activePublications == 0 { publicationDrainWaiters.removeAll() }
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    /// An account-level clear is serialized after all leases and also satisfies
    /// any provider clear that was deferred while the gate was closed.
    func accountClearWasIssued() {
        lock.lock()
        deferredClearPending = false
        deferredClearInProgress = false
        lock.unlock()
    }

    func endPublication() {
        lock.lock()
        activePublications = max(0, activePublications - 1)
        let waiters = activePublications == 0 ? publicationDrainWaiters : []
        if activePublications == 0 { publicationDrainWaiters.removeAll() }
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func waitForPublicationsToDrain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if activePublications == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                publicationDrainWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
