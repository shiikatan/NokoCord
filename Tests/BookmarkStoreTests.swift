import Foundation
import XCTest
@testable import NokoCordCore

@MainActor
final class BookmarkStoreTests: XCTestCase {
    func testFailedPersistenceDoesNotClaimBookmarkWasSaved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BookmarkStore(fileURL: directory)
        let saved = store.add(
            messageId: "message-1",
            authorName: "Ava",
            channelName: "general",
            serverName: "Noko",
            content: "A saved message",
            messageURL: "https://discord.com/channels/1/2/3"
        )

        XCTAssertFalse(saved)
        XCTAssertTrue(store.bookmarks.isEmpty)
        XCTAssertNotNil(store.error)
    }

    func testRestorePersistsAnExistingBookmarkAfterADelete() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = BookmarkStore(fileURL: file)
        let bookmark = NokoBookmark(
            messageId: "message-1",
            authorName: "Ava",
            channelName: "general",
            serverName: "Noko",
            content: "A saved message",
            messageURL: "https://discord.com/channels/1/2/3"
        )

        XCTAssertTrue(store.restore(bookmark))
        XCTAssertTrue(store.remove(id: bookmark.id))
        XCTAssertTrue(store.restore(bookmark))

        let reloaded = BookmarkStore(fileURL: file)
        XCTAssertEqual(reloaded.bookmarks, [bookmark])
        XCTAssertNil(reloaded.error)
    }
}
