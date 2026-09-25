import Foundation
import XCTest
@testable import NokoCordCore

final class ChatTimestampScannerTests: XCTestCase {
    func testCodeEscapesAndLinksRemainLiteral() {
        let input = #"`<t:0>` \<t:0> [<t:0>](https://example.com/<t:0>) <t:0>"#
        let plan = ChatTimestampScanner.plan(input)
        XCTAssertEqual(plan.tokens.count, 1)
        XCTAssertTrue(plan.markdown.hasPrefix(#"`<t:0>` \<t:0> [<t:0>](https://example.com/<t:0>) "#))
    }

    func testTimestampRetainsSurroundingEmphasis() {
        let plan = ChatTimestampScanner.plan("**At <t:0:d>**")
        let text = plan.attributed(locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertTrue(String(text.characters).hasPrefix("At "))
        XCTAssertFalse(String(text.characters).contains("NOKOTIMESTAMP"))
        XCTAssertTrue(text.runs.allSatisfy { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    func testSubstitutionDoesNotTruncateTrailingText() {
        let input = String(repeating: "<t:0> ", count: 64) + String(repeating: "a", count: 30_000) + "TAIL"
        let plan = ChatTimestampScanner.plan(input)
        XCTAssertEqual(plan.tokens.count, 64)
        XCTAssertTrue(String(plan.attributed().characters).hasSuffix("TAIL"))
    }

    func testMalformedAndUnsupportedMarkupRemainsUnchanged() {
        let input = "<t:nope> <t:0:x> <t:999999999999999999999999>"
        let plan = ChatTimestampScanner.plan(input)
        XCTAssertTrue(plan.tokens.isEmpty)
        XCTAssertEqual(plan.markdown, input)
    }
}
