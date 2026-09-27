import AppKit
import XCTest
@testable import NokoCordCore

final class AppleMusicRPCTests: XCTestCase {
    private func track(state: AppleMusicTrack.PlayerState = .playing,
                       position: TimeInterval = 42,
                       duration: TimeInterval = 210,
                       artwork: URL? = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/512x512bb.jpg"),
                       artistImage: URL? = URL(string: "https://cdn-images.dzcdn.net/images/artist/abc/500x500.jpg")) -> AppleMusicTrack {
        AppleMusicTrack(databaseID: 77,
                        name: "Plastic Love",
                        artist: "Mariya Takeuchi",
                        album: "Variety",
                        duration: duration,
                        position: position,
                        playerState: state,
                        artworkURL: artwork,
                        artistImageURL: artistImage)
    }

    func testPlayingTrackMapsToListeningActivity() throws {
        let presence = track().toGamePresence()

        XCTAssertEqual(presence.clientId, AppleMusicTrack.discordApplicationID)
        XCTAssertEqual(presence.type, 2, "Apple Music presence must use the Listening activity type")
        XCTAssertEqual(presence.name, "Mariya Takeuchi", "The status line carries the artist")
        XCTAssertEqual(presence.details, "Plastic Love")
        XCTAssertEqual(presence.state, "Variety")
        XCTAssertEqual(presence.largeImageKey, "https://is1-ssl.mzstatic.com/image/thumb/512x512bb.jpg")
        XCTAssertEqual(presence.largeImageText, "Variety")
        XCTAssertEqual(presence.smallImageKey, "https://cdn-images.dzcdn.net/images/artist/abc/500x500.jpg")
        XCTAssertEqual(presence.smallImageText, "Mariya Takeuchi")
        XCTAssertNotNil(presence.startTimestamp)
        XCTAssertNotNil(presence.endTimestamp)
        XCTAssertEqual(presence.buttons?.first?["label"], "Listen on Apple Music")

        let payload = presence.toDiscordPayload()
        XCTAssertEqual(payload["application_id"] as? String, AppleMusicTrack.discordApplicationID)
        XCTAssertEqual(payload["type"] as? Int, 2)
        XCTAssertEqual(payload["name"] as? String, "Mariya Takeuchi")
        XCTAssertEqual(payload["details"] as? String, "Plastic Love")
        let timestamps = try XCTUnwrap(payload["timestamps"] as? [String: Any])
        XCTAssertNotNil(timestamps["start"])
        XCTAssertNotNil(timestamps["end"])
        let assets = try XCTUnwrap(payload["assets"] as? [String: Any])
        XCTAssertEqual(assets["small_image"] as? String, "https://cdn-images.dzcdn.net/images/artist/abc/500x500.jpg")
    }

    func testPresenceWithoutArtistImageOmitsTheSmallAsset() throws {
        let presence = track(artistImage: nil).toGamePresence()
        XCTAssertNil(presence.smallImageKey, "An unresolvable asset key must not be sent")
        let assets = try XCTUnwrap(presence.toDiscordPayload()["assets"] as? [String: Any])
        XCTAssertNil(assets["small_image"])
        XCTAssertNotNil(assets["large_image"])
    }

    func testPausedTrackOmitsPlaybackWindow() {
        let presence = track(state: .paused).toGamePresence()

        XCTAssertNil(presence.startTimestamp)
        XCTAssertNil(presence.endTimestamp)
        XCTAssertEqual(presence.smallImageKey, "https://cdn-images.dzcdn.net/images/artist/abc/500x500.jpg")
    }

    func testRepositioningReanchorsThePlaybackWindow() {
        let track = track(position: 10, duration: 200)
        XCTAssertEqual(track.currentPosition, 10, accuracy: 1.0)

        let moved = track.repositioned(to: 150)
        XCTAssertEqual(moved.position, 150, accuracy: 0.001)
        XCTAssertEqual(moved.currentPosition, 150, accuracy: 1.0)
        XCTAssertNotEqual(moved.id, "")
        XCTAssertEqual(moved.artistImageURL, track.artistImageURL)
        XCTAssertEqual(moved.playbackStartTime.timeIntervalSinceNow, -150, accuracy: 1.0)
        XCTAssertEqual(track.position, 10, accuracy: 0.001, "The original track is not mutated")
    }

    func testCurrentPositionFollowsPlaybackAndClampsToKnownDuration() {
        let playing = track(position: 10, duration: 200)
        XCTAssertGreaterThanOrEqual(playing.currentPosition, 10)
        XCTAssertLessThan(playing.currentPosition, 12)

        let finished = track(position: 200, duration: 200)
        XCTAssertEqual(finished.currentPosition, 200, accuracy: 0.001)

        let paused = track(state: .paused, position: 65, duration: 200)
        XCTAssertEqual(paused.currentPosition, 65, accuracy: 0.001)
        XCTAssertEqual(paused.formattedProgress, "01:05 / 03:20")
    }

    func testWatcherBroadcastBuildsTrackAndRejectsIncompletePayloads() throws {
        let track = try XCTUnwrap(AppleMusicTrack(watcherBroadcast: [
            "state": "playing",
            "name": "Plastic Love",
            "artist": "Mariya Takeuchi",
            "album": "Variety",
            "duration": 294.0,
            "position": 121.5,
            "databaseID": 77
        ]))

        XCTAssertEqual(track.name, "Plastic Love")
        XCTAssertEqual(track.artist, "Mariya Takeuchi")
        XCTAssertEqual(track.album, "Variety")
        XCTAssertEqual(track.duration, 294, accuracy: 0.001)
        XCTAssertEqual(track.position, 121.5, accuracy: 0.001)
        XCTAssertEqual(track.playerState, .playing)
        XCTAssertEqual(track.databaseID, 77)

        XCTAssertNil(AppleMusicTrack(watcherBroadcast: ["state": "playing", "name": "   "]))
        XCTAssertNil(AppleMusicTrack(watcherBroadcast: ["state": "playing"]))
        XCTAssertNil(AppleMusicTrack(watcherBroadcast: [:]))
    }

    func testPlayerNotificationParsingBuildsTrackMetadata() throws {
        _ = NSApplication.shared
        let detector = AppleMusicDetector()
        let info: [AnyHashable: Any] = [
            "Name": "Plastic Love",
            "Artist": "Mariya Takeuchi",
            "Album": "Variety",
            "Player State": "Playing",
            "Total Time": NSNumber(value: 294_000),
            "Elapsed Time": NSNumber(value: 42.5),
            "Database ID": NSNumber(value: 1234)
        ]

        let track = try XCTUnwrap(detector.handlePlayerNotification(info))
        XCTAssertEqual(track.name, "Plastic Love")
        XCTAssertEqual(track.artist, "Mariya Takeuchi")
        XCTAssertEqual(track.album, "Variety")
        XCTAssertEqual(track.duration, 294, accuracy: 0.001)
        XCTAssertEqual(track.position, 42.5, accuracy: 0.001)
        XCTAssertEqual(track.playerState, .playing)
        XCTAssertEqual(track.databaseID, 1234)

        let paused = try XCTUnwrap(detector.handlePlayerNotification(["Name": "Song", "Player State": "Paused"]))
        XCTAssertEqual(paused.playerState, .paused)
        XCTAssertEqual(paused.duration, 0, accuracy: 0.001)

        XCTAssertNil(detector.handlePlayerNotification(nil))
        XCTAssertNil(detector.handlePlayerNotification(["Name": "   ", "Artist": "Nobody"]))
    }
}
