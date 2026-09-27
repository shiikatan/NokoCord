import Foundation
import AppKit
import Observation

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
            stopPlayback()
            return
        }
        if let track = detector.getCurrentTrack(), track.playerState.isPlaying {
            show(track)
        } else {
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
    }

    private func begin() {
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
        stopPlayback()
    }

    /// Adopts a track the detector reported. The Discord progress bar comes from
    /// the activity's start and end timestamps, so no position ticker is needed.
    private func show(_ track: AppleMusicTrack) {
        let changed = currentTrack?.id != track.id || currentTrack?.playerState != track.playerState
        var updated = track
        if changed {
            cancelScheduledStop()
            currentTrack = updated
            publish(updated)
            guard updated.artworkURL == nil || updated.artistImageURL == nil else { return }
            let pending = updated
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
        } else {
            updated.artworkURL = currentTrack?.artworkURL
            updated.artistImageURL = currentTrack?.artistImageURL
            if let watcherLastSeen, Date().timeIntervalSince(watcherLastSeen) < 20 {
                // Keep the watcher's position; the notification's elapsed time
                // can lag well behind the player.
                updated = updated.repositioned(to: currentTrack?.currentPosition ?? updated.position)
            }
            currentTrack = updated
            publish(updated)
        }
    }

    private func stopPlayback() {
        currentTrack = nil
        publish(nil)
    }

    /// A track that ends posts a stopped state just before the next play, and a
    /// repeat may not post anything else. Clearing straight away is what made a
    /// looping song vanish, so the clear waits briefly for that next play.
    private func scheduleStop() {
        guard stopTask == nil else { return }
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.stopTask = nil
            guard self.currentTrack?.playerState.isPlaying != true else { return }
            self.stopPlayback()
        }
    }

    private func cancelScheduledStop() {
        stopTask?.cancel()
        stopTask = nil
    }

    private func publish(_ track: AppleMusicTrack?) {
        onPresenceChange?()
    }

    /// NokoMusicWatch, the unsandboxed helper bundled with the app, is the
    /// only component that may read Music over Apple Events. It polls the
    /// player and broadcasts what it sees, which is what reports a repeated
    /// track, a seek or a stop that the player never announces.
    private func startMusicWatcher() {
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
        launchWatcherIfNeeded()
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
                if !isReporting { self.launchWatcherIfNeeded() }
            }
        }
    }

    private func stopMusicWatcher() {
        watcherWatchdog?.cancel()
        watcherWatchdog = nil
        watcherLastSeen = nil
        if let watcherObserver {
            DistributedNotificationCenter.default().removeObserver(watcherObserver)
            self.watcherObserver = nil
        }
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: Self.watcherBundleID) {
            application.terminate()
        }
    }

    private func launchWatcherIfNeeded() {
        guard let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NokoMusicWatch.app", isDirectory: true) as URL?,
              FileManager.default.fileExists(atPath: url.path) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = ["--owner", Bundle.main.bundleIdentifier ?? ""]
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    /// Adopts what the helper saw. Positions are exact, so this is also the
    /// path that re-anchors the seek bar and catches a repeating track.
    private func applyWatcherBroadcast(_ userInfo: [AnyHashable: Any]?) {
        watcherLastSeen = Date()
        guard let state = userInfo?["state"] as? String else { return }
        switch state {
        case "playing":
            guard let track = AppleMusicTrack(watcherBroadcast: userInfo) else { return }
            isPositionAccessDenied = false
            cancelScheduledStop()
            if let current = currentTrack, current.playerState.isPlaying,
               current.name == track.name, current.artist == track.artist {
                guard abs(track.position - current.currentPosition) > 2 else { return }
                let reanchored = current.repositioned(to: track.position)
                currentTrack = reanchored
                publish(reanchored)
                return
            }
            show(track)
        case "paused", "stopped", "not_running":
            scheduleStop()
        case "denied", "unavailable":
            // "unavailable" is what the helper reports when the Apple Event to
            // Music comes back empty, which in practice means macOS never
            // granted it. Either way the player cannot be read, so surface the
            // same explanation rather than silence.
            // macOS never prompted, or the user declined: Settings explains how
            // to allow it instead of failing silently.
            isPositionAccessDenied = true
        default:
            break
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
                if let track = self.detector.handlePlayerNotification(notification.userInfo), track.playerState.isPlaying {
                    self.cancelScheduledStop()
                    self.show(track)
                } else {
                    self.scheduleStop()
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
