import Foundation

struct ChatAttachment: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let filename: String
    let url: URL?
    let size: Int?
    init(id: String = UUID().uuidString, filename: String, url: URL? = nil, size: Int? = nil) {
        self.id = id; self.filename = filename; self.url = url; self.size = size
    }
}

struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let authorID: String
    let authorName: String
    let date: Date
    let text: String
    let isEdited: Bool
    let replyTo: String?
    let attachments: [ChatAttachment]
    var isSystem: Bool { authorID.isEmpty }

    init(id: String = UUID().uuidString, authorID: String, authorName: String, date: Date,
         text: String, isEdited: Bool = false, replyTo: String? = nil,
         attachments: [ChatAttachment] = []) {
        self.id = id; self.authorID = authorID; self.authorName = authorName; self.date = date
        self.text = text; self.isEdited = isEdited; self.replyTo = replyTo; self.attachments = attachments
    }
}

struct ChatMessageRow: Identifiable, Equatable, Sendable {
    let message: ChatMessage
    let isGrouped: Bool
    let isDateBreak: Bool
    var id: String { message.id }
}

extension Array where Element == ChatMessage {
    func groupedRows(calendar: Calendar = .current) -> [ChatMessageRow] {
        enumerated().map { index, message in
            guard index > 0 else { return ChatMessageRow(message: message, isGrouped: false, isDateBreak: true) }
            let previous = self[index - 1]
            let sameDay = calendar.isDate(message.date, inSameDayAs: previous.date)
            let interval = message.date.timeIntervalSince(previous.date)
            let eligible = !message.isSystem && !previous.isSystem
                && message.authorID == previous.authorID
                && message.replyTo == nil && previous.replyTo == nil
                && sameDay && interval >= 0 && interval <= 300
            return ChatMessageRow(message: message, isGrouped: eligible, isDateBreak: !sameDay)
        }
    }
}

enum ChatMarkdownBlock: Equatable, Sendable {
    case text(String)
    case code(language: String?, source: String)
    case heading(level: Int, text: String)
    case quote(String)
    case listItem(marker: String, text: String)
}

enum ChatMarkdownParser {
    static let maxInputLength = 32_000

    static func blocks(_ input: String) -> [ChatMarkdownBlock] {
        let bounded = String(input.prefix(maxInputLength))
        var result: [ChatMarkdownBlock] = [], text = "", code: String?, lines: [String] = [], inCode = false
        for line in bounded.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("```") {
                if inCode { result.append(.code(language: code, source: lines.joined(separator: "\n"))); code = nil; lines = []; inCode = false }
                else { if !text.isEmpty { result.append(.text(text)); text = "" }; code = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces); inCode = true }
            } else if inCode { lines.append(line) }
            else if let block = structuredLine(line) {
                if !text.isEmpty { result.append(.text(text)); text = "" }
                result.append(block)
            }
            else { if !text.isEmpty { text += "\n" }; text += line }
        }
        if inCode { result.append(.code(language: code, source: lines.joined(separator: "\n"))) }
        else if !text.isEmpty { result.append(.text(text)) }
        return result
    }

    private static func structuredLine(_ line: String) -> ChatMarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        if (1...3).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") {
            return .heading(level: hashes, text: String(line.dropFirst(hashes + 1)))
        }
        if line.hasPrefix("> ") { return .quote(String(line.dropFirst(2))) }
        let trimmed = line.drop(while: { $0 == " " })
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return .listItem(marker: "•", text: String(trimmed.dropFirst(2)))
        }
        let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty, digits.count <= 9, trimmed.dropFirst(digits.count).hasPrefix(". ") {
            return .listItem(marker: String(digits) + ".", text: String(trimmed.dropFirst(digits.count + 2)))
        }
        return nil
    }

    static func allowedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil,
              url.user == nil, url.password == nil else { return false }
        return true
    }

    static func inline(_ input: String, limit: Int = maxInputLength) -> AttributedString {
        let bounded = String(input.prefix(min(max(0, limit), maxInputLength + 8192)))
        var attributed = (try? AttributedString(markdown: bounded, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(bounded)
        let unsafeRanges = attributed.runs.compactMap { run in
            run.link.map { allowedURL($0) ? nil : run.range } ?? nil
        }
        for range in unsafeRanges { attributed[range].link = nil }
        return attributed
    }
}
