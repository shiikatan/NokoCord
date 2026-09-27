import Foundation
import AppKit

/// Detects what's currently playing in Apple Music via LastFM integration and native macOS distributed notifications.
public final class AppleMusicDetector: @unchecked Sendable {
    public static let shared = AppleMusicDetector()
    public static let musicBundleIdentifier = "com.apple.Music"

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
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleIdentifier).isEmpty
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
        }
        if let cachedArtist = getCachedArtwork(for: "artist:\(artist.lowercased())") {
            track.artistImageURL = cachedArtist
        }

        trackLock.lock()
        latestTrack = track
        trackLock.unlock()

        return track
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
            artworkURL: nil,
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

    /// Last.fm catalogue methods are public and read-only, so only the client
    /// key is used; the shared secret is never needed and never ships.
    public static let lastFMAPIKeyKey = "lastFMAPIKey"
    private static let defaultLastFMAPIKey = "12aa2b420edadc835c04e7e4a336ac52"

    public static var configuredLastFMAPIKey: String {
        let stored = (UserDefaults.standard.string(forKey: lastFMAPIKeyKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? defaultLastFMAPIKey : stored
    }

    /// Only image hosts NokoCord asks for are accepted, so a catalogue response
    /// can never point Discord at an arbitrary address.
    private static func acceptedImageURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return nil }
        let allowed = host.hasSuffix("mzstatic.com") || host.hasSuffix("fastly.net")
            || host.hasSuffix("dzcdn.net") || host.hasSuffix("deezer.com")
        return allowed ? url : nil
    }

    /// Resolves album artwork, preferring Last.fm's exact track-to-album match
    /// and falling back to the iTunes catalogue for albums it does not know.
    public func resolveArtwork(for track: AppleMusicTrack) async -> URL? {
        let cacheKey = "\(track.artist.lowercased()):\(track.album.lowercased())"
        if let cached = getCachedArtwork(for: cacheKey) {
            return cached
        }
        if let artwork = await lastFMAlbumArtwork(for: track) {
            setCachedArtwork(artwork, for: cacheKey)
            return artwork
        }
        if let artwork = await iTunesAlbumArtwork(for: track) {
            setCachedArtwork(artwork, for: cacheKey)
            return artwork
        }
        if let artwork = await deezerAlbumArtwork(for: track) {
            setCachedArtwork(artwork, for: cacheKey)
            return artwork
        }
        return nil
    }

    /// Deezer carries releases iTunes US often does not, so a strict album
    /// search by artist and album title closes the remaining gaps.
    private func deezerAlbumArtwork(for track: AppleMusicTrack) async -> URL? {
        let album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !album.isEmpty else { return nil }
        let query = "artist:\"\(track.artist)\" album:\"\(album)\""
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search/album?q=\(encoded)&limit=5") else {
            return nil
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["data"] as? [[String: Any]] else {
                return nil
            }
            let wantedArtist = track.artist.lowercased()
            for result in results {
                let resultArtist = ((result["artist"] as? [String: Any])?["name"] as? String ?? "").lowercased()
                guard resultArtist == wantedArtist else { continue }
                if let artwork = Self.acceptedImageURL(result["cover_big"] as? String ?? result["cover_xl"] as? String) {
                    return artwork
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    /// Album-scoped lookups are what keep the right cover on screen: a track
    /// lookup without the album resolves to whichever release Last.fm considers
    /// the track's main one, which is a different cover whenever a song appears
    /// on a single, an EP and an album.
    private func lastFMAlbumArtwork(for track: AppleMusicTrack) async -> URL? {
        let album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
        if !album.isEmpty {
            if let artwork = await lastFMArtwork(method: "album.getinfo",
                                                 params: ["artist": track.artist, "album": album],
                                                 imagePath: ["album", "image"]) {
                return artwork
            }
            if let artwork = await lastFMArtwork(method: "track.getinfo",
                                                 params: ["artist": track.artist, "track": track.name, "album": album],
                                                 imagePath: ["track", "album", "image"]) {
                return artwork
            }
        }
        return await lastFMArtwork(method: "track.getinfo",
                                   params: ["artist": track.artist, "track": track.name],
                                   imagePath: ["track", "album", "image"])
    }

    private func lastFMArtwork(method: String, params: [String: String], imagePath: [String]) async -> URL? {
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")
        components?.queryItems = [
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "api_key", value: Self.configuredLastFMAPIKey)
        ] + params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            var current: Any = json
            for key in imagePath {
                guard let dictionary = current as? [String: Any], let next = dictionary[key] else { return nil }
                current = next
            }
            guard let sizes = current as? [[String: Any]] else { return nil }
            let bySize = Dictionary(uniqueKeysWithValues: sizes.compactMap { entry -> (String, String)? in
                guard let size = entry["size"] as? String, let text = entry["#text"] as? String, !text.isEmpty else { return nil }
                return (size, text)
            })
            guard let raw = bySize["extralarge"] ?? bySize["mega"] ?? bySize["large"] else { return nil }
            // The catalogue path carries the pixel size; ask for a larger render
            // of the same image when the smaller one is what was returned.
            let larger = raw.replacingOccurrences(of: "/300x300/", with: "/600x600/")
            return Self.acceptedImageURL(larger) ?? Self.acceptedImageURL(raw)
        } catch {
            return nil
        }
    }

    /// iTunes knows albums Last.fm does not, so the album name is matched first
    /// and the artist has to agree, which avoids cover-alikes by other artists.
    private func iTunesAlbumArtwork(for track: AppleMusicTrack) async -> URL? {
        let wantedArtist = track.artist.lowercased()
        let wantedAlbum = track.album.lowercased()
        for (term, entity) in [("\(track.artist) \(track.album)", "album"), ("\(track.artist) \(track.name)", "song")] {
            guard !term.trimmingCharacters(in: .whitespaces).isEmpty,
                  let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let searchURL = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=\(entity)&limit=8") else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: searchURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]] else { continue }
                for result in results {
                    let resultArtist = (result["artistName"] as? String ?? "").lowercased()
                    guard resultArtist.contains(wantedArtist) || wantedArtist.contains(resultArtist) else { continue }
                    let albumName = (result["collectionName"] as? String ?? "").lowercased()
                    let trackName = (result["trackName"] as? String ?? "").lowercased()
                    let albumMatches = !wantedAlbum.isEmpty && albumName.contains(wantedAlbum)
                    let trackMatches = !trackName.isEmpty && trackName == track.name.lowercased()
                    guard albumMatches || trackMatches else { continue }
                    let raw = result["artworkUrl100"] as? String
                    let highResolution = raw?
                        .replacingOccurrences(of: "100x100bb.jpg", with: "512x512bb.jpg")
                        .replacingOccurrences(of: "60x60bb.jpg", with: "512x512bb.jpg")
                    if let artwork = Self.acceptedImageURL(highResolution) { return artwork }
                }
            } catch {
                continue
            }
        }
        return nil
    }

    /// Resolves the artist's profile image from Deezer's keyless public API.
    /// Only Deezer image hosts are accepted, so the URL handed to Discord can
    /// never come from an arbitrary response.
    public func resolveArtistImage(for track: AppleMusicTrack) async -> URL? {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else { return nil }
        let cacheKey = "artist:\(artist.lowercased())"
        if let cached = getCachedArtwork(for: cacheKey) {
            return cached
        }

        guard let encoded = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://api.deezer.com/search/artist?q=\(encoded)&limit=5") else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: searchURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["data"] as? [[String: Any]],
                  !results.isEmpty else {
                return nil
            }

            let wanted = artist.lowercased()
            let match = results.first { ($0["name"] as? String ?? "").lowercased() == wanted } ?? results[0]
            for key in ["picture_xl", "picture_big", "picture_medium"] {
                guard let artwork = Self.acceptedImageURL(match[key] as? String) else { continue }
                setCachedArtwork(artwork, for: cacheKey)
                return artwork
            }
        } catch {
            // Non-critical network lookup failure
        }

        return nil
    }
}
