import Foundation

/// Models the playback status and metadata of the currently playing Apple Music track.
public struct AppleMusicTrack: Equatable, Sendable, Identifiable {
    public enum PlayerState: String, Sendable {
        case playing
        case paused
        case stopped
        case notRunning = "not_running"

        public var isPlaying: Bool {
            self == .playing
        }
    }

    public enum TrackingSource: String, Sendable {
        case lastFMApp = "LastFM.app"
        case lastFMLog = "LastFM Log"
        case musicApp = "Apple Music"
        case distributedNotification = "macOS Media Notification"
    }

    public var id: String { "\(artist):\(name):\(album)" }
    /// Discord application whose name and assets label the listening activity.
    /// Overridable from Settings → Music RPC without a rebuild.
    public static let discordApplicationID = "1535776441357303848"
    public let databaseID: Int
    public let name: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval     // in seconds
    public let position: TimeInterval     // in seconds
    public let playerState: PlayerState
    public var artworkURL: URL?
    public var artistImageURL: URL?
    public let source: TrackingSource
    public let updatedAt: Date

    public init(
        databaseID: Int = 0,
        name: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        position: TimeInterval,
        playerState: PlayerState,
        artworkURL: URL? = nil,
        artistImageURL: URL? = nil,
        source: TrackingSource = .musicApp,
        updatedAt: Date = Date()
    ) {
        self.databaseID = databaseID
        self.name = name
        self.artist = artist
        self.album = album
        self.duration = duration
        self.position = position
        self.playerState = playerState
        self.artworkURL = artworkURL
        self.artistImageURL = artistImageURL
        self.source = source
        self.updatedAt = updatedAt
    }

    /// Builds a track from a NokoMusicWatch broadcast. Returns nil when the
    /// payload does not describe a playable track.
    public init?(watcherBroadcast userInfo: [AnyHashable: Any]?) {
        guard let name = (userInfo?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        let duration = (userInfo?["duration"] as? NSNumber)?.doubleValue ?? 0
        self.init(databaseID: (userInfo?["databaseID"] as? NSNumber)?.intValue ?? 0,
                  name: name,
                  artist: (userInfo?["artist"] as? String) ?? "",
                  album: (userInfo?["album"] as? String) ?? "",
                  duration: max(0, duration),
                  position: max(0, (userInfo?["position"] as? NSNumber)?.doubleValue ?? 0),
                  playerState: .playing,
                  artworkURL: nil,
                  artistImageURL: nil,
                  source: .musicApp,
                  updatedAt: Date())
    }

    /// Calculates the estimated start time for Discord Rich Presence seeking bar.
    public var playbackStartTime: Date {
        Date().addingTimeInterval(-position)
    }

    /// Calculates the estimated end time for Discord Rich Presence seeking bar.
    public var playbackEndTime: Date {
        Date().addingTimeInterval(max(0, duration - position))
    }

    /// Position advanced by the wall clock since the last reported playback state.
    public var currentPosition: TimeInterval {
        guard playerState.isPlaying else { return position }
        let elapsed = max(0, Date().timeIntervalSince(playbackStartTime))
        return duration > 0 ? min(duration, elapsed) : elapsed
    }

    /// Returns a copy whose playback window is re-anchored to a position read
    /// from the player itself, so seeks and clock drift stay accurate.
    public func repositioned(to newPosition: TimeInterval) -> AppleMusicTrack {
        AppleMusicTrack(databaseID: databaseID,
                        name: name,
                        artist: artist,
                        album: album,
                        duration: duration,
                        position: max(0, newPosition),
                        playerState: playerState,
                        artworkURL: artworkURL,
                        artistImageURL: artistImageURL,
                        source: source,
                        updatedAt: Date())
    }

    /// Formats progress as mm:ss / mm:ss
    public var formattedProgress: String {
        let posMin = Int(currentPosition) / 60
        let posSec = Int(currentPosition) % 60
        let durMin = Int(duration) / 60
        let durSec = Int(duration) % 60
        return String(format: "%02d:%02d / %02d:%02d", posMin, posSec, durMin, durSec)
    }

    /// Converts this track into Discord GamePresence with Listening activity type (type: 2).
    ///
    /// Discord renders the activity name as the status line ("Listening to …"),
    /// so it carries the artist, with the song and album on the two detail
    /// lines. Album art and the artist's image are external URLs, because an
    /// activity whose application is not registered cannot resolve asset keys.
    public func toGamePresence(clientId: String = AppleMusicTrack.discordApplicationID) -> GamePresence {
        var buttons: [[String: String]] = []
        if let query = "\(artist) \(name)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            buttons.append([
                "label": "Listen on Apple Music",
                "url": "https://music.apple.com/search?term=\(query)"
            ])
        }

        return GamePresence(
            clientId: clientId,
            name: artist.isEmpty ? "Apple Music" : artist,
            details: name,
            state: album.isEmpty ? "by \(artist)" : album,
            type: 2, // 2 = Listening
            startTimestamp: playerState.isPlaying ? Date().addingTimeInterval(-currentPosition) : nil,
            endTimestamp: playerState.isPlaying && duration > 0 ? Date().addingTimeInterval(max(0, duration - currentPosition)) : nil,
            largeImageKey: artworkURL?.absoluteString,
            largeImageText: album.isEmpty ? name : album,
            smallImageKey: artistImageURL?.absoluteString,
            smallImageText: artist.isEmpty ? nil : artist,
            buttons: buttons.isEmpty ? nil : buttons
        )
    }
}
