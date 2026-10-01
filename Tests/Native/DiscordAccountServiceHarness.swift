import Foundation

// Compiled with the production account service, but without a real SDK or
// Keychain. All token values here are synthetic and never printed.
enum NokoDiscordSocialClientStatus: Int {
    case disconnected = 0, connecting, connected, ready, reconnecting, disconnecting, httpWait
}

struct NokoDiscordOperationResult {
    let isSuccessful: Bool
    let invalidGrant: Bool
    let isRetryable: Bool
}

struct NokoDiscordTokenResult {
    let isSuccessful: Bool
    let invalidGrant: Bool
    let wasCancelled: Bool
    let isRetryable: Bool
    let expiresIn: TimeInterval
    let accessToken: String?
    let refreshToken: String?

    static let canceled = Self(isSuccessful: false, invalidGrant: false,
                               wasCancelled: true, isRetryable: false,
                               expiresIn: 0, accessToken: nil, refreshToken: nil)
    static let lateSuccess = Self(isSuccessful: true, invalidGrant: false,
                                  wasCancelled: false, isRetryable: false,
                                  expiresIn: 3600, accessToken: "synthetic-access",
                                  refreshToken: "synthetic-refresh")
}

struct DiscordSocialCredentials: Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

protocol DiscordSocialCredentialStoring: Sendable {
    func load() async throws -> DiscordSocialCredentials?
    func save(_ credentials: DiscordSocialCredentials) async throws
    func remove() async throws
}

actor KeychainDiscordSocialCredentialStore: DiscordSocialCredentialStoring {
    private var value: DiscordSocialCredentials?
    init() {}
    func load() async throws -> DiscordSocialCredentials? { value }
    func save(_ credentials: DiscordSocialCredentials) async throws { value = credentials }
    func remove() async throws { value = nil }
}

final class DiscordSocialPublicationGate {
    func beginConnecting(sessionGeneration: UInt64) {}
    func useDesktopRPC(sessionGeneration: UInt64) {}
    func markReady(sessionGeneration: UInt64) -> Bool { true }
    func waitForPublicationsToDrain() async {}
    func accountClearWasIssued() {}
}

@MainActor
final class NokoDiscordSocialClient {
    var statusChangedHandler: ((Int, Int, Int) -> Void)?
    var tokenExpirationHandler: (() -> Void)?
    var authorizeCallbacks: [(NokoDiscordTokenResult) -> Void] = []
    var revokeCallbacks: [(NokoDiscordOperationResult) -> Void] = []
    var status = NokoDiscordSocialClientStatus.disconnected.rawValue

    var authorizeCount: Int { authorizeCallbacks.count }
    func authorize(completion: @escaping (NokoDiscordTokenResult) -> Void) {
        authorizeCallbacks.append(completion)
    }
    func abortAuthorization() {}
    func refreshToken(_ token: String, completion: @escaping (NokoDiscordTokenResult) -> Void) {
        completion(.canceled)
    }
    func updateToken(_ token: String, completion: @escaping (NokoDiscordOperationResult) -> Void) {
        completion(.init(isSuccessful: true, invalidGrant: false, isRetryable: false))
    }
    func connect() {
        status = NokoDiscordSocialClientStatus.ready.rawValue
        statusChangedHandler?(status, 0, 0)
    }
    func disconnect() {
        status = NokoDiscordSocialClientStatus.disconnected.rawValue
        statusChangedHandler?(status, 0, 0)
    }
    func connectionStatus() -> Int { status }
    func refreshConnectionStatus(completion: (Int) -> Void) { completion(status) }
    func revokeToken(_ token: String, completion: @escaping (NokoDiscordOperationResult) -> Void) {
        revokeCallbacks.append(completion)
    }
    func clearRichPresence(completion: (NokoDiscordOperationResult) -> Void) {
        completion(.init(isSuccessful: true, invalidGrant: false, isRetryable: false))
    }
    func finishRevoke(at index: Int = 0) {
        revokeCallbacks[index](.init(isSuccessful: true, invalidGrant: false, isRetryable: false))
    }
}

@MainActor
@main
struct DiscordAccountServiceHarness {
    static func main() async throws {
        try await revokeTimeoutKeepsConnectQuarantined()
        try await cancelledAuthorizationKeepsConnectQuarantined()
        print("Native account race harness passed")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        if !condition() { throw NSError(domain: "NativeAuthHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: description]) }
    }

    private static func pause() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private static func revokeTimeoutKeepsConnectQuarantined() async throws {
        let client = NokoDiscordSocialClient()
        let store = KeychainDiscordSocialCredentialStore()
        try await store.save(.init(accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
                                   expiresAt: Date().addingTimeInterval(7200)))
        let service = DiscordSocialAccountService(client: client,
            publicationGate: DiscordSocialPublicationGate(), credentialStore: store)
        var pumpDemand = false
        service.onCallbackPumpDemandChanged = { pumpDemand = $0 }
        await service.start()
        try await pause()
        try check(service.state == .ready, "saved session should reach Ready")
        await service.disconnect() // SDK revoke callback is deliberately withheld past 3 seconds.
        try check(service.state == .authorizationRequired, "local logout should complete")
        try check(service.authorizationIsQuarantined, "pending server revoke must quarantine Connect")
        await service.authorize()
        try check(client.authorizeCount == 0, "new grant must not precede old revoke callback")
        try check(pumpDemand, "callback pump must remain active after local revoke timeout")
        client.finishRevoke()
        try await pause()
        try check(!service.authorizationIsQuarantined, "completed revoke should release quarantine")
        let attempt = Task { await service.authorize() }
        try await pause()
        try check(client.authorizeCount == 1, "Connect should resume after revoke callback")
        client.authorizeCallbacks[0](.canceled)
        await attempt.value
    }

    private static func cancelledAuthorizationKeepsConnectQuarantined() async throws {
        let client = NokoDiscordSocialClient()
        let service = DiscordSocialAccountService(client: client,
            publicationGate: DiscordSocialPublicationGate(),
            credentialStore: KeychainDiscordSocialCredentialStore())
        await service.start()
        let attempt = Task { await service.authorize() }
        try await pause()
        try check(client.authorizeCount == 1, "first OAuth attempt must begin")
        await service.disconnect()
        await attempt.value
        try check(service.authorizationIsQuarantined, "canceled OAuth callback must remain quarantined")
        await service.authorize()
        try check(client.authorizeCount == 1, "new OAuth must wait for canceled callback")
        try await Task.sleep(nanoseconds: 60_200_000_000)
        try check(service.authorizationIsQuarantined, "OAuth must remain quarantined after the warning deadline")
        try check(service.warning?.contains("Restart NokoCord") == true,
                  "a stalled canceled OAuth attempt needs visible restart guidance")
        await service.authorize()
        try check(client.authorizeCount == 1, "OAuth must still be blocked after the warning deadline")
        client.authorizeCallbacks[0](.lateSuccess)
        try await Task.sleep(nanoseconds: 3_200_000_000)
        try check(service.authorizationIsQuarantined, "timed out cleanup revoke must still block Connect")
        await service.authorize()
        try check(client.authorizeCount == 1, "late revoke must not race newer OAuth")
        client.finishRevoke()
        try await pause()
        try check(!service.authorizationIsQuarantined, "cleanup completion should release quarantine")
    }
}
