import Foundation
import XCTest
@testable import NokoCordCore

final class NokoMusicWatchTests: XCTestCase {
    func testHelperPayloadCarriesSequenceAndEventTimestamp() throws {
        let timestamp = Date(timeIntervalSince1970: 1_234)
        let payload = try XCTUnwrap(AppleMusicWatcherPayload(userInfo: [
            "state": "playing",
            "sequence": NSNumber(value: 7),
            "eventTimestamp": timestamp.timeIntervalSince1970
        ]))

        XCTAssertEqual(payload.state, .playing)
        XCTAssertEqual(payload.sequence, 7)
        XCTAssertEqual(payload.timestamp, timestamp)
    }

    func testHelperPayloadRejectsUnknownStatesAndInvalidTimestamps() {
        XCTAssertNil(AppleMusicWatcherPayload(userInfo: ["state": "mystery"]))
        XCTAssertNil(AppleMusicWatcherPayload(userInfo: ["state": "playing", "eventTimestamp": .infinity]))
    }

    func testHelperFailureStatesRemainObservable() throws {
        let denied = try XCTUnwrap(AppleMusicWatcherPayload(userInfo: ["state": "denied"]))
        let unavailable = try XCTUnwrap(AppleMusicWatcherPayload(userInfo: ["state": "unavailable"]))
        let unsupported = try XCTUnwrap(AppleMusicWatcherPayload(userInfo: ["state": "unsupported"]))

        XCTAssertEqual(denied.state, .denied)
        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertEqual(unsupported.state, .unsupported)
    }
}
