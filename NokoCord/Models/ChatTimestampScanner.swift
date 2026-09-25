import Foundation

/// Replaces only standalone timestamp markup. Code, escaped text and Markdown
/// link labels/destinations remain untouched. Rendering keeps Markdown attributes.
struct ChatTimestampPlan {
    struct Token {
        let marker: String
        let timestamp: ChatTimestamp
    }
    let markdown: String
    let tokens: [Token]
    var hasRelativeTime: Bool { tokens.contains { $0.timestamp.style == "R" } }

    func attributed(now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> AttributedString {
        var result = ChatMarkdownParser.inline(markdown, limit: ChatMarkdownParser.maxInputLength + 8192)
        for token in tokens {
            guard let range = result.range(of: token.marker) else { continue }
            var replacement = AttributedString(token.timestamp.format(now: now, locale: locale, timeZone: timeZone))
            if let attributes = result[range].runs.first?.attributes { replacement.setAttributes(attributes) }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

enum ChatTimestampScanner {
    static func plan(_ source: String) -> ChatTimestampPlan {
        let bounded = String(source.prefix(ChatMarkdownParser.maxInputLength))
        guard bounded.contains("<t:") else { return ChatTimestampPlan(markdown: bounded, tokens: []) }
        let characters = Array(bounded)
        let prefix = "NOKOTIMESTAMP" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var output = "", plainStart = 0, index = 0, codeDelimiter = 0, brackets = 0, destination = 0
        var tokens: [ChatTimestampPlan.Token] = []
        while index < characters.count && tokens.count < 64 {
            let character = characters[index]
            if character == "\\" { index = min(index + 2, characters.count); continue }
            if character == "`" {
                let start = index
                while index < characters.count && characters[index] == "`" { index += 1 }
                let count = index - start
                if codeDelimiter == 0 { codeDelimiter = count }
                else if codeDelimiter == count { codeDelimiter = 0 }
                continue
            }
            if codeDelimiter != 0 { index += 1; continue }
            if destination > 0 {
                if character == "(" { destination += 1 }
                if character == ")" { destination -= 1 }
                index += 1; continue
            }
            if character == "[" { brackets += 1 }
            if character == "]" && brackets > 0 {
                brackets -= 1
                if index + 1 < characters.count && characters[index + 1] == "(" {
                    destination = 1; index += 2; continue
                }
            }
            if brackets == 0, character == "<", index + 3 < characters.count,
               characters[index + 1] == "t", characters[index + 2] == ":" {
                let end = min(index + 40, characters.count)
                if let close = (index..<end).first(where: { characters[$0] == ">" }),
                   let timestamp = ChatTimestamp.parse(String(characters[index...close])) {
                    output += String(characters[plainStart..<index])
                    let marker = prefix + "TOKEN" + String(tokens.count) + "END"
                    output += marker
                    tokens.append(.init(marker: marker, timestamp: timestamp))
                    index = close + 1; plainStart = index; continue
                }
            }
            index += 1
        }
        output += String(characters[plainStart...])
        return ChatTimestampPlan(markdown: output, tokens: tokens)
    }
}
