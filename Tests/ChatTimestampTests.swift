import Foundation
import XCTest
@testable import NokoCordCore

final class ChatTimestampTests: XCTestCase {
    private let locale = Locale(identifier: "en_US_POSIX")
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let fixtureDate = Date(timeIntervalSince1970: 1_789_776_000) // 2026-09-21 12:00:00 UTC

    func testParsesDefaultAndEverySupportedStyle() {
        XCTAssertEqual(ChatTimestamp.parse("<t:1789776000>"), ChatTimestamp(date: fixtureDate, style: "f"))
        for style in ["t", "T", "d", "D", "f", "F", "s", "S", "R"] {
            XCTAssertEqual(ChatTimestamp.parse("<t:1789776000:\(style)>")?.style, style)
        }
    }

    func testRejectsMalformedUnsupportedAndOversizedMarkup() {
        let invalid = ["", "t:1789776000", "<T:1789776000>", "<t:>", "<t:-:R>", "<t:+1:R>", "<t:1.5:R>", "<t:1:x>", "<t:1:R:extra>", "<t:١:R>"]
        for markup in invalid { XCTAssertNil(ChatTimestamp.parse(markup), markup) }
        XCTAssertNil(ChatTimestamp.parse("<t:\(String(repeating: "9", count: 35)):R>"))
    }

    func testRejectsDatesOutsideFoundationDisplayYearRange() {
        XCTAssertNil(ChatTimestamp.parse("<t:-62135596801:R>")) // before Gregorian year 1
        XCTAssertNil(ChatTimestamp.parse("<t:253402300800:R>")) // after Gregorian year 9999
    }

    func testFormattingUsesInjectedLocaleAndTimeZone() {
        let timestamp = ChatTimestamp.parse("<t:1789776000:f>")!
        let utcText = timestamp.format(now: fixtureDate, locale: locale, timeZone: utc)
        let easternText = timestamp.format(now: fixtureDate, locale: locale, timeZone: TimeZone(secondsFromGMT: -18_000)!)
        let frenchText = timestamp.format(now: fixtureDate, locale: Locale(identifier: "fr_FR"), timeZone: utc)
        XCTAssertNotEqual(utcText, easternText)
        XCTAssertNotEqual(utcText, frenchText)
        XCTAssertFalse(utcText.isEmpty)
    }

    func testRelativeFormattingDistinguishesPastAndFuture() {
        let past = ChatTimestamp(date: fixtureDate.addingTimeInterval(-120), style: "R")
        let future = ChatTimestamp(date: fixtureDate.addingTimeInterval(120), style: "R")
        let pastText = past.format(now: fixtureDate, locale: locale, timeZone: utc)
        let futureText = future.format(now: fixtureDate, locale: locale, timeZone: utc)
        XCTAssertNotEqual(pastText, futureText)
        XCTAssertTrue(pastText.contains("ago"))
        XCTAssertTrue(futureText.contains("in"))
    }
}
