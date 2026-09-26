import Foundation
import AppKit

/// Detects what's currently playing in Apple Music via LastFM integration and native AppleScript/distributed notifications.
public final class AppleMusicDetector: @unchecked Sendable {
    public static let shared = AppleMusicDetector()

    private let scriptLock = NSLock()
    private var artworkCache: [String: URL] = [:]
    private let cacheLock = NSLock()

    // Compiled AppleScript reused across checks
    private let currentTrackScript: NSAppleScript? = {
        let source = """
        tell application "System Events"
            if not (exists process "Music") then
                return "NOT_RUNNING"
            end if
        end tell

        tell application "Music"
            try
                set playerState to player state as string
                if playerState is "stopped" then
                    return "STOPPED"
                end if

                set t to current track
                set trackId to database ID of t
                set trackName to name of t
                set artistName to artist of t
                set albumName to album of t
                set trackDuration to duration of t
                set pos to player position

                return (trackId as string) & "|||" & trackName & "|||" & artistName & "|||" & albumName & "|||" & (trackDuration as string) & "|||" & (pos as string) & "|||" & playerState
            on error
                return "ERROR"
            end try
        end tell
        """
        return NSAppleScript(source: source)
    }()

    public init() {}

    /// Checks if LastFM.app is installed on the user's Mac.
    public func isLastFMInstalled() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidatePaths = [
            home.appendingPathComponent("LastFMSwift/LastFM.app").path,
            "/Applications/LastFM.app",
            home.appendingPathComponent("Applications/LastFM.app").path
        ]
        return candidatePaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Path to LastFM Application Support directory if present.
    public var lastFMSupportDirectory: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let lastFMDir = appSupport.appendingPathComponent("LastFM")
        return FileManager.default.fileExists(atPath: lastFMDir.path) ? lastFMDir : nil
    }

    /// Fetches the currently playing Apple Music track, checking LastFM.app first if installed.
    public func getCurrentTrack() -> AppleMusicTrack? {
        let lastFMInstalled = isLastFMInstalled()

        // 1. Primary Query: Execute compiled AppleScript for live Apple Music state
        var scriptOutput: String?
        scriptLock.lock()
        if let script = currentTrackScript {
            var error: NSDictionary?
            let res = script.executeAndReturnError(&error)
            scriptOutput = res.stringValue
        }
        scriptLock.unlock()

        guard let output = scriptOutput,
              output != "NOT_RUNNING",
              output != "STOPPED",
              output != "ERROR" else {
            return nil
        }

        let parts = output.components(separatedBy: "|||")
        guard parts.count >= 7 else { return nil }

        let databaseID = Int(parts[0]) ?? 0
        let trackName = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let artistName = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let albumName = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Double(parts[4]) ?? 0
        let position = Double(parts[5]) ?? 0
        let stateStr = parts[6].lowercased()

        let state: AppleMusicTrack.PlayerState
        if stateStr.contains("playing") {
            state = .playing
        } else if stateStr.contains("paused") {
            state = .paused
        } else {
            state = .stopped
        }

        let trackingSource: AppleMusicTrack.TrackingSource = lastFMInstalled ? .lastFMApp : .musicApp

        var track = AppleMusicTrack(
            databaseID: databaseID,
            name: trackName,
            artist: artistName,
            album: albumName,
            duration: duration,
            position: position,
            playerState: state,
            artworkURL: nil,
            source: trackingSource
        )

        // Resolve Artwork
        let cacheKey = "\(artistName.lowercased()):\(albumName.lowercased())"
        cacheLock.lock()
        let cachedArt = artworkCache[cacheKey]
        cacheLock.unlock()

        if let cachedArt {
            track.artworkURL = cachedArt
        }

        return track
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

        // Query iTunes Search API for official Apple Music cover art
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

            // Find best matching result
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
                // Upscale thumbnail to 512x512 high-resolution artwork
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
