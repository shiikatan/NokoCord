import Foundation
import Observation
import CoreFoundation

enum DiscordSocialAccountState: Equatable {
    case signedOut
    case authorizing
    case connecting
    case ready
    case reconnecting
    case authorizationRequired
    case failed(String)
}

/// Completes a callback continuation at most once. The timeout can finish a
/// best-effort operation while a late SDK callback safely becomes a no-op.
private final class DiscordSocialContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func complete(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

private enum DiscordSocialAuthorizationOutcome {
    case completed(NokoDiscordTokenResult)
    case cancelled
}

private final class DiscordSocialAuthorizationAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DiscordSocialAuthorizationOutcome, Never>?
    private var completed = false

    func install(_ continuation: CheckedContinuation<DiscordSocialAuthorizationOutcome, Never>) {
        lock.lock()
        let wasCompleted = completed
        if !wasCompleted { self.continuation = continuation }
        lock.unlock()
        if wasCompleted { continuation.resume(returning: .cancelled) }
    }

    @discardableResult
    func complete(_ result: NokoDiscordTokenResult) -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: .completed(result))
        return true
    }

    func cancel() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: .cancelled)
    }
}

/// A non-secret persisted marker prevents a failed Keychain deletion during
/// logout from silently restoring the old authorization on the next launch.
private enum DiscordSocialLogoutBarrier {
    private static let key = "discordSocialLogoutPending"

    static var isRaised: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    @discardableResult
    static func raise() -> Bool {
        UserDefaults.standard.set(true, forKey: key)
        return CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    @discardableResult
    static func clear() -> Bool {
        UserDefaults.standard.removeObject(forKey: key)
        return CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }
}

/// Owns the Social SDK account lifecycle. Activity providers continue to
/// publish only through NokoActivityBridge; this service controls authentication
/// and selects when the generic transport may use the connected SDK.
@MainActor
@Observable
final class DiscordSocialAccountService {
    private(set) var state: DiscordSocialAccountState = .signedOut
    private(set) var warning: String?
    private(set) var authorizationIsQuarantined = false

    @ObservationIgnored private let client: NokoDiscordSocialClient
    @ObservationIgnored private let credentialStore: any DiscordSocialCredentialStoring
    @ObservationIgnored private let publicationGate: DiscordSocialPublicationGate
    @ObservationIgnored private let isConfigured: Bool
    @ObservationIgnored private var credentials: DiscordSocialCredentials?
    @ObservationIgnored private var currentStatus: Int = NokoDiscordSocialClientStatus.disconnected.rawValue
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var userRequestedDisconnect = false
    @ObservationIgnored private var shuttingDown = false
    @ObservationIgnored private var disconnectInProgress = false
    @ObservationIgnored private var disconnectCleanupComplete = false
    @ObservationIgnored private var pendingFallbackState: DiscordSocialAccountState?
    @ObservationIgnored private var retryAfterDisconnect = false
    @ObservationIgnored private var sessionHasAcceptedToken = false
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var expirationTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshOperationID: UUID?
    @ObservationIgnored private var installOperationID: UUID?
    @ObservationIgnored private var pendingInstall: (DiscordSocialCredentials, UInt64)?
    @ObservationIgnored private var authorizationInProgress = false
    @ObservationIgnored private var authorizationOperationID: UUID?
    @ObservationIgnored private var authorizationAttempt: DiscordSocialAuthorizationAttempt?
    @ObservationIgnored private var pendingAuthorizationCallbacks: Set<UUID> = []
    @ObservationIgnored private var authorizationCallbackExpiryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lateCallbackCleanupCount = 0
    @ObservationIgnored private var pendingRevocationCallbacks: Set<UUID> = []
    @ObservationIgnored private var shutdownDisconnectInProgress = false
    @ObservationIgnored private var sessionGeneration: UInt64 = 0
    @ObservationIgnored private var statusEventGeneration: UInt64 = 0
    @ObservationIgnored private var callbackPumpDemand = false
    @ObservationIgnored var onCallbackPumpDemandChanged: ((Bool) -> Void)?
    @ObservationIgnored var onReady: (() -> Void)?
    @ObservationIgnored var onDesktopRPCFallback: (() -> Void)?

    private static let readyStatus = NokoDiscordSocialClientStatus.ready.rawValue
    private static let disconnectedStatus = NokoDiscordSocialClientStatus.disconnected.rawValue
    private static let connectingStatuses: Set<Int> = [
        NokoDiscordSocialClientStatus.connecting.rawValue,
        NokoDiscordSocialClientStatus.connected.rawValue,
        NokoDiscordSocialClientStatus.reconnecting.rawValue,
        NokoDiscordSocialClientStatus.disconnecting.rawValue,
        NokoDiscordSocialClientStatus.httpWait.rawValue
    ]
    private static let proactiveRefreshWindow: TimeInterval = 60 * 60

    init(
        client: NokoDiscordSocialClient,
        publicationGate: DiscordSocialPublicationGate,
        credentialStore: any DiscordSocialCredentialStoring = KeychainDiscordSocialCredentialStore(),
        isConfigured: Bool = true
    ) {
        self.client = client
        self.publicationGate = publicationGate
        self.credentialStore = credentialStore
        self.isConfigured = isConfigured

        client.statusChangedHandler = { [weak self] status, error, errorDetail in
            Task { @MainActor [weak self] in
                await self?.statusChanged(status: status, error: error, errorDetail: errorDetail)
            }
        }
        client.tokenExpirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.tokenDidExpire()
            }
        }
    }

    var requiresAuthorization: Bool {
        state == .signedOut || state == .authorizationRequired
    }

    /// Restores a saved Keychain session and starts the Social SDK connection.
    /// With no saved authorization, the existing desktop RPC route stays active.
    func start() async {
        guard !didStart else { return }
        didStart = true
        guard isConfigured else {
            state = .failed("This build has no Discord application configured. Set NOKO_DISCORD_APPLICATION_ID when building NokoCord.")
            return
        }
        let requestGeneration = sessionGeneration
        if DiscordSocialLogoutBarrier.isRaised {
            do {
                try await credentialStore.remove()
                _ = DiscordSocialLogoutBarrier.clear()
                guard isCurrent(requestGeneration) else { return }
                state = .authorizationRequired
            } catch {
                guard isCurrent(requestGeneration) else { return }
                warning = "A previous Discord logout could not clear Keychain. NokoCord will not restore that session; connect again to replace it."
                state = .failed("Discord logout cleanup is still pending.")
            }
            updateCallbackPumpDemand()
            return
        }
        do {
            guard let saved = try await credentialStore.load() else {
                guard requestGeneration == sessionGeneration, !shuttingDown else { return }
                state = .authorizationRequired
                return
            }
            guard isCurrent(requestGeneration) else { return }
            credentials = saved
            sessionHasAcceptedToken = false
            if saved.expiresAt.timeIntervalSinceNow <= Self.proactiveRefreshWindow {
                await refreshCredentials()
            } else {
                await install(saved, sessionGeneration: requestGeneration)
            }
        } catch {
            guard isCurrent(requestGeneration) else { return }
            state = .failed("NokoCord could not read the Discord authorization from Keychain.")
        }
        updateCallbackPumpDemand()
    }

    /// Starts Discord's documented public-client authorization flow. The SDK
    /// creates and verifies OAuth state and the PKCE challenge.
    func authorize() async {
        guard isConfigured, (requiresAuthorization || isRetryableFailure),
              !authorizationInProgress,
              refreshOperationID == nil,
              installOperationID == nil,
              pendingAuthorizationCallbacks.isEmpty,
              lateCallbackCleanupCount == 0,
              pendingRevocationCallbacks.isEmpty,
              !disconnectInProgress,
              !shuttingDown else { return }

        authorizationInProgress = true
        let operationID = UUID()
        let attempt = DiscordSocialAuthorizationAttempt()
        authorizationOperationID = operationID
        authorizationAttempt = attempt
        pendingAuthorizationCallbacks.insert(operationID)
        let requestGeneration = sessionGeneration
        defer {
            if authorizationOperationID == operationID {
                authorizationOperationID = nil
                authorizationAttempt = nil
                authorizationInProgress = false
            }
            updateCallbackPumpDemand()
        }

        userRequestedDisconnect = false
        warning = nil
        retryTask?.cancel()
        retryTask = nil
        sessionHasAcceptedToken = false
        publicationGate.beginConnecting(sessionGeneration: requestGeneration)
        updateCallbackPumpDemand()
        state = .authorizing

        let outcome = await withCheckedContinuation { continuation in
            attempt.install(continuation)
            client.authorize { [weak self] result in
                Task { @MainActor [weak self] in
                    let accepted = attempt.complete(result)
                    await self?.authorizationCallbackDidArrive(
                        operationID,
                        result: result,
                        wasAccepted: accepted
                    )
                }
            }
        }
        guard case .completed(let tokenResult) = outcome else { return }

        guard isCurrent(requestGeneration), !userRequestedDisconnect else {
            if tokenResult.isSuccessful,
               shuttingDown, !userRequestedDisconnect,
               let access = tokenResult.accessToken,
               let refresh = tokenResult.refreshToken {
                let authorized = DiscordSocialCredentials(
                    accessToken: access,
                    refreshToken: refresh,
                    expiresAt: Date().addingTimeInterval(tokenResult.expiresIn)
                )
                do {
                    try await credentialStore.save(authorized)
                    _ = DiscordSocialLogoutBarrier.clear()
                } catch {
                    _ = await revoke(refreshToken: refresh)
                }
            } else if tokenResult.isSuccessful, let refresh = tokenResult.refreshToken {
                _ = await revoke(refreshToken: refresh)
            }
            return
        }

        guard tokenResult.isSuccessful,
              let access = tokenResult.accessToken,
              let refresh = tokenResult.refreshToken else {
            state = tokenResult.wasCancelled
                ? .authorizationRequired
                : .failed("Discord authorization did not complete. You can try again.")
            return
        }

        let authorized = DiscordSocialCredentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(tokenResult.expiresIn)
        )
        do {
            try await credentialStore.save(authorized)
        } catch {
            _ = await revoke(refreshToken: refresh)
            guard isCurrent(requestGeneration), !userRequestedDisconnect else { return }
            state = .failed("NokoCord could not save Discord authorization in Keychain.")
            return
        }

        guard isCurrent(requestGeneration), !userRequestedDisconnect else {
            // Remove after a stale save as well: logout may have reached
            // Keychain first while the OAuth save was still queued.
            try? await credentialStore.remove()
            _ = await revoke(refreshToken: refresh)
            return
        }

        credentials = authorized
        _ = DiscordSocialLogoutBarrier.clear()
        await install(authorized, sessionGeneration: requestGeneration)
    }

    /// Removes local credentials and revokes the public-client grant
    /// best-effort. Logout completes locally even if Discord never answers a
    /// revoke or disconnect callback.
    func disconnect() async {
        guard isConfigured else { return }
        sessionGeneration &+= 1
        let logoutGeneration = sessionGeneration
        userRequestedDisconnect = true
        disconnectInProgress = true
        disconnectCleanupComplete = false
        pendingFallbackState = .authorizationRequired
        retryAfterDisconnect = false
        retryTask?.cancel()
        retryTask = nil
        expirationTask?.cancel()
        expirationTask = nil
        warning = nil
        let logoutBarrierPersisted = DiscordSocialLogoutBarrier.raise()

        publicationGate.beginConnecting(sessionGeneration: sessionGeneration)
        updateCallbackPumpDemand()
        client.abortAuthorization()
        if let cancelledOperation = authorizationOperationID {
            scheduleAuthorizationCallbackExpiry(cancelledOperation)
        }
        authorizationAttempt?.cancel()
        authorizationAttempt = nil
        authorizationOperationID = nil
        authorizationInProgress = false
        updateCallbackPumpDemand()
        await clearRichPresence()

        let refreshToken = credentials?.refreshToken
        if let refreshToken, !(await revoke(refreshToken: refreshToken)) {
            warning = pendingRevocationCallbacks.isEmpty
                ? "Discord did not confirm revocation. NokoCord removed the local authorization."
                : "Discord has not finished revocation. Connect will be available after its callback; restart NokoCord if it does not finish."
        }

        var removalSucceeded = true
        do {
            try await credentialStore.remove()
            _ = DiscordSocialLogoutBarrier.clear()
        } catch {
            removalSucceeded = false
            warning = "NokoCord could not remove the saved Discord authorization from Keychain."
            if !logoutBarrierPersisted {
                warning = "NokoCord could not remove the saved Discord authorization from Keychain or persist the logout block. Retry logout before closing the app."
            }
        }
        guard logoutGeneration == sessionGeneration else { return }

        credentials = nil
        sessionHasAcceptedToken = false
        pendingFallbackState = removalSucceeded
            ? .authorizationRequired
            : .failed("Discord logout cleanup is still pending.")
        disconnectCleanupComplete = true
        client.disconnect()
        if await waitForDisconnected() {
            await finishPendingDisconnect()
        } else {
            warning = removalSucceeded
                ? "Discord is still disconnecting. Local authorization was removed; desktop RPC will resume after disconnect completes."
                : "Discord is still disconnecting. Keychain cleanup is pending and automatic session restore is blocked."
            updateCallbackPumpDemand()
        }
    }

    /// Stops the connection when NokoCord exits while retaining Keychain
    /// credentials for the next launch. It does not revoke the user's grant.
    func shutdown() async {
        guard isConfigured else { return }
        shuttingDown = true
        shutdownDisconnectInProgress = true
        sessionGeneration &+= 1
        let shutdownGeneration = sessionGeneration
        retryTask?.cancel()
        retryTask = nil
        expirationTask?.cancel()
        expirationTask = nil
        publicationGate.beginConnecting(sessionGeneration: shutdownGeneration)
        updateCallbackPumpDemand()
        client.abortAuthorization()
        await waitForRefreshDuringShutdown()
        await publicationGate.waitForPublicationsToDrain()
        client.disconnect()
        if await waitForDisconnected(timeout: 2.0) {
            publicationGate.useDesktopRPC(sessionGeneration: shutdownGeneration)
        }
        shutdownDisconnectInProgress = false
        updateCallbackPumpDemand()
    }

    private var isRetryableFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == sessionGeneration && !shuttingDown
    }

    /// Only one UpdateToken request may be in flight. If a refresh rotates the
    /// credentials during an install, the newest pair is installed next.
    private func install(_ value: DiscordSocialCredentials, sessionGeneration generation: UInt64) async {
        guard isCurrent(generation), !userRequestedDisconnect, !disconnectInProgress else { return }
        if installOperationID != nil {
            pendingInstall = (value, generation)
            return
        }

        let operationID = UUID()
        installOperationID = operationID
        let hadAuthenticatedConnection = currentStatus == Self.readyStatus && sessionHasAcceptedToken
        credentials = value
        state = currentStatus == Self.readyStatus ? .reconnecting : .connecting
        publicationGate.beginConnecting(sessionGeneration: generation)
        updateCallbackPumpDemand()

        let result = await withCheckedContinuation { continuation in
            client.updateToken(value.accessToken) { result in continuation.resume(returning: result) }
        }

        guard installOperationID == operationID else { return }
        guard isCurrent(generation), !userRequestedDisconnect, !disconnectInProgress else {
            finishInstall(operationID)
            return
        }

        if result.isSuccessful {
            sessionHasAcceptedToken = true
            if client.connectionStatus() == Self.readyStatus {
                currentStatus = Self.readyStatus
                markReady()
            } else {
                state = .connecting
                client.connect()
            }
            finishInstall(operationID)
            return
        }

        if result.invalidGrant {
            finishInstall(operationID)
            await requireAuthorization(sessionGeneration: generation)
            return
        }

        let failure = "Discord did not accept the saved authorization."
        warning = result.isRetryable ? "Discord is temporarily unavailable. NokoCord will retry." : nil
        if result.isRetryable, hadAuthenticatedConnection,
           client.connectionStatus() == Self.readyStatus {
            sessionHasAcceptedToken = true
            currentStatus = Self.readyStatus
            markReady()
            finishInstall(operationID)
            scheduleReconnect()
            return
        }

        finishInstall(operationID)
        await disconnectToFallback(
            state: .failed(result.isRetryable ? "Discord authorization is temporarily unavailable. NokoCord will retry." : failure),
            sessionGeneration: generation,
            retryAfterDisconnect: result.isRetryable
        )
    }

    private func finishInstall(_ operationID: UUID) {
        guard installOperationID == operationID else { return }
        installOperationID = nil
        let pending = pendingInstall
        pendingInstall = nil
        updateCallbackPumpDemand()
        if let (value, generation) = pending,
           isCurrent(generation), !userRequestedDisconnect, !disconnectInProgress {
            Task { @MainActor [weak self] in
                await self?.install(value, sessionGeneration: generation)
            }
        }
    }

    /// RefreshToken rotates the refresh token, so all callers share one SDK
    /// request. Logout invalidates its generation without waiting for network
    /// completion; any late rotated token is revoked and never persisted.
    private func refreshCredentials() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        guard !userRequestedDisconnect, !shuttingDown, !disconnectInProgress else { return }
        guard let current = credentials else {
            await requireAuthorization(sessionGeneration: sessionGeneration)
            return
        }

        let operationID = UUID()
        let generation = sessionGeneration
        refreshOperationID = operationID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh(current, generation: generation, operationID: operationID)
        }
        refreshTask = task
        updateCallbackPumpDemand()
        await task.value
    }

    private func performRefresh(
        _ current: DiscordSocialCredentials,
        generation: UInt64,
        operationID: UUID
    ) async {
        defer {
            if refreshOperationID == operationID {
                refreshOperationID = nil
                refreshTask = nil
                updateCallbackPumpDemand()
            }
        }

        guard isCurrent(generation), !userRequestedDisconnect else { return }
        let wasAuthenticated = currentStatus == Self.readyStatus && sessionHasAcceptedToken
        state = currentStatus == Self.readyStatus ? .reconnecting : .connecting
        publicationGate.beginConnecting(sessionGeneration: generation)
        updateCallbackPumpDemand()

        let result = await withCheckedContinuation { continuation in
            client.refreshToken(current.refreshToken) { result in continuation.resume(returning: result) }
        }

        guard isCurrent(generation), !userRequestedDisconnect, !disconnectInProgress else {
            if result.isSuccessful, let refresh = result.refreshToken {
                if shuttingDown, !userRequestedDisconnect {
                    let rotated = DiscordSocialCredentials(
                        accessToken: result.accessToken ?? "",
                        refreshToken: refresh,
                        expiresAt: Date().addingTimeInterval(result.expiresIn)
                    )
                    if !rotated.accessToken.isEmpty {
                        try? await credentialStore.save(rotated)
                    }
                } else {
                    try? await credentialStore.remove()
                    _ = await revoke(refreshToken: refresh)
                }
            }
            return
        }

        guard result.isSuccessful,
              let access = result.accessToken,
              let refresh = result.refreshToken else {
            if result.invalidGrant {
                await requireAuthorization(sessionGeneration: generation)
                return
            }

            warning = "Discord authorization could not be refreshed. NokoCord will retry."
            if wasAuthenticated, client.connectionStatus() == Self.readyStatus {
                sessionHasAcceptedToken = true
                currentStatus = Self.readyStatus
                markReady()
            } else {
                await disconnectToFallback(
                    state: .failed("Discord authorization could not be refreshed."),
                    sessionGeneration: generation,
                    retryAfterDisconnect: result.isRetryable
                )
            }
            if result.isRetryable, wasAuthenticated { scheduleReconnect() }
            return
        }

        let rotated = DiscordSocialCredentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(result.expiresIn)
        )
        credentials = rotated
        do {
            try await credentialStore.save(rotated)
            warning = nil
        } catch {
            // Refresh tokens are single use. Keep the rotated pair in memory so
            // this session can continue and tell the user to reauthorize if the
            // app restarts before Keychain is available again.
            warning = "Discord is connected, but refreshed credentials could not be saved. Reauthorize before quitting NokoCord."
        }

        guard isCurrent(generation), !userRequestedDisconnect, !disconnectInProgress else {
            if shuttingDown, !userRequestedDisconnect {
                return
            }
            credentials = nil
            try? await credentialStore.remove()
            _ = await revoke(refreshToken: refresh)
            return
        }
        await install(rotated, sessionGeneration: generation)
    }

    private func tokenDidExpire() {
        guard expirationTask == nil, credentials != nil,
              !userRequestedDisconnect, !shuttingDown, !disconnectInProgress else { return }
        expirationTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshCredentials()
            self.expirationTask = nil
            self.updateCallbackPumpDemand()
        }
    }

    private func authorizationCallbackDidArrive(
        _ operationID: UUID,
        result: NokoDiscordTokenResult,
        wasAccepted: Bool
    ) async {
        pendingAuthorizationCallbacks.remove(operationID)
        authorizationCallbackExpiryTasks.removeValue(forKey: operationID)?.cancel()
        if authorizationOperationID == operationID {
            authorizationAttempt = nil
        }

        if !wasAccepted, !result.isSuccessful,
           warning == "Discord authorization cancellation is taking longer than expected. Restart NokoCord to retry Connect." {
            warning = nil
        }

        if !wasAccepted, result.isSuccessful,
           let refreshToken = result.refreshToken ?? result.accessToken {
            lateCallbackCleanupCount += 1
            updateCallbackPumpDemand()
            await invalidateAfterLateAuthorization(refreshToken: refreshToken)
            lateCallbackCleanupCount = max(0, lateCallbackCleanupCount - 1)
        }
        updateCallbackPumpDemand()
    }

    private func scheduleAuthorizationCallbackExpiry(_ operationID: UUID) {
        authorizationCallbackExpiryTasks[operationID]?.cancel()
        authorizationCallbackExpiryTasks[operationID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                return
            }
            guard let self, self.pendingAuthorizationCallbacks.contains(operationID) else { return }
            self.authorizationCallbackExpiryTasks[operationID] = nil
            // AbortAuthorize does not guarantee a callback. Keep this attempt
            // quarantined: a later success would revoke every grant for this
            // app and user, including one issued by a newer Connect attempt.
            self.warning = "Discord authorization cancellation is taking longer than expected. Restart NokoCord to retry Connect."
            self.updateCallbackPumpDemand()
        }
    }

    /// Token revocation invalidates this app's Discord grant, so a late OAuth
    /// success must first invalidate any newer in-flight or saved session.
    /// That way revoking the late result cannot silently revoke a fresh login.
    private func invalidateAfterLateAuthorization(refreshToken: String) async {
        if userRequestedDisconnect && disconnectInProgress {
            if !(await revoke(refreshToken: refreshToken)) {
                warning = "Discord did not confirm revocation of an authorization that completed after logout."
            }
            return
        }

        sessionGeneration &+= 1
        let generation = sessionGeneration
        userRequestedDisconnect = true
        disconnectInProgress = true
        disconnectCleanupComplete = false
        pendingFallbackState = .authorizationRequired
        retryAfterDisconnect = false
        retryTask?.cancel()
        retryTask = nil
        expirationTask?.cancel()
        expirationTask = nil

        if let activeOperation = authorizationOperationID {
            scheduleAuthorizationCallbackExpiry(activeOperation)
            authorizationAttempt?.cancel()
            authorizationAttempt = nil
            authorizationOperationID = nil
            authorizationInProgress = false
        }
        DiscordSocialLogoutBarrier.raise()
        publicationGate.beginConnecting(sessionGeneration: generation)
        updateCallbackPumpDemand()
        await clearRichPresence()
        let didRevoke = await revoke(refreshToken: refreshToken)

        var removalSucceeded = true
        do {
            try await credentialStore.remove()
            _ = DiscordSocialLogoutBarrier.clear()
        } catch {
            removalSucceeded = false
            warning = "A canceled Discord authorization completed late. Its grant was revoked, but Keychain cleanup is still pending."
        }
        guard generation == sessionGeneration else { return }
        credentials = nil
        sessionHasAcceptedToken = false
        pendingFallbackState = removalSucceeded
            ? .authorizationRequired
            : .failed("Discord authorization cleanup is still pending.")
        if !didRevoke {
            warning = "A canceled Discord authorization completed late and Discord did not confirm revocation. Connect again to replace the grant."
        } else if removalSucceeded {
            warning = "Discord completed an authorization after it was canceled. NokoCord revoked it; connect again to continue."
        }
        disconnectCleanupComplete = true
        client.disconnect()
        if await waitForDisconnected() {
            await finishPendingDisconnect()
        } else {
            warning = "A canceled Discord authorization completed late. NokoCord is waiting for the Social SDK to disconnect."
            updateCallbackPumpDemand()
        }
    }

    private func statusChanged(status: Int, error: Int, errorDetail: Int) async {
        statusEventGeneration &+= 1
        let eventGeneration = statusEventGeneration
        currentStatus = status
        guard client.connectionStatus() == status else {
            currentStatus = client.connectionStatus()
            updateCallbackPumpDemand()
            return
        }

        if status == Self.readyStatus {
            // The shutdown path owns the final disconnect. Avoid racing it
            // with a second call from a late Ready callback.
            guard !shuttingDown else { return }
            guard !userRequestedDisconnect, !disconnectInProgress,
                  credentials != nil else {
                publicationGate.beginConnecting(sessionGeneration: sessionGeneration)
                guard !userRequestedDisconnect, !disconnectInProgress else {
                    updateCallbackPumpDemand()
                    return
                }
                let generation = sessionGeneration
                await publicationGate.waitForPublicationsToDrain()
                guard isCurrent(generation) else { return }
                client.disconnect()
                updateCallbackPumpDemand()
                return
            }
            guard sessionHasAcceptedToken, installOperationID == nil else {
                publicationGate.beginConnecting(sessionGeneration: sessionGeneration)
                state = .connecting
                updateCallbackPumpDemand()
                return
            }
            markReady(expectedEvent: eventGeneration)
            return
        }

        if Self.connectingStatuses.contains(status) {
            if shuttingDown || userRequestedDisconnect || disconnectInProgress {
                publicationGate.beginConnecting(sessionGeneration: sessionGeneration)
                updateCallbackPumpDemand()
                return
            }
            publicationGate.beginConnecting(sessionGeneration: sessionGeneration)
            guard eventGeneration == statusEventGeneration else { return }
            state = status == NokoDiscordSocialClientStatus.reconnecting.rawValue
                ? .reconnecting
                : .connecting
            updateCallbackPumpDemand()
            return
        }

        guard status == Self.disconnectedStatus else { return }
        if disconnectInProgress {
            await finishPendingDisconnect()
            return
        }
        if shuttingDown {
            publicationGate.useDesktopRPC(sessionGeneration: sessionGeneration)
            updateCallbackPumpDemand()
            return
        }
        if credentials == nil {
            publicationGate.useDesktopRPC(sessionGeneration: sessionGeneration)
            guard eventGeneration == statusEventGeneration else { return }
            state = .authorizationRequired
            updateCallbackPumpDemand()
            onDesktopRPCFallback?()
            return
        }

        publicationGate.beginConnecting(sessionGeneration: sessionGeneration)
        guard eventGeneration == statusEventGeneration else { return }
        state = .reconnecting
        updateCallbackPumpDemand()
        if error != 0 || errorDetail != 0 || credentials != nil {
            scheduleReconnect()
        }
    }

    private func markReady(expectedEvent: UInt64? = nil) {
        let generation = sessionGeneration
        guard client.connectionStatus() == Self.readyStatus,
              expectedEvent == nil || expectedEvent == statusEventGeneration,
              sessionHasAcceptedToken,
              credentials != nil,
              !userRequestedDisconnect,
              !disconnectInProgress,
              !shuttingDown else {
            publicationGate.beginConnecting(sessionGeneration: generation)
            return
        }
        guard publicationGate.markReady(sessionGeneration: generation) else { return }
        retryAttempt = 0
        retryTask?.cancel()
        retryTask = nil
        state = .ready
        updateCallbackPumpDemand()
        onReady?()
    }

    private func scheduleReconnect() {
        guard retryTask == nil, credentials != nil,
              !userRequestedDisconnect, !disconnectInProgress, !shuttingDown else { return }
        let generation = sessionGeneration
        let delay = min(60, 1 << min(retryAttempt, 6))
        retryAttempt += 1
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  self.isCurrent(generation),
                  !self.userRequestedDisconnect,
                  !self.disconnectInProgress,
                  let current = self.credentials else { return }
            self.retryTask = nil
            if current.expiresAt.timeIntervalSinceNow <= Self.proactiveRefreshWindow {
                await self.refreshCredentials()
            } else {
                await self.install(current, sessionGeneration: generation)
            }
            self.updateCallbackPumpDemand()
        }
        updateCallbackPumpDemand()
    }

    private func requireAuthorization(sessionGeneration generation: UInt64) async {
        guard isCurrent(generation), !userRequestedDisconnect else { return }
        credentials = nil
        sessionHasAcceptedToken = false
        retryTask?.cancel()
        retryTask = nil
        expirationTask?.cancel()
        expirationTask = nil
        warning = nil
        _ = DiscordSocialLogoutBarrier.raise()
        disconnectInProgress = true
        disconnectCleanupComplete = false
        pendingFallbackState = .authorizationRequired
        publicationGate.beginConnecting(sessionGeneration: generation)
        updateCallbackPumpDemand()
        await clearRichPresence()
        var removalSucceeded = true
        do {
            try await credentialStore.remove()
            _ = DiscordSocialLogoutBarrier.clear()
        } catch {
            removalSucceeded = false
            warning = "NokoCord could not remove the expired Discord authorization from Keychain."
        }
        guard isCurrent(generation), !userRequestedDisconnect else { return }
        disconnectCleanupComplete = true
        await requestDisconnectToFallback(
            removalSucceeded
                ? .authorizationRequired
                : .failed("Discord authorization cleanup is still pending."),
            generation: generation
        )
    }

    private func disconnectToFallback(
        state fallbackState: DiscordSocialAccountState,
        sessionGeneration generation: UInt64,
        retryAfterDisconnect shouldRetry: Bool = false
    ) async {
        guard isCurrent(generation), !userRequestedDisconnect else { return }
        await requestDisconnectToFallback(
            fallbackState,
            generation: generation,
            retryAfterDisconnect: shouldRetry
        )
    }

    private func requestDisconnectToFallback(
        _ fallbackState: DiscordSocialAccountState,
        generation: UInt64,
        retryAfterDisconnect shouldRetry: Bool = false
    ) async {
        guard isCurrent(generation) else { return }
        disconnectInProgress = true
        disconnectCleanupComplete = true
        pendingFallbackState = fallbackState
        retryAfterDisconnect = shouldRetry
        publicationGate.beginConnecting(sessionGeneration: generation)
        updateCallbackPumpDemand()
        await publicationGate.waitForPublicationsToDrain()
        guard isCurrent(generation), disconnectInProgress else { return }
        client.disconnect()
        if await waitForDisconnected() {
            await finishPendingDisconnect()
        } else {
            updateCallbackPumpDemand()
        }
    }

    private func finishPendingDisconnect() async {
        let generation = sessionGeneration
        let observedStatus = await readCurrentSDKStatus()
        currentStatus = observedStatus
        guard disconnectInProgress,
              disconnectCleanupComplete,
              pendingFallbackState != nil,
              generation == sessionGeneration,
              observedStatus == Self.disconnectedStatus else { return }

        publicationGate.useDesktopRPC(sessionGeneration: generation)
        guard generation == sessionGeneration else {
            publicationGate.beginConnecting(sessionGeneration: sessionGeneration)
            return
        }
        let fallback = pendingFallbackState
        let shouldRetry = retryAfterDisconnect
        pendingFallbackState = nil
        retryAfterDisconnect = false
        disconnectInProgress = false
        disconnectCleanupComplete = false
        userRequestedDisconnect = false
        if let fallback { state = fallback }
        updateCallbackPumpDemand()
        onDesktopRPCFallback?()
        if shouldRetry { scheduleReconnect() }
    }

    private func waitForDisconnected(timeout: TimeInterval = 3.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = await readCurrentSDKStatus()
            currentStatus = status
            if status == Self.disconnectedStatus { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        currentStatus = await readCurrentSDKStatus()
        return currentStatus == Self.disconnectedStatus
    }

    /// Give an in-flight refresh a bounded chance to persist a rotated token
    /// pair before the callback pump stops during app shutdown.
    private func waitForRefreshDuringShutdown(timeout: TimeInterval = 5.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while refreshOperationID != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func readCurrentSDKStatus() async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let gate = DiscordSocialContinuationGate(continuation)
            client.refreshConnectionStatus { status in gate.complete(status) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                gate.complete(Int.min)
            }
        }
    }

    private func revoke(refreshToken: String) async -> Bool {
        let operationID = UUID()
        pendingRevocationCallbacks.insert(operationID)
        updateCallbackPumpDemand()
        return await withCheckedContinuation { continuation in
            let gate = DiscordSocialContinuationGate(continuation)
            client.revokeToken(refreshToken) { [weak self] result in
                gate.complete(result.isSuccessful)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pendingRevocationCallbacks.remove(operationID)
                    self.updateCallbackPumpDemand()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                gate.complete(false)
            }
        }
    }

    private func clearRichPresence() async {
        await publicationGate.waitForPublicationsToDrain()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = DiscordSocialContinuationGate(continuation)
            client.clearRichPresence { [publicationGate] _ in
                publicationGate.accountClearWasIssued()
                gate.complete(())
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [publicationGate] in
                publicationGate.accountClearWasIssued()
                gate.complete(())
            }
        }
    }

    private func updateCallbackPumpDemand() {
        authorizationIsQuarantined = !pendingAuthorizationCallbacks.isEmpty ||
            lateCallbackCleanupCount > 0 || !pendingRevocationCallbacks.isEmpty
        guard !shuttingDown else {
            setCallbackPumpDemand(
                shutdownDisconnectInProgress || currentStatus != Self.disconnectedStatus ||
                    client.connectionStatus() != Self.disconnectedStatus
            )
            return
        }
        let sdkIsActive = currentStatus != Self.disconnectedStatus || client.connectionStatus() != Self.disconnectedStatus
        let demanded = authorizationInProgress || refreshOperationID != nil || installOperationID != nil ||
            !pendingAuthorizationCallbacks.isEmpty || lateCallbackCleanupCount > 0 || !pendingRevocationCallbacks.isEmpty ||
            disconnectInProgress || retryTask != nil || sdkIsActive || state == .ready ||
            state == .connecting || state == .reconnecting
        setCallbackPumpDemand(demanded)
    }

    private func setCallbackPumpDemand(_ demanded: Bool) {
        guard callbackPumpDemand != demanded else { return }
        callbackPumpDemand = demanded
        onCallbackPumpDemandChanged?(demanded)
    }
}
