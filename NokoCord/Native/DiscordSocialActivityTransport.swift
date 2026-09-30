import AppKit

private struct DiscordSocialTransportError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class DiscordCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func complete(_ result: Result<Void, any Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}

/// App-only adapter. The shared activity bridge never imports Discord SDK types.
final class DiscordSocialActivityTransport: NokoActivityTransport, @unchecked Sendable {
    private let client: NokoDiscordSocialClient
    private let publicationGate: DiscordSocialPublicationGate

    init(client: NokoDiscordSocialClient, publicationGate: DiscordSocialPublicationGate) {
        self.client = client
        self.publicationGate = publicationGate
    }

    func update(activity: NokoActivity) async throws {
        guard publicationGate.beginPublication() else {
            throw DiscordSocialTransportError(message: "Discord Social SDK is connecting; activity will be retried when it is ready.")
        }
        try await withCheckedThrowingContinuation { continuation in
            let gate = DiscordCompletionGate(continuation)
            client.updateRichPresence(
                type: activity.type.rawValue,
                name: activity.name,
                details: activity.details ?? activity.title,
                state: activity.state,
                startedAt: activity.startedAt,
                endsAt: activity.endsAt,
                statusDisplayField: activity.statusDisplayField?.rawValue,
                largeImage: activity.largeImageURL ?? activity.largeImageAssetKey,
                largeImageText: activity.largeImageText
            ) { result in
                let updateResult: Result<Void, any Error> = result.isSuccessful
                    ? .success(())
                    : .failure(DiscordSocialTransportError(message: result.message))
                if gate.complete(updateResult) {
                    self.publicationGate.endPublication()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if gate.complete(.failure(DiscordSocialTransportError(message: "Rich Presence callback timed out."))) {
                    self.publicationGate.endPublication()
                }
            }
        }
    }

    func clear() async throws {
        guard publicationGate.beginPublication() else {
            if publicationGate.deferClearIfBlocked() { return }
            throw DiscordSocialTransportError(message: "Discord Social SDK is connecting; presence will be cleared after it is ready.")
        }
        try await issueClear { _ in self.publicationGate.endPublication() }
    }

    func flushDeferredClear() async throws {
        guard publicationGate.beginDeferredClear() else { return }
        try await issueClear { succeeded in
            self.publicationGate.finishDeferredClear(succeeded: succeeded)
        }
    }

    private func issueClear(onFinished: @escaping (Bool) -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = DiscordCompletionGate(continuation)
            client.clearRichPresence { result in
                let clearResult: Result<Void, any Error> = result.isSuccessful
                    ? .success(())
                    : .failure(DiscordSocialTransportError(message: result.message))
                if gate.complete(clearResult) { onFinished(result.isSuccessful) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if gate.complete(.failure(DiscordSocialTransportError(message: "Rich Presence clear timed out."))) {
                    onFinished(false)
                }
            }
        }
    }
}

/// Owns the SDK client and callback pump independently of any SwiftUI window.
@MainActor
final class NokoActivityRuntime {
    private let client = NokoDiscordSocialClient(applicationID: 0)
    private let publicationGate = DiscordSocialPublicationGate()
    private lazy var transport = DiscordSocialActivityTransport(client: client, publicationGate: publicationGate)
    private lazy var bridge = NokoActivityBridge(transport: transport)
    lazy var discordAccount = DiscordSocialAccountService(client: client, publicationGate: publicationGate)
    lazy var appleMusicPresence = AppleMusicPresenceService(bridge: bridge)
    private let smokeOwner = NokoActivityOwner("nokocord.smoke")
    private let smokeActivity = NokoActivity(
        title: "NokoCord",
        details: "NokoCord Activity Bridge",
        state: "Social SDK transport test"
    )
    private var callbackTimer: Timer?
    private var discordLaunchObserver: NSObjectProtocol?
    private var stopping = false
    private var appleMusicCallbackDemand = false
    private var discordAccountCallbackDemand = false
    private var authenticatedSmokeTestActive = false
    private var shutdownClearActive = false

    func start(tanManager: TanManager) {
        stopping = false
        configureDiscordAccountCallbacks()
        Task { await discordAccount.start() }
        appleMusicPresence.onCallbackPumpDemandChanged = { [weak self] demanded in
            self?.appleMusicCallbackDemand = demanded
            self?.updateCallbackPump()
        }
        observeDiscordLaunches()
        appleMusicPresence.start(tanManager: tanManager)
    }

    private func updateCallbackPump() {
        if authenticatedSmokeTestActive || appleMusicCallbackDemand ||
            discordAccountCallbackDemand || shutdownClearActive {
            guard callbackTimer == nil else { return }
            callbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.client.runCallbacks() }
            }
        } else {
            callbackTimer?.invalidate()
            callbackTimer = nil
        }
    }

    private func observeDiscordLaunches() {
        guard discordLaunchObserver == nil else { return }
        discordLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier?.localizedCaseInsensitiveContains("discord") == true else { return }
            Task { @MainActor in await self?.reassert() }
        }
    }

    private func publishSmoke() {
        guard !stopping else { return }
        Task {
            guard !stopping else { return }
            do {
                let result = try await bridge.publish(smokeActivity, ownedBy: smokeOwner)
                if result == .published { NSLog("NokoCord Social SDK smoke activity accepted by SDK") }
            } catch {
                NSLog("NokoCord Social SDK smoke activity failed: %@", error.localizedDescription)
            }
        }
    }

    /// Debug acceptance route for verifying the authenticated Social SDK while
    /// the Discord desktop process is closed. It uses the same generic bridge.
    func startAuthenticatedSmokeTest() {
        stopping = false
        authenticatedSmokeTestActive = true
        configureDiscordAccountCallbacks()
        updateCallbackPump()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.discordAccount.start()
            if self.discordAccount.requiresAuthorization {
                await self.discordAccount.authorize()
            }
        }
    }

    private func configureDiscordAccountCallbacks() {
        discordAccount.onCallbackPumpDemandChanged = { [weak self] demanded in
            self?.discordAccountCallbackDemand = demanded
            self?.updateCallbackPump()
        }
        discordAccount.onReady = { [weak self] in
            self?.handlePresenceRouteAvailable()
        }
        discordAccount.onDesktopRPCFallback = { [weak self] in
            self?.handlePresenceRouteAvailable()
        }
    }

    private var routeAvailableTask: Task<Void, Never>?

    private func handlePresenceRouteAvailable() {
        guard routeAvailableTask == nil else { return }
        routeAvailableTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.routeAvailableTask = nil }
            do {
                try await self.transport.flushDeferredClear()
            } catch {
                return
            }
            if self.authenticatedSmokeTestActive {
                self.publishSmoke()
            } else {
                await self.reassert()
            }
        }
    }

    private func reassert() async {
        guard !stopping else { return }
        do {
            _ = try await bridge.reassert()
        } catch {
            NSLog("NokoCord Social SDK reassert failed: %@", error.localizedDescription)
        }
    }

    func stop() async {
        stopping = true
        shutdownClearActive = true
        updateCallbackPump()
        if let discordLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(discordLaunchObserver)
        }
        discordLaunchObserver = nil
        await appleMusicPresence.stop()
        _ = try? await bridge.stop()
        await discordAccount.shutdown()
        authenticatedSmokeTestActive = false
        appleMusicCallbackDemand = false
        discordAccountCallbackDemand = false
        shutdownClearActive = false
        updateCallbackPump()
    }
}
