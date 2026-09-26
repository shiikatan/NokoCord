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
        let stored = UserDefaults.standard.object(forKey: "appleMusicRPCEnabled") as? Bool ?? true
        self.isEnabled = stored
        super.init()

        // Defer startup to avoid blocking app initialization
        if isEnabled {
            DispatchQueue.main.async { [weak self] in
                self?.start()
            }
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

        // 1. Subscribe to macOS distributed player notifications for zero-latency, sandbox-safe track changes
        if distributedObserver == nil {
            distributedObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.Music.playerInfo"),
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self = self, self.isEnabled else { return }
                    if let track = self.detector.handlePlayerNotification(notification.userInfo) {
                        self.applyTrack(track)
                    } else {
                        self.stopPlayback()
                    }
                }
            }
        }

        // 2. Poll every 3 seconds for smooth progress tracking and app lifecycle monitoring
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // 3. Initial non-blocking check
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

        stopPlayback()
    }

    public func toggle() {
        isEnabled.toggle()
    }

    private func applyTrack(_ track: AppleMusicTrack) {
        guard track.playerState.isPlaying else {
            stopPlayback()
            return
        }

        let trackChanged = currentTrack?.id != track.id || currentTrack?.playerState != track.playerState
        var updated = track

        if trackChanged {
            self.currentTrack = updated
            Task { [weak self] in
                guard let self = self else { return }
                if let artworkURL = await self.detector.resolveArtwork(for: updated) {
                    await MainActor.run {
                        if self.currentTrack?.id == updated.id {
                            updated.artworkURL = artworkURL
                            self.currentTrack = updated
                            self.broadcastPresence(updated)
                        }
                    }
                }
            }
        } else {
            updated.artworkURL = currentTrack?.artworkURL
            self.currentTrack = updated
        }

        broadcastPresence(updated)
    }

    private func stopPlayback() {
        if currentTrack != nil {
            currentTrack = nil
            onPresenceChange?(nil)
            socialBridge.clearPresence()
        }
    }

    /// Checks the current Apple Music state and synchronizes with Discord.
    public func poll() {
        guard isEnabled else { return }

        // If Apple Music is not running, stop playback
        if !detector.isMusicAppRunning() {
            if currentTrack != nil {
                stopPlayback()
            }
            return
        }

        // If we have an active track playing, advance its position smoothly
        if let current = currentTrack, current.playerState.isPlaying {
            detector.updatePlaybackPosition(elapsedDelta: 3.0)
            if let updated = detector.getCurrentTrack() {
                self.currentTrack = updated
                broadcastPresence(updated)
            }
            return
        }

        // Otherwise check for existing track state (e.g. from LastFM cold start)
        if let track = detector.getCurrentTrack(), track.playerState.isPlaying {
            applyTrack(track)
        }
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
