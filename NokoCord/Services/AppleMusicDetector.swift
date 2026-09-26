import Foundation
import AppKit

/// Detects what's currently playing in Apple Music via LastFM integration and native macOS distributed notifications.
public final class AppleMusicDetector: @unchecked Sendable {
    public static let shared = AppleMusicDetector()

    private var latestTrack: AppleMusicTrack?
    private let trackLock = NSLock()
    private var artworkCache: [String: URL] = [:]
    private let cacheLock = NSLock()

    public init() {}

    /// Checks if LastFM.app is installed or running on the user's Mac.
    public func isLastFMInstalled() -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.verbog.lastfm").isEmpty {
            return true
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidatePaths = [
            home.appendingPathComponent("LastFMSwift/LastFM.app").path,
            "/Applications/LastFM.app",
            home.appendingPathComponent("Applications/LastFM.app").path
        ]
        return candidatePaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Checks if Apple Music is currently running.
    public func isMusicAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    /// Path to LastFM Application Support directory if present.
    public var lastFMSupportDirectory: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let lastFMDir = appSupport.appendingPathComponent("LastFM")
        return FileManager.default.fileExists(atPath: lastFMDir.path) ? lastFMDir : nil
    }

    /// Parses a `com.apple.Music.playerInfo` distributed notification userInfo dictionary.
    public func handlePlayerNotification(_ userInfo: [AnyHashable: Any]?) -> AppleMusicTrack? {
        guard let info = userInfo else { return nil }

        let name = (info["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = (info["Artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let album = (info["Album"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let playerStateStr = (info["Player State"] as? String)?.lowercased() ?? "stopped"

        guard !name.isEmpty else {
            trackLock.lock()
            latestTrack = nil
            trackLock.unlock()
            return nil
        }

        let totalTimeMs = (info["Total Time"] as? NSNumber)?.doubleValue ?? 0.0
        let duration = totalTimeMs > 0 ? (totalTimeMs / 1000.0) : 0.0
        let position = (info["Elapsed Time"] as? NSNumber)?.doubleValue ?? 0.0
        let databaseID = (info["Database ID"] as? NSNumber)?.intValue ?? 0

        let state: AppleMusicTrack.PlayerState
        if playerStateStr.contains("playing") {
            state = .playing
        } else if playerStateStr.contains("paused") {
            state = .paused
        } else {
            state = .stopped
        }

        let lastFMInstalled = isLastFMInstalled()
        let source: AppleMusicTrack.TrackingSource = lastFMInstalled ? .lastFMApp : .musicApp

        var track = AppleMusicTrack(
            databaseID: databaseID,
            name: name,
            artist: artist,
            album: album,
            duration: duration,
            position: position,
            playerState: state,
            artworkURL: nil,
            source: source,
            updatedAt: Date()
        )

        // Check if artwork is already cached
        let cacheKey = "\(artist.lowercased()):\(album.lowercased())"
        if let cached = getCachedArtwork(for: cacheKey) {
            track.artworkURL = cached
        } else if lastFMInstalled, let artURL = checkLastFMCurrentArtwork() {
            track.artworkURL = artURL
        }

        trackLock.lock()
        latestTrack = track
        trackLock.unlock()

        return track
    }

    /// Checks if LastFM has current artwork saved to disk.
    public func checkLastFMCurrentArtwork() -> URL? {
        guard let dir = lastFMSupportDirectory else { return nil }
        let artPath = dir.appendingPathComponent("current_art.jpg")
        return FileManager.default.fileExists(atPath: artPath.path) ? artPath : nil
    }

    /// Reads the latest track from LastFM's local scrobble stats if available.
    public func readLastFMStatus() -> AppleMusicTrack? {
        guard isLastFMInstalled(), let dir = lastFMSupportDirectory else { return nil }
        let statsFile = dir.appendingPathComponent("scrobble_stats.json")
        guard FileManager.default.fileExists(atPath: statsFile.path),
              let data = try? Data(contentsOf: statsFile),
              let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let lastEntry = jsonArray.last else {
            return nil
        }

        guard let trackName = lastEntry["track"] as? String,
              let artistName = lastEntry["artist"] as? String,
              !trackName.isEmpty, !artistName.isEmpty else {
            return nil
        }

        let albumName = lastEntry["album"] as? String ?? ""
        let isMusicRunning = isMusicAppRunning()

        let timestamp = (lastEntry["timestamp"] as? NSNumber)?.doubleValue ?? 0
        let date = Date(timeIntervalSinceReferenceDate: timestamp)
        let isRecent = abs(Date().timeIntervalSince(date)) < 300

        let playerState: AppleMusicTrack.PlayerState = (isMusicRunning && isRecent) ? .playing : .stopped

        var track = AppleMusicTrack(
            databaseID: 0,
            name: trackName,
            artist: artistName,
            album: albumName,
            duration: 180,
            position: 0,
            playerState: playerState,
            artworkURL: checkLastFMCurrentArtwork(),
            source: .lastFMApp,
            updatedAt: date
        )

        let cacheKey = "\(artistName.lowercased()):\(albumName.lowercased())"
        if let cached = getCachedArtwork(for: cacheKey) {
            track.artworkURL = cached
        }

        return track
    }

    /// Fetches the currently playing Apple Music track.
    public func getCurrentTrack() -> AppleMusicTrack? {
        trackLock.lock()
        defer { trackLock.unlock() }

        if let track = latestTrack {
            if !isMusicAppRunning() {
                latestTrack = nil
                return nil
            }
            return track
        }

        if isLastFMInstalled() {
            if let lastFMTrack = readLastFMStatus(), lastFMTrack.playerState.isPlaying {
                latestTrack = lastFMTrack
                return lastFMTrack
            }
        }

        return nil
    }

    /// Updates the position of the current track during playback.
    public func updatePlaybackPosition(elapsedDelta: TimeInterval) {
        trackLock.lock()
        defer { trackLock.unlock() }

        guard let track = latestTrack, track.playerState.isPlaying else { return }
        let newPos = track.duration > 0 ? min(track.duration, track.position + elapsedDelta) : (track.position + elapsedDelta)
        latestTrack = AppleMusicTrack(
            databaseID: track.databaseID,
            name: track.name,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            position: newPos,
            playerState: track.playerState,
            artworkURL: track.artworkURL,
            source: track.source,
            updatedAt: Date()
        )
    }

    private func getCachedArtwork(for key: String) -> URL? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return artworkCache[key]
    }

    private func setCachedArtwork(_ url: URL, for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        artworkCache[key] = url
    }

    /// Asynchronously resolves high-resolution artwork for the track from iTunes Search API.
    public func resolveArtwork(for track: AppleMusicTrack) async -> URL? {
        let cacheKey = "\(track.artist.lowercased()):\(track.album.lowercased())"
        if let cached = getCachedArtwork(for: cacheKey) {
            return cached
        }

        let term = "\(track.artist) \(track.name)"
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=5") else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: searchURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  !results.isEmpty else {
                return nil
            }

            var candidateArtURL: String?
            for result in results {
                let resArtist = (result["artistName"] as? String ?? "").lowercased()
                let artUrl = result["artworkUrl100"] as? String
                if resArtist.contains(track.artist.lowercased()) || track.artist.lowercased().contains(resArtist) {
                    candidateArtURL = artUrl
                    break
                }
            }

            if candidateArtURL == nil, let first = results.first {
                candidateArtURL = first["artworkUrl100"] as? String
            }

            if let rawArt = candidateArtURL {
                let highResStr = rawArt
                    .replacingOccurrences(of: "100x100bb.jpg", with: "512x512bb.jpg")
                    .replacingOccurrences(of: "60x60bb.jpg", with: "512x512bb.jpg")
                if let finalURL = URL(string: highResStr) {
                    setCachedArtwork(finalURL, for: cacheKey)
                    return finalURL
                }
            }
        } catch {
            // Non-critical network lookup failure
        }

        return nil
    }
}
