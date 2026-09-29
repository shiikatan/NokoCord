import Foundation
import AppKit
import Observation

public enum AppleMusicPositionAccuracy: String, Equatable, Sendable {
    case exact
    case estimated
    case unavailable
}

public enum AppleMusicHelperStatus: String, Equatable, Sendable {
    case notStarted
    case connected
    case notRunning
    case missing
    case accessDenied
    case unsupported
    case stale

    public var userMessage: String? {
        switch self {
        case .notStarted, .connected:
            return nil
        case .notRunning:
            return "Apple Music is not running. Playback will appear when Music starts."
        case .missing:
            return "Apple Music helper is unavailable. NokoCord will retry automatically."
        case .accessDenied:
            return "Apple Music Automation access is unavailable. Allow NokoCord to control Music in System Settings → Privacy & Security → Automation."
        case .unsupported:
            return "Apple Music reported an unsupported playback state; exact position is unavailable."
        case .stale:
            return "Apple Music data is stale. NokoCord will retry the helper."
        }
    }
}

public struct AppleMusicPlaybackEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case playing(track: AppleMusicTrack, accuracy: AppleMusicPositionAccuracy)
        case seeked(track: AppleMusicTrack, accuracy: AppleMusicPositionAccuracy)
        case repeated(track: AppleMusicTrack, accuracy: AppleMusicPositionAccuracy)
        case nextTrack(track: AppleMusicTrack, accuracy: AppleMusicPositionAccuracy)
        case paused(track: AppleMusicTrack?, accuracy: AppleMusicPositionAccuracy)
        case stopped(track: AppleMusicTrack?, accuracy: AppleMusicPositionAccuracy)
        case notRunning
        case clear
        case helperDisconnected
        case helperUnavailable
        case helperDenied
        case helperUnsupported
        case helperStale
    }

    public let generation: UInt64
    public let timestamp: Date
    public let kind: Kind

    public init(generation: UInt64, timestamp: Date, kind: Kind) {
        self.generation = generation
        self.timestamp = timestamp
        self.kind = kind
    }
}

public enum AppleMusicPlaybackState: String, Equatable, Sendable {
    case idle
    case playing
    case paused
    case stopped
}

public struct AppleMusicPlaybackSnapshot: Equatable, Sendable {
    public let currentTrack: AppleMusicTrack?
    public let helperStatus: AppleMusicHelperStatus
    public let playbackState: AppleMusicPlaybackState
    public let positionAccuracy: AppleMusicPositionAccuracy
    public let lastEventAt: Date?
    public let generation: UInt64
    public let message: String?

    public init(currentTrack: AppleMusicTrack? = nil,
                helperStatus: AppleMusicHelperStatus = .notStarted,
                playbackState: AppleMusicPlaybackState = .idle,
                positionAccuracy: AppleMusicPositionAccuracy = .unavailable,
                lastEventAt: Date? = nil,
                generation: UInt64 = 0,
                message: String? = nil) {
        self.currentTrack = currentTrack
        self.helperStatus = helperStatus
        self.playbackState = playbackState
        self.positionAccuracy = positionAccuracy
        self.lastEventAt = lastEventAt
        self.generation = generation
        self.message = message
    }
}

/// Reduces player and helper notifications into one monotonic playback state.
/// A delayed clear carries the generation that scheduled it; a newer event or
/// an older timestamp therefore cannot erase the track that superseded it.
public struct AppleMusicPlaybackReducer: Sendable {
    public private(set) var snapshot: AppleMusicPlaybackSnapshot

    public init(snapshot: AppleMusicPlaybackSnapshot = .init()) {
        self.snapshot = snapshot
    }

    @discardableResult
    public mutating func reduce(_ event: AppleMusicPlaybackEvent) -> AppleMusicPlaybackSnapshot {
        guard event.generation >= snapshot.generation else { return snapshot }
        if let lastEventAt = snapshot.lastEventAt, event.timestamp < lastEventAt {
            return snapshot
        }

        var next = snapshot
        next = AppleMusicPlaybackSnapshot(currentTrack: next.currentTrack,
                                          helperStatus: next.helperStatus,
                                          playbackState: next.playbackState,
                                          positionAccuracy: next.positionAccuracy,
                                          lastEventAt: event.timestamp,
                                          generation: event.generation,
                                          message: next.message)

        switch event.kind {
        case let .playing(track, accuracy),
             let .seeked(track, accuracy),
             let .repeated(track, accuracy),
             let .nextTrack(track, accuracy):
            next = AppleMusicPlaybackSnapshot(currentTrack: track,
                                              helperStatus: .connected,
                                              playbackState: .playing,
                                              positionAccuracy: accuracy,
                                              lastEventAt: event.timestamp,
                                              generation: event.generation)
        case .paused(let track, let accuracy):
            let pausedTrack = track?.withPlayerState(.paused) ?? next.currentTrack?.withPlayerState(.paused)
            next = AppleMusicPlaybackSnapshot(currentTrack: pausedTrack,
                                              helperStatus: .connected,
                                              playbackState: .paused,
                                              positionAccuracy: accuracy,
                                              lastEventAt: event.timestamp,
                                              generation: event.generation)
        case .stopped(let track, let accuracy):
            let stoppedTrack = track?.withPlayerState(.stopped) ?? next.currentTrack?.withPlayerState(.stopped)
            next = AppleMusicPlaybackSnapshot(currentTrack: stoppedTrack,
                                              helperStatus: .connected,
                                              playbackState: .stopped,
                                              positionAccuracy: accuracy,
                                              lastEventAt: event.timestamp,
                                              generation: event.generation,
                                              message: next.helperStatus.userMessage)
        case .notRunning:
            next = AppleMusicPlaybackSnapshot(currentTrack: nil,
                                              helperStatus: .notRunning,
                                              playbackState: .idle,
                                              positionAccuracy: .unavailable,
                                              lastEventAt: event.timestamp,
                                              generation: event.generation,
                                              message: AppleMusicHelperStatus.notRunning.userMessage)
        case .clear:
            next = AppleMusicPlaybackSnapshot(currentTrack: nil,
                                              helperStatus: next.helperStatus,
                                              playbackState: .idle,
                                              positionAccuracy: .unavailable,
                                              lastEventAt: event.timestamp,
                                              generation: event.generation,
                                              message: next.helperStatus.userMessage)
        case .helperDisconnected:
            next = AppleMusicPlaybackSnapshot(currentTrack: next.currentTrack,
                                              helperStatus: .missing,
                                              playbackState: next.playbackState,
                                              positionAccuracy: .unavailable,
                                              lastEventAt: event.timestamp,
                                              generation: event.generation,
                                              message: AppleMusicHelperStatus.missing.userMessage)
        case .helperUnavailable:
            next = AppleMusicPlaybackSnapshot(currentTrack: next.currentTrack,
                                              helperStatus: .missing,
                                              playbackState: next.playbackState,
                                              positionAccuracy: .unavailable,
                                              lastEventAt: event.timestamp,
                                              generation: event.generation,
                                              message: AppleMusicHelperStatus.missing.userMessage)
        case .helperDenied:
            next = AppleMusicPlaybackSnapshot(currentTrack: next.currentTrack,
                                              helperStatus: .accessDenied,
                                              playbackState: next.playbackState,
                                              positionAccuracy: .unavailable,
                                              lastEventAt: event.timestamp,
                                              generation: event.generation,
                                              message: AppleMusicHelperStatus.accessDenied.userMessage)
        case .helperUnsupported:
            next = AppleMusicPlaybackSnapshot(currentTrack: next.currentTrack,
                                              helperStatus: .unsupported,
                                              playbackState: next.playbackState,
                                              positionAccuracy: .unavailable,
                                              lastEventAt: event.timestamp,
                                              generation: event.generation,
                                              message: AppleMusicHelperStatus.unsupported.userMessage)
        case .helperStale:
            next = AppleMusicPlaybackSnapshot(currentTrack: next.currentTrack,
                                              helperStatus: .stale,
                                              playbackState: next.playbackState,
                                              positionAccuracy: .unavailable,
                                              lastEventAt: event.timestamp,
                                              generation: event.generation,
                                              message: AppleMusicHelperStatus.stale.userMessage)
        }

        snapshot = next
        return next
    }
}

/// A small, deterministic backoff shared by the service's helper watchdog.
/// A successful report resets it, while repeated launch attempts cap at the
/// maximum delay instead of relaunching the helper in a tight loop.
public struct AppleMusicWatcherReconnectPolicy: Equatable, Sendable {
    public let baseDelay: TimeInterval
    public let maximumDelay: TimeInterval
    public private(set) var attemptCount = 0
    public private(set) var nextAttemptAt: Date?

    public init(baseDelay: TimeInterval = 10, maximumDelay: TimeInterval = 60) {
        self.baseDelay = max(0, baseDelay)
        self.maximumDelay = max(self.baseDelay, maximumDelay)
    }

    public func canAttempt(at date: Date) -> Bool {
        guard let nextAttemptAt else { return true }
        return date >= nextAttemptAt
    }

    public mutating func recordAttempt(at date: Date) {
        var delay = baseDelay
        if attemptCount > 0 {
            for _ in 0..<min(attemptCount, 16) {
                delay = min(maximumDelay, delay * 2)
            }
        }
        attemptCount += 1
        nextAttemptAt = date.addingTimeInterval(min(maximumDelay, delay))
    }

    public mutating func recordReport(at _: Date) {
        attemptCount = 0
        nextAttemptAt = nil
    }
}

/// Keeps the helper alive only while its owning NokoCord process exists. The
/// helper's process timer and this model share the same grace-period rule so
/// termination behavior remains bounded and testable without launching apps.
public struct AppleMusicWatcherOwnerPolicy: Equatable, Sendable {
    public let gracePeriod: TimeInterval
    public private(set) var missingSince: Date?

    public init(gracePeriod: TimeInterval = 30) {
        self.gracePeriod = max(0, gracePeriod)
    }

    public mutating func shouldTerminate(ownerIsRunning: Bool, at date: Date) -> Bool {
        guard !ownerIsRunning else {
            missingSince = nil
            return false
        }
        let firstMissing = missingSince ?? date
        missingSince = firstMissing
        return date.timeIntervalSince(firstMissing) >= gracePeriod
    }
}

/// A process-local model of the single-helper lease. The real helper also
/// takes an OS file lock; this model keeps ownership semantics covered by the
/// same focused test suite as the reducer.
public struct AppleMusicWatcherOwnership: Equatable, Sendable {
    public private(set) var ownerID: String?

    public init(ownerID: String? = nil) {
        self.ownerID = ownerID
    }

    @discardableResult
    public mutating func acquire(ownerID: String) -> Bool {
        guard self.ownerID == nil else { return false }
        self.ownerID = ownerID
        return true
    }

    @discardableResult
    public mutating func release(ownerID: String) -> Bool {
        guard self.ownerID == ownerID else { return false }
        self.ownerID = nil
        return true
    }
}

/// The notification payload emitted by NokoMusicWatch. Older helpers may omit
/// sequence and timestamp, but an explicitly malformed timestamp is rejected.
public struct AppleMusicWatcherPayload: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case playing
        case paused
        case stopped
        case notRunning = "not_running"
        case denied
        case unavailable
        case unsupported
    }

    public let state: State
    public let sequence: UInt64?
    public let timestamp: Date?
    public let reportedPositionAccuracy: AppleMusicPositionAccuracy?

    public init?(userInfo: [AnyHashable: Any]) {
        guard let rawState = userInfo["state"] as? String,
              let state = State(rawValue: rawState) else { return nil }

        if let rawTimestamp = userInfo["eventTimestamp"] {
            let seconds: Double?
            if let number = rawTimestamp as? NSNumber {
                seconds = number.doubleValue
            } else if let value = rawTimestamp as? Double {
                seconds = value
            } else {
                seconds = nil
            }
            guard let seconds, seconds.isFinite else { return nil }
            timestamp = Date(timeIntervalSince1970: seconds)
        } else {
            timestamp = nil
        }

        if let rawSequence = userInfo["sequence"] as? NSNumber {
            guard rawSequence.int64Value >= 0 else { return nil }
            sequence = rawSequence.uint64Value
        } else if let rawSequence = userInfo["sequence"] as? UInt64 {
            sequence = rawSequence
        } else {
            sequence = nil
        }
        if let rawAccuracy = userInfo["positionAccuracy"] as? String {
            reportedPositionAccuracy = AppleMusicPositionAccuracy(rawValue: rawAccuracy)
        } else {
            reportedPositionAccuracy = nil
        }
        self.state = state
    }
}

private extension AppleMusicTrack {
    func withPlayerState(_ state: PlayerState) -> AppleMusicTrack {
        AppleMusicTrack(databaseID: databaseID,
                        name: name,
                        artist: artist,
                        album: album,
                        duration: duration,
                        position: position,
                        playerState: state,
                        artworkURL: artworkURL,
                        artistImageURL: artistImageURL,
                        source: source,
                        updatedAt: updatedAt)
    }
}

/// Apple Music Rich Presence: detects local playback and resolves artwork. The
/// bundled `noko.apple-music` Tan is the feature's switch; the app itself
/// delivers the activity inside the signed-in Discord session.
///
/// The Tan is the feature's switch. `setActive(_:)` follows `TanManager` state
/// through the browser engine, so disabling or uninstalling the Tan, or
/// entering Safe Mode, stops detection and delivery together.
@MainActor @Observable
public final class AppleMusicRPCService: NSObject {
    public static let shared = AppleMusicRPCService()

    /// True while the Tan is enabled and not suppressed by Safe Mode.
    public private(set) var isEnabled = false
    public private(set) var currentTrack: AppleMusicTrack?
    public private(set) var lastFMStatusText = ""
    /// Set when macOS reported that NokoCord may not read Music's position.
    public private(set) var isPositionAccessDenied = false
    public private(set) var helperStatus: AppleMusicHelperStatus = .notStarted
    public private(set) var positionAccuracy: AppleMusicPositionAccuracy = .unavailable
    /// A truthful, user-facing explanation for helper and data lifecycle
    /// failures. The existing settings surface renders this status text.
    public private(set) var statusMessage: String?

    static let watcherNotification = "com.shiikatan.nokocord.music"
    static let watcherBundleID = "com.shiikatan.nokocord.musicwatch"

    /// UserDefaults key holding the Discord application id sent with the
    /// activity. Artwork and images only resolve for a registered application.
    public static let applicationIDKey = "appleMusicDiscordApplicationID"

    /// The configured Discord application id, falling back to the bundled one.
    public static var configuredApplicationID: String {
        let stored = (UserDefaults.standard.string(forKey: applicationIDKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = stored.allSatisfy(\.isNumber) && (17...20).contains(stored.count)
        return digits ? stored : AppleMusicTrack.discordApplicationID
    }

    /// Reports that the activity to show has changed. The engine reads
    /// `currentTrack` and builds the activity, so there is one construction
    /// site rather than two that can drift.
    public var onPresenceChange: (() -> Void)?

    @ObservationIgnored private var playerObserver: NSObjectProtocol?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var watcherObserver: NSObjectProtocol?
    /// Set while NokoMusicWatch is reporting, so its exact positions win over
    /// the player notification's own elapsed time.
    @ObservationIgnored private var watcherLastSeen: Date?
    @ObservationIgnored private var watcherWatchdog: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var reducer = AppleMusicPlaybackReducer()
    @ObservationIgnored private var eventGeneration: UInt64 = 0
    @ObservationIgnored private var watcherReconnect = AppleMusicWatcherReconnectPolicy()
    @ObservationIgnored private let detector = AppleMusicDetector.shared

    /// Starts or stops the service with the bundled Tan's active state.
    public func setActive(_ active: Bool) {
        guard active != isEnabled else { return }
        isEnabled = active
        if active { begin() } else { end() }
    }

    /// One-shot status check for cold starts and explicit refreshes. Playback
    /// changes arrive as notifications; the service never polls.
    public func refresh() {
        guard isEnabled else { return }
        guard detector.isMusicAppRunning() else {
            _ = reduce(.notRunning, at: Date())
            return
        }
        guard let track = detector.getCurrentTrack() else {
            _ = reduce(.notRunning, at: Date())
            return
        }
        if track.playerState.isPlaying {
            show(track, accuracy: .estimated)
        } else {
            let kind: AppleMusicPlaybackEvent.Kind = track.playerState == .paused
                ? .paused(track: track, accuracy: .estimated)
                : .stopped(track: track, accuracy: .estimated)
            let snapshot = reduce(kind, at: Date()) ?? reducer.snapshot
            scheduleStop(for: snapshot.generation,
                         after: track.playerState == .paused ? Self.pauseGracePeriod : Self.stopGracePeriod)
        }
    }

    public func refreshLastFMStatus() {
        if detector.isLastFMInstalled() {
            let appInHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("LastFMSwift/LastFM.app").path
            lastFMStatusText = FileManager.default.fileExists(atPath: appInHome)
                ? String(localized: "Active: LastFM.app detected in LastFMSwift")
                : String(localized: "Active: LastFM.app installed in Applications")
        } else {
            lastFMStatusText = String(localized: "Native Apple Music detector")
        }
        if let statusMessage {
            lastFMStatusText = statusMessage
        }
    }

    private func begin() {
        reducer = AppleMusicPlaybackReducer()
        eventGeneration = 0
        watcherReconnect = AppleMusicWatcherReconnectPolicy()
        watcherLastSeen = nil
        refreshLastFMStatus()
        observePlayerNotifications()
        observeMusicApplication()
        refresh()
        startMusicWatcher()
    }

    private func end() {
        cancelScheduledStop()
        stopMusicWatcher()
        removeObservers()
        artworkTask?.cancel()
        artworkTask = nil
        reducer = AppleMusicPlaybackReducer()
        eventGeneration = 0
        applySnapshot(reducer.snapshot)
    }

    /// Adopts a track the detector reported. The Discord progress bar comes from
    /// the activity's start and end timestamps, so no position ticker is needed.
    private func show(_ track: AppleMusicTrack,
                      accuracy: AppleMusicPositionAccuracy,
                      at timestamp: Date = Date(),
                      generation: UInt64? = nil,
                      preserveWatcherPosition: Bool = true) {
        let previousTrack = currentTrack
        var updated = track
        if previousTrack?.id == track.id {
            updated.artworkURL = currentTrack?.artworkURL
            updated.artistImageURL = currentTrack?.artistImageURL
            if preserveWatcherPosition,
               accuracy == .estimated,
               let watcherLastSeen,
               Date().timeIntervalSince(watcherLastSeen) < 20 {
                // Keep the watcher's position; the notification's elapsed time
                // can lag well behind the player.
                updated = updated.repositioned(to: currentTrack?.currentPosition ?? updated.position)
            }
        }

        guard let snapshot = reduce(.playing(track: updated, accuracy: accuracy),
                                    at: timestamp,
                                    generation: generation),
              let adopted = snapshot.currentTrack else { return }

        cancelScheduledStop()

        let changed = previousTrack?.id != adopted.id || previousTrack?.playerState != adopted.playerState
        guard changed, adopted.artworkURL == nil || adopted.artistImageURL == nil else { return }
        let pending = adopted
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let self else { return }
            async let artwork = pending.artworkURL == nil ? self.detector.resolveArtwork(for: pending) : nil
            async let artistImage = pending.artistImageURL == nil ? self.detector.resolveArtistImage(for: pending) : nil
            let (resolvedArtwork, resolvedArtist) = await (artwork, artistImage)
            guard !Task.isCancelled, self.isEnabled, self.currentTrack?.id == pending.id,
                  self.currentTrack?.playerState == pending.playerState,
                  resolvedArtwork != nil || resolvedArtist != nil else { return }
            var merged = pending
            if let resolvedArtwork { merged.artworkURL = resolvedArtwork }
            if let resolvedArtist { merged.artistImageURL = resolvedArtist }
            self.currentTrack = merged
            self.publish(merged)
        }
    }

    private func stopPlayback() {
        _ = reduce(.clear, at: Date(), generation: reducer.snapshot.generation)
    }

    /// A track that ends posts a stopped state just before the next play, and a
    /// repeat may not post anything else. Clearing straight away is what made a
    /// looping song vanish, so a stop waits for the next track to claim the
    /// status. A pause is deliberate and nothing is coming, so it clears almost
    /// at once instead.
    private nonisolated static let stopGracePeriod: TimeInterval = 8
    private nonisolated static let pauseGracePeriod: TimeInterval = 1

    private func scheduleStop(for generation: UInt64,
                              after delay: TimeInterval = AppleMusicRPCService.stopGracePeriod) {
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.stopTask = nil
            guard self.reducer.snapshot.generation == generation else { return }
            _ = self.reduce(.clear, at: Date(), generation: generation)
        }
    }

    private func cancelScheduledStop() {
        stopTask?.cancel()
        stopTask = nil
    }

    private func publish(_ track: AppleMusicTrack?) {
        onPresenceChange?()
    }

    @discardableResult
    private func reduce(_ kind: AppleMusicPlaybackEvent.Kind,
                        at timestamp: Date,
                        generation: UInt64? = nil) -> AppleMusicPlaybackSnapshot? {
        let eventGeneration: UInt64
        if let generation {
            self.eventGeneration = max(self.eventGeneration, generation)
            eventGeneration = generation
        } else {
            self.eventGeneration &+= 1
            eventGeneration = self.eventGeneration
        }
        let previous = reducer.snapshot
        let next = reducer.reduce(.init(generation: eventGeneration,
                                        timestamp: timestamp,
                                        kind: kind))
        guard next != previous else { return nil }
        applySnapshot(next)
        return next
    }

    private func applySnapshot(_ snapshot: AppleMusicPlaybackSnapshot) {
        currentTrack = snapshot.currentTrack
        helperStatus = snapshot.helperStatus
        positionAccuracy = snapshot.positionAccuracy
        statusMessage = snapshot.message
        isPositionAccessDenied = snapshot.helperStatus == .accessDenied
        refreshLastFMStatus()
        publish(snapshot.currentTrack)
    }

    /// NokoMusicWatch, the unsandboxed helper bundled with the app, is the
    /// only component that may read Music over Apple Events. It polls the
    /// player and broadcasts what it sees, which is what reports a repeated
    /// track, a seek or a stop that the player never announces.
    private func startMusicWatcher() {
        watcherReconnect = AppleMusicWatcherReconnectPolicy()
        watcherObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(Self.watcherNotification),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled else { return }
                self.applyWatcherBroadcast(notification.userInfo)
            }
        }
        _ = launchWatcherIfNeeded(at: Date(), force: true)
        startWatcherWatchdog()
    }

    /// A helper that quits with the app, or one that is missed because a stale
    /// copy was still shutting down when NokoCord launched, would silently stop
    /// all music reporting. Asking again whenever nothing has been heard is
    /// harmless, because LaunchServices activates the running helper instead of
    /// starting a second copy.
    private func startWatcherWatchdog() {
        watcherWatchdog?.cancel()
        watcherWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                guard let self, self.isEnabled else { continue }
                let isReporting = self.watcherLastSeen.map { Date().timeIntervalSince($0) < 20 } ?? false
                let now = Date()
                if !isReporting, self.watcherReconnect.canAttempt(at: now) {
                    let lifecycleEvent: AppleMusicPlaybackEvent.Kind = self.watcherLastSeen == nil
                        ? .helperDisconnected
                        : .helperStale
                    _ = self.reduce(lifecycleEvent, at: now)
                    _ = self.launchWatcherIfNeeded(at: now)
                }
            }
        }
    }

    private func stopMusicWatcher() {
        watcherWatchdog?.cancel()
        watcherWatchdog = nil
        watcherLastSeen = nil
        watcherReconnect = AppleMusicWatcherReconnectPolicy()
        if let watcherObserver {
            DistributedNotificationCenter.default().removeObserver(watcherObserver)
            self.watcherObserver = nil
        }
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: Self.watcherBundleID) {
            application.terminate()
        }
    }

    @discardableResult
    private func launchWatcherIfNeeded(at date: Date, force: Bool = false) -> Bool {
        guard force || watcherReconnect.canAttempt(at: date) else { return false }
        watcherReconnect.recordAttempt(at: date)
        guard let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NokoMusicWatch.app", isDirectory: true) as URL?,
              FileManager.default.fileExists(atPath: url.path) else {
            _ = reduce(.helperDisconnected, at: date)
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = ["--owner", Bundle.main.bundleIdentifier ?? ""]
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        return true
    }

    /// Adopts what the helper saw. The helper's measured position is useful for
    /// re-anchoring seeks and repeats, but this unsigned distribution does not
    /// claim exact position to the user until the signed-build manual gate has
    /// passed.
    private func applyWatcherBroadcast(_ userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              let payload = AppleMusicWatcherPayload(userInfo: userInfo) else { return }
        let receivedAt = Date()
        watcherLastSeen = receivedAt
        watcherReconnect.recordReport(at: receivedAt)
        let timestamp = payload.timestamp ?? receivedAt
        switch payload.state {
        case .playing:
            guard let track = AppleMusicTrack(watcherBroadcast: userInfo) else { return }
            show(track,
                 accuracy: .estimated,
                 at: timestamp,
                 generation: payload.sequence,
                 preserveWatcherPosition: false)
        case .paused:
            let paused = currentTrack?.withPlayerState(.paused)
            let snapshot = reduce(.paused(track: paused, accuracy: .estimated),
                                  at: timestamp,
                                  generation: payload.sequence)
            if let snapshot {
                scheduleStop(for: snapshot.generation, after: Self.pauseGracePeriod)
            }
        case .stopped:
            let stopped = currentTrack?.withPlayerState(.stopped)
            let snapshot = reduce(.stopped(track: stopped, accuracy: .estimated),
                                  at: timestamp,
                                  generation: payload.sequence)
            if let snapshot {
                scheduleStop(for: snapshot.generation, after: Self.stopGracePeriod)
            }
        case .notRunning:
            _ = reduce(.notRunning, at: timestamp, generation: payload.sequence)
        case .denied:
            _ = reduce(.helperDenied, at: timestamp, generation: payload.sequence)
        case .unavailable:
            _ = reduce(.helperUnavailable, at: timestamp, generation: payload.sequence)
        case .unsupported:
            _ = reduce(.helperUnsupported, at: timestamp, generation: payload.sequence)
        }
    }

    private func observePlayerNotifications() {
        guard playerObserver == nil else { return }
        playerObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled else { return }
                let track = self.detector.handlePlayerNotification(notification.userInfo)
                if let track, track.playerState.isPlaying {
                    self.show(track, accuracy: .estimated)
                } else {
                    let kind: AppleMusicPlaybackEvent.Kind
                    if let track, track.playerState == .paused {
                        kind = .paused(track: track, accuracy: .estimated)
                    } else {
                        kind = .stopped(track: track, accuracy: .estimated)
                    }
                    guard let snapshot = self.reduce(kind, at: Date()) else { return }
                    self.scheduleStop(for: snapshot.generation,
                                      after: track?.playerState == .paused
                                      ? Self.pauseGracePeriod
                                      : Self.stopGracePeriod)
                }
            }
        }
    }

    /// Playback notifications stop arriving when Music quits, so the app's own
    /// launch and termination events complete the picture without polling.
    private func observeMusicApplication() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier == AppleMusicDetector.musicBundleIdentifier else { return }
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
    }

    private func removeObservers() {
        if let playerObserver {
            DistributedNotificationCenter.default().removeObserver(playerObserver)
            self.playerObserver = nil
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
    }
}
