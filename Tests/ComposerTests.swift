import XCTest
@testable import NokoCordCore

final class ComposerTests: XCTestCase {
    func testUnavailableCannotSend() {
        var state = ComposerState()

        if case .success = state.beginSending("hello", maxCharacters: 100) { XCTFail("Unavailable composer sent text") }
        XCTAssertEqual(state.sendState, .idle)
    }

    func testReadOnlyCannotSend() {
        var state = ComposerState(availability: .readOnly(reason: "Read only"))

        if case .success = state.beginSending("hello", maxCharacters: 100) { XCTFail("Read only composer sent text") }
        XCTAssertEqual(state.sendState, .idle)
    }

    func testBlankAndTooLongTextAreRejected() {
        var state = ComposerState(availability: .ready)

        if case .success = state.beginSending(" \n ", maxCharacters: 100) { XCTFail("Blank text was accepted") }
        if case .failure(.tooLong(limit: 3)) = state.beginSending("four", maxCharacters: 3) {} else { XCTFail("Overlong text was accepted") }
    }

    func testBusyComposerCannotStartSecondSend() {
        var state = ComposerState(availability: .ready)
        if case .success("first") = state.beginSending("first", maxCharacters: 100) {} else { XCTFail("Initial send was rejected") }

        if case .failure(.busy) = state.beginSending("second", maxCharacters: 100) {} else { XCTFail("Busy composer started another send") }
    }

    func testFailurePreservesFailedStateAndCancellationReturnsIdle() {
        var state = ComposerState(availability: .ready)
        _ = state.beginSending("hello", maxCharacters: 100)
        state.finish(.failure(TestError.failed))
        if case .failed(let reason) = state.sendState { XCTAssertEqual(reason, TestError.failed.localizedDescription) } else { XCTFail("Failure was not surfaced") }

        state.finish(.failure(CancellationError()))
        XCTAssertEqual(state.sendState, .idle)
    }

    func testSuccessfulSendOnlyClearsUnchangedDraft() {
        XCTAssertEqual(ComposerState.draftAfterSuccessfulSend(submittedText: "hello", currentText: "hello"), "")
        XCTAssertEqual(ComposerState.draftAfterSuccessfulSend(submittedText: "hello", currentText: "newer draft"), "newer draft")
    }

    private enum TestError: Error { case failed }
}
