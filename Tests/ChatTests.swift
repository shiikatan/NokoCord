import Foundation
import XCTest
@testable import NokoCordCore

final class ChatTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ minute: Int, day: Int = 1) -> Date {
        calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 9, day: day, hour: 12, minute: minute))!
    }

    private func message(_ id: String, author: String = "ava", minute: Int, day: Int = 1, replyTo: String? = nil, text: String = "hello") -> ChatMessage {
        ChatMessage(id: id, authorID: author.isEmpty ? "" : author + "-id", authorName: author, date: date(minute, day: day), text: text, replyTo: replyTo)
    }

    func testConsecutiveMessagesBySameAuthorWithinFiveMinutesAreGrouped() {
        let rows = [message("a", minute: 0), message("b", minute: 4)].groupedRows(calendar: calendar)

        XCTAssertFalse(rows[0].isGrouped)
        XCTAssertTrue(rows[1].isGrouped)
    }

    func testGroupingStopsAfterFiveMinutesOrCalendarDay() {
        let rows = [message("a", minute: 0), message("b", minute: 6), message("c", minute: 7, day: 2)].groupedRows(calendar: calendar)

        XCTAssertEqual(rows.map(\.isGrouped), [false, false, false])
    }

    func testDifferentAuthorsAreNeverGrouped() {
        let rows = [message("a", author: "ava", minute: 0), message("b", author: "bo", minute: 1)].groupedRows(calendar: calendar)

        XCTAssertEqual(rows.map(\.isGrouped), [false, false])
    }

    func testRepliesAlwaysStartTheirOwnMessageGroup() {
        let rows = [message("a", minute: 0), message("b", minute: 1, replyTo: "earlier"), message("c", minute: 2)].groupedRows(calendar: calendar)

        XCTAssertEqual(rows.map(\.isGrouped), [false, false, false])
    }

    func testSystemMessagesAlwaysStartTheirOwnMessageGroup() {
        let rows = [message("a", minute: 0), message("system", author: "", minute: 1, text: "A member joined"), message("b", minute: 2)].groupedRows(calendar: calendar)

        XCTAssertEqual(rows.map(\.isGrouped), [false, false, false])
    }

    func testFencedCodeSpoilersAndMaskedLinkFixtureRemainDistinct() throws {
        let fixture = """
        Before **bold** text.
        ```swift
        let answer = 42
        ```
        ||hidden detail|| [masked link](https://example.com/docs)
        """
        let blocks = ChatMarkdownParser.blocks(fixture)
        XCTAssertEqual(blocks, [.text("Before **bold** text."), .code(language: "swift", source: "let answer = 42"), .text("||hidden detail|| [masked link](https://example.com/docs)")])
        XCTAssertTrue(ChatMarkdownParser.inline("[masked link](https://example.com/docs)").link != nil)
        XCTAssertNil(ChatMarkdownParser.inline("[unsafe](javascript:alert(1))").link)
    }

    func testOnlyHTTPAndHTTPSLinksAreAccepted() {
        let candidates = ["https://example.com", "http://localhost:8080", "javascript:alert(1)", "file:///tmp/private"]
        let accepted = candidates.compactMap(URL.init(string:)).filter(ChatMarkdownParser.allowedURL)

        XCTAssertEqual(accepted.map(\.scheme), ["https", "http"])
    }

    func testStructuredMarkdownDoesNotInterpretInsideCode() {
        let source = "# Heading\n> quote\n- first\n2. second\n```\n# literal\n```"
        XCTAssertEqual(ChatMarkdownParser.blocks(source), [
            .heading(level: 1, text: "Heading"), .quote("quote"),
            .listItem(marker: "•", text: "first"), .listItem(marker: "2.", text: "second"),
            .code(language: "", source: "# literal")
        ])
        XCTAssertEqual(ChatMarkdownParser.blocks("#channel\n3.14"), [.text("#channel\n3.14")])
    }

    func testMessageAndAttachmentRoundTrip() throws {
        let original = message("message", minute: 3, text: "See file").addingAttachment(ChatAttachment(id: "attachment", filename: "notes.txt", size: 12))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.attachments.first?.filename, "notes.txt")
    }
}

private extension ChatMessage {
    func addingAttachment(_ attachment: ChatAttachment) -> ChatMessage {
        ChatMessage(id: id, authorID: authorID, authorName: authorName, date: date, text: text, isEdited: isEdited, replyTo: replyTo, attachments: attachments + [attachment])
    }
}
