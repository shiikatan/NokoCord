import Foundation
import Observation

/// Represents a bookmarked Discord message saved locally in NokoCord.
public struct NokoBookmark: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let messageId: String
    public let authorName: String
    public let authorAvatarURL: String?
    public let channelName: String
    public let serverName: String
    public let content: String
    public let mediaURL: String?
    public let messageURL: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        messageId: String,
        authorName: String,
        authorAvatarURL: String? = nil,
        channelName: String,
        serverName: String,
        content: String,
        mediaURL: String? = nil,
        messageURL: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.messageId = messageId
        self.authorName = authorName
        self.authorAvatarURL = authorAvatarURL
        self.channelName = channelName
        self.serverName = serverName
        self.content = content
        self.mediaURL = mediaURL
        self.messageURL = messageURL
        self.createdAt = createdAt
    }
}

/// Thread-safe local storage for private bookmarked messages.
/// Persisted locally in `~/Library/Application Support/NokoCord/bookmarks.json`.
/// Zero telemetry, zero external network requests, zero Discord API modifications.
@MainActor @Observable
public final class BookmarkStore {
    public static let shared = BookmarkStore()

    public private(set) var bookmarks: [NokoBookmark] = []
    public private(set) var error: String?
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("NokoCord", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("bookmarks.json")
        }
        load()
    }

    @discardableResult
    public func add(
        messageId: String,
        authorName: String,
        authorAvatarURL: String? = nil,
        channelName: String,
        serverName: String,
        content: String,
        mediaURL: String? = nil,
        messageURL: String
    ) -> Bool {
        var updated = bookmarks
        // Prevent duplicate bookmarks for the exact same message
        if let index = updated.firstIndex(where: { $0.messageId == messageId }) {
            updated[index] = NokoBookmark(
                id: updated[index].id,
                messageId: messageId,
                authorName: authorName,
                authorAvatarURL: authorAvatarURL,
                channelName: channelName,
                serverName: serverName,
                content: content,
                mediaURL: mediaURL,
                messageURL: messageURL,
                createdAt: Date()
            )
        } else {
            let newBookmark = NokoBookmark(
                messageId: messageId,
                authorName: authorName,
                authorAvatarURL: authorAvatarURL,
                channelName: channelName,
                serverName: serverName,
                content: content,
                mediaURL: mediaURL,
                messageURL: messageURL
            )
            updated.insert(newBookmark, at: 0)
        }
        guard persist(updated) else { return false }
        bookmarks = updated
        return true
    }

    @discardableResult
    public func remove(id: String) -> Bool {
        guard bookmarks.contains(where: { $0.id == id }) else { return false }
        var updated = bookmarks
        updated.removeAll(where: { $0.id == id })
        guard persist(updated) else { return false }
        bookmarks = updated
        return true
    }

    @discardableResult
    public func remove(messageId: String) -> Bool {
        guard bookmarks.contains(where: { $0.messageId == messageId }) else { return false }
        var updated = bookmarks
        updated.removeAll(where: { $0.messageId == messageId })
        guard persist(updated) else { return false }
        bookmarks = updated
        return true
    }

    @discardableResult
    public func restore(_ bookmark: NokoBookmark) -> Bool {
        var updated = bookmarks
        if let index = updated.firstIndex(where: { $0.id == bookmark.id }) {
            updated[index] = bookmark
        } else if let index = updated.firstIndex(where: { $0.messageId == bookmark.messageId }) {
            updated[index] = bookmark
        } else {
            updated.insert(bookmark, at: 0)
        }
        guard persist(updated) else { return false }
        bookmarks = updated
        return true
    }

    public func isBookmarked(messageId: String) -> Bool {
        bookmarks.contains(where: { $0.messageId == messageId })
    }

    public func search(query: String) -> [NokoBookmark] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return bookmarks }
        return bookmarks.filter {
            $0.content.lowercased().contains(q) ||
            $0.authorName.lowercased().contains(q) ||
            $0.channelName.lowercased().contains(q) ||
            $0.serverName.lowercased().contains(q)
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            bookmarks = try decoder.decode([NokoBookmark].self, from: data)
        } catch {
            bookmarks = []
            self.error = String(localized: "Saved messages could not be loaded. New bookmarks will replace the damaged file.")
        }
    }

    private func persist(_ updated: [NokoBookmark]) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(updated)
            try data.write(to: fileURL, options: .atomic)
            error = nil
            return true
        } catch {
            self.error = String(localized: "Saved messages could not be saved. Check available storage and try again.")
            return false
        }
    }
}
