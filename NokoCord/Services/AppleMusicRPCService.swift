import Foundation
import AppKit
import Observation

/// Coordinates Apple Music playback tracking, LastFM integration, and Discord Rich Presence broadcasting.
@MainActor @Observable
public final class AppleMusicRPCService: NSObject {
    public static let shared = AppleMusicRPCService()

    public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "appleMusicRPCEnabled")
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }

    public private(set) var currentTrack: AppleMusicTrack?
    public private(set) var isLastFMDetected: Bool = false
    public private(set) var lastFMStatusText: String = ""
    public private(set) var isDiscordDesktopConnected: Bool = false
    public private(set) var isRunning: Bool = false

    public var onPresenceChange: ((GamePresence?) -> Void)?

    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var distributedObserver: NSObjectProtocol?
    @ObservationIgnored private let detector = AppleMusicDetector.shared
    @ObservationIgnored private let socialBridge = DiscordSocialSDKBridge.shared

    public override init() {
        // Defaults to enabled unless explicitly turned off by the user
        let stored = UserDefaults.standard.object(forKey: "appleMusicRPCEnabled") as? Bool ?? true
        self.isEnabled = stored
        super.init()

        refreshLastFMStatus()

        if isEnabled {
            start()
        }
    }

    public func refreshLastFMStatus() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let lastFMInstalled = detector.isLastFMInstalled()
        self.isLastFMDetected = lastFMInstalled

        if lastFMInstalled {
            let lastFMSwiftPath = home.appendingPathComponent("LastFMSwift/LastFM.app").path
            if FileManager.default.fileExists(atPath: lastFMSwiftPath) {
                lastFMStatusText = "Active: LastFM.app detected in LastFMSwift"
            } else {
                lastFMStatusText = "Active: LastFM.app installed in Applications"
            }
        } else {
            lastFMStatusText = "Native Apple Music detector"
        }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        refreshLastFMStatus()

        // 1. Subscribe to macOS distributed player notifications for zero-latency changes
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }

        // 2. Poll every 3 seconds for smooth progress tracking
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }

        // Initial poll
        poll()
    }

    public func stop() {
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil

        if let obs = distributedObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            distributedObserver = nil
        }

        currentTrack = nil
        onPresenceChange?(nil)
        socialBridge.clearPresence()
    }

    public func toggle() {
        isEnabled.toggle()
    }

    /// Checks the current Apple Music state and synchronizes with Discord.
    public func poll() {
        guard isEnabled else { return }

        guard let track = detector.getCurrentTrack(), track.playerState.isPlaying else {
            if currentTrack != nil {
                currentTrack = nil
                onPresenceChange?(nil)
                socialBridge.clearPresence()
            }
            return
        }

        // Check if track changed or position advanced significantly
        let trackChanged = currentTrack?.id != track.id || currentTrack?.playerState != track.playerState
        var updatedTrack = track

        if trackChanged {
            self.currentTrack = updatedTrack

            // Asynchronously resolve album art from iTunes Search API or local LastFM cache
            Task {
                if let artworkURL = await detector.resolveArtwork(for: updatedTrack) {
                    updatedTrack.artworkURL = artworkURL
                    if self.currentTrack?.id == updatedTrack.id {
                        self.currentTrack = updatedTrack
                        self.broadcastPresence(updatedTrack)
                    }
                }
            }
        } else {
            // Keep existing artwork URL if already resolved
            updatedTrack.artworkURL = currentTrack?.artworkURL
            self.currentTrack = updatedTrack
        }

        broadcastPresence(updatedTrack)
    }

    private func broadcastPresence(_ track: AppleMusicTrack) {
        let presence = track.toGamePresence()

        // 1. Dispatch to NokoCord's internal Discord session
        onPresenceChange?(presence)

        // 2. Dispatch to Discord Desktop via Social SDK and Unix IPC socket
        socialBridge.updatePresence(for: track)
        isDiscordDesktopConnected = socialBridge.isIPCConnected
    }
}
