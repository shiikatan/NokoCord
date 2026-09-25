import XCTest
@testable import NokoCordCore

final class CodeHighlighterTests: XCTestCase {
    func testHighlightPreservesUnicodeAndNewlinesExactly() {
        let source = "let greeting = \"hé 👋\"\r\n// café\n"

        let fragments = CodeHighlighter.highlight(source: source, language: "swift")

        XCTAssertEqual(fragments.map(\.text).joined(), source)
        XCTAssertTrue(fragments.contains { $0.kind == .keyword && $0.text == "let" })
        XCTAssertTrue(fragments.contains { $0.kind == .string && $0.text == "\"hé 👋\"" })
        XCTAssertTrue(fragments.contains { $0.kind == .comment && $0.text == "// café" })
    }

    func testEscapedStringContentsAreNotClassifiedAsKeywordsOrComments() {
        let source = #"""
let text = "return \"quoted\" // still a string"; // actual comment
let block = "/* also a string */"
"""#

        let fragments = CodeHighlighter.highlight(source: source, language: "swift")
        let strings = fragments.filter { $0.kind == .string }.map(\.text)
        let comments = fragments.filter { $0.kind == .comment }.map(\.text)

        XCTAssertEqual(fragments.map(\.text).joined(), source)
        XCTAssertEqual(strings, [#""return \"quoted\" // still a string""#, #""/* also a string */""#])
        XCTAssertEqual(comments, ["// actual comment"])
        XCTAssertFalse(fragments.contains { $0.kind == .keyword && ["return", "if"].contains($0.text) })
    }

    func testLineCommentEndsAtCarriageReturnBeforeFollowingCode() {
        let source = "// comment\r\nlet value = 1"

        let fragments = CodeHighlighter.highlight(source: source, language: "swift")

        XCTAssertEqual(fragments.map(\.text).joined(), source)
        XCTAssertEqual(fragments.filter { $0.kind == .comment }.map(\.text), ["// comment"])
        XCTAssertTrue(fragments.contains { $0.kind == .keyword && $0.text == "let" })
        XCTAssertTrue(fragments.contains { $0.kind == .number && $0.text == "1" })
    }

    func testMultilineAndUnterminatedBlockCommentsRemainComments() {
        let source = "/* first line\nlet hidden = 1\n*/\nlet visible = 2\n/* never closes\nreturn"

        let fragments = CodeHighlighter.highlight(source: source, language: "swift")

        XCTAssertEqual(fragments.map(\.text).joined(), source)
        XCTAssertEqual(fragments.filter { $0.kind == .comment }.map(\.text), ["/* first line\nlet hidden = 1\n*/", "/* never closes\nreturn"])
        XCTAssertTrue(fragments.contains { $0.kind == .keyword && $0.text == "let" })
        XCTAssertTrue(fragments.contains { $0.kind == .number && $0.text == "2" })
        XCTAssertFalse(fragments.contains { $0.kind == .keyword && $0.text == "return" })
    }

    func testUnknownAndNilLanguagesProduceOnePlaintextFragment() {
        let source = "αβ\n123 // symbols"

        for language in [String?.none, "made-up"] {
            let fragments = CodeHighlighter.highlight(source: source, language: language)

            XCTAssertEqual(fragments, [CodeHighlightFragment(text: source, kind: .plain)], "language: \(String(describing: language))")
        }
    }

    func testHighlightBoundsSourceAtMaximumCharacterCount() {
        let source = String(repeating: "a", count: CodeHighlighter.maximumSourceCharacters - 1) + "éTAIL"
        let expected = String(source.prefix(CodeHighlighter.maximumSourceCharacters))

        let fragments = CodeHighlighter.highlight(source: source, language: "unknown")

        XCTAssertEqual(fragments.map(\.text).joined(), expected)
        XCTAssertEqual(expected.count, CodeHighlighter.maximumSourceCharacters)
        XCTAssertFalse(fragments.map(\.text).joined().contains("TAIL"))
    }
}
