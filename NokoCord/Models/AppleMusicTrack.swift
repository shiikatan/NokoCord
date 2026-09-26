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
    public let databaseID: Int
    public let name: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval     // in seconds
    public let position: TimeInterval     // in seconds
    public let playerState: PlayerState
    public var artworkURL: URL?
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
        self.source = source
        self.updatedAt = updatedAt
    }

    /// Calculates the estimated start time for Discord Rich Presence seeking bar.
    public var playbackStartTime: Date {
        Date().addingTimeInterval(-position)
    }

    /// Calculates the estimated end time for Discord Rich Presence seeking bar.
    public var playbackEndTime: Date {
        Date().addingTimeInterval(max(0, duration - position))
    }

    /// Formats progress as mm:ss / mm:ss
    public var formattedProgress: String {
        let posMin = Int(position) / 60
        let posSec = Int(position) % 60
        let durMin = Int(duration) / 60
        let durSec = Int(duration) % 60
        return String(format: "%02d:%02d / %02d:%02d", posMin, posSec, durMin, durSec)
    }

    /// Converts this track into Discord GamePresence with Listening activity type (type: 2).
    public func toGamePresence(clientId: String = "1038520842044874792") -> GamePresence {
        var buttons: [[String: String]] = []
        if let query = "\(artist) \(name)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            buttons.append([
                "label": "Listen on Apple Music",
                "url": "https://music.apple.com/search?term=\(query)"
            ])
        }

        return GamePresence(
            clientId: clientId,
            name: "Apple Music",
            details: name,
            state: "by \(artist)",
            type: 2, // 2 = Listening
            startTimestamp: playerState.isPlaying ? playbackStartTime : nil,
            endTimestamp: playerState.isPlaying ? playbackEndTime : nil,
            largeImageKey: artworkURL?.absoluteString ?? "apple_music",
            largeImageText: album.isEmpty ? name : album,
            smallImageKey: playerState.isPlaying ? "play" : "pause",
            smallImageText: playerState.isPlaying ? "Playing" : "Paused",
            buttons: buttons.isEmpty ? nil : buttons
        )
    }
}
