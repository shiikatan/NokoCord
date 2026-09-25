import XCTest
import Foundation

final class GamePresenceTests: XCTestCase {
    func testGamePresenceSerialization() {
        let presence = GamePresence(
            clientId: "1234567890",
            pid: 4321,
            name: "Hollow Knight: Silksong",
            details: "Exploring Pharloom",
            state: "Moss Grotto",
            startTimestamp: Date(timeIntervalSince1970: 1700000000),
            largeImageKey: "pharloom_map",
            largeImageText: "Pharloom",
            smallImageKey: "hornet_icon",
            smallImageText: "Hornet"
        )

        let payload = presence.toDiscordPayload()

        XCTAssertEqual(payload["application_id"] as? String, "1234567890")
        XCTAssertEqual(payload["name"] as? String, "Hollow Knight: Silksong")
        XCTAssertEqual(payload["type"] as? Int, 0)
        XCTAssertEqual(payload["details"] as? String, "Exploring Pharloom")
        XCTAssertEqual(payload["state"] as? String, "Moss Grotto")

        let timestamps = payload["timestamps"] as? [String: Any]
        XCTAssertNotNil(timestamps)
        XCTAssertEqual(timestamps?["start"] as? Int, 1700000000 * 1000)

        let assets = payload["assets"] as? [String: Any]
        XCTAssertNotNil(assets)
        XCTAssertEqual(assets?["large_image"] as? String, "pharloom_map")
        XCTAssertEqual(assets?["large_text"] as? String, "Pharloom")
        XCTAssertEqual(assets?["small_image"] as? String, "hornet_icon")
        XCTAssertEqual(assets?["small_text"] as? String, "Hornet")
    }

    func testGamePresenceEquality() {
        let now = Date()
        let p1 = GamePresence(clientId: "123", name: "Game A", details: "Playing", startTimestamp: now)
        let p2 = GamePresence(clientId: "123", name: "Game A", details: "Playing", startTimestamp: now)
        let p3 = GamePresence(clientId: "456", name: "Game B", details: "Playing", startTimestamp: now)

        XCTAssertEqual(p1, p2)
        XCTAssertNotEqual(p1, p3)
    }

    func testGamePresenceJSONSerialization() throws {
        let presence = GamePresence(
            clientId: "999",
            name: "Cyberpunk 2077",
            details: "Night City"
        )
        let payload = presence.toDiscordPayload()
        let data = try JSONSerialization.data(withJSONObject: payload)
        let string = String(data: data, encoding: .utf8)

        XCTAssertNotNil(string)
        XCTAssertTrue(string!.contains("Cyberpunk 2077"))
        XCTAssertTrue(string!.contains("Night City"))
    }
}
