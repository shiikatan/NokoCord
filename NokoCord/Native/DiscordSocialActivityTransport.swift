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

    func complete(_ result: Result<Void, any Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// App-only adapter. The shared activity bridge never imports Discord SDK types.
final class DiscordSocialActivityTransport: NokoActivityTransport, @unchecked Sendable {
    private let client: NokoDiscordSocialClient

    init(client: NokoDiscordSocialClient) {
        self.client = client
    }

    func update(activity: NokoActivity) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = DiscordCompletionGate(continuation)
            client.updateRichPresence(
                details: activity.details ?? activity.title,
                state: activity.state,
                startedAt: activity.startedAt,
                endsAt: activity.endsAt
            ) { result in
                if result.isSuccessful {
                    gate.complete(.success(()))
                } else {
                    gate.complete(.failure(DiscordSocialTransportError(message: result.message)))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                gate.complete(.failure(DiscordSocialTransportError(message: "Rich Presence callback timed out.")))
            }
        }
    }

    func clear() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = DiscordCompletionGate(continuation)
            client.clearRichPresence { result in
                if result.isSuccessful {
                    gate.complete(.success(()))
                } else {
                    gate.complete(.failure(DiscordSocialTransportError(message: result.message)))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                gate.complete(.failure(DiscordSocialTransportError(message: "Rich Presence clear timed out.")))
            }
        }
    }
}

/// Owns the SDK client and callback pump independently of any SwiftUI window.
@MainActor
final class NokoActivityRuntime {
    private let client = NokoDiscordSocialClient(applicationID: 0)
    private lazy var bridge = NokoActivityBridge(transport: DiscordSocialActivityTransport(client: client))
    private let smokeOwner = NokoActivityOwner("nokocord.smoke")
    private let smokeActivity = NokoActivity(
        title: "NokoCord",
        details: "NokoCord Activity Bridge",
        state: "Social SDK transport test"
    )
    private var callbackTimer: Timer?
    private var retryTimer: Timer?
    private var discordLaunchObserver: NSObjectProtocol?
    private var stopping = false

    func startSmokeTest() {
        stopping = false
        callbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.client.runCallbacks() }
        }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publishSmoke() }
        }
        discordLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier?.localizedCaseInsensitiveContains("discord") == true else { return }
            Task { @MainActor in await self?.reassert() }
        }
        publishSmoke()
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
        retryTimer?.invalidate()
        if let discordLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(discordLaunchObserver)
        }
        do {
            _ = try await bridge.stop(ownedBy: smokeOwner)
        } catch {
            NSLog("NokoCord Social SDK clear failed: %@", error.localizedDescription)
        }
        callbackTimer?.invalidate()
    }
}
