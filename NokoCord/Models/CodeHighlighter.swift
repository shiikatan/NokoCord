import Foundation

enum CodeHighlightKind: Equatable, Sendable {
    case plain
    case keyword
    case string
    case number
    case comment
}

struct CodeHighlightFragment: Equatable, Sendable {
    var text: String
    let kind: CodeHighlightKind
}

enum CodeHighlighter {
    static let maximumSourceCharacters = 32_000

    static func highlight(source: String, language: String?) -> [CodeHighlightFragment] {
        let bounded = Array(source.prefix(maximumSourceCharacters))
        guard let syntax = Syntax(language) else {
            return bounded.isEmpty ? [] : [CodeHighlightFragment(text: String(bounded), kind: .plain)]
        }

        var result: [CodeHighlightFragment] = []
        var index = 0
        while index < bounded.count {
            let start = index
            let kind: CodeHighlightKind
            if syntax.lineComment && index + 1 < bounded.count && bounded[index] == "/" && bounded[index + 1] == "/" {
                index += 2
                while index < bounded.count && !bounded[index].isNewline { index += 1 }
                kind = .comment
            } else if syntax.hashComment && bounded[index] == "#" {
                index += 1
                while index < bounded.count && !bounded[index].isNewline { index += 1 }
                kind = .comment
            } else if syntax.blockComment && index + 1 < bounded.count && bounded[index] == "/" && bounded[index + 1] == "*" {
                index += 2
                while index + 1 < bounded.count && !(bounded[index] == "*" && bounded[index + 1] == "/") { index += 1 }
                if index + 1 < bounded.count { index += 2 } else { index = bounded.count }
                kind = .comment
            } else if syntax.quotes.contains(bounded[index]) {
                let quote = bounded[index]
                index += 1
                while index < bounded.count {
                    if bounded[index] == "\\" { index += min(2, bounded.count - index) }
                    else if bounded[index] == quote { index += 1; break }
                    else { index += 1 }
                }
                kind = .string
            } else if bounded[index].isNumber || (bounded[index] == "-" && index + 1 < bounded.count && bounded[index + 1].isNumber) {
                if bounded[index] == "-" { index += 1 }
                while index < bounded.count && bounded[index].isNumber { index += 1 }
                if index + 1 < bounded.count, bounded[index] == ".", bounded[index + 1].isNumber {
                    index += 1
                    while index < bounded.count && bounded[index].isNumber { index += 1 }
                }
                if index < bounded.count, bounded[index] == "e" || bounded[index] == "E" {
                    var exponentEnd = index + 1
                    if exponentEnd < bounded.count, bounded[exponentEnd] == "+" || bounded[exponentEnd] == "-" { exponentEnd += 1 }
                    let digitStart = exponentEnd
                    while exponentEnd < bounded.count && bounded[exponentEnd].isNumber { exponentEnd += 1 }
                    if exponentEnd > digitStart { index = exponentEnd }
                }
                kind = .number
            } else if bounded[index].isLetter || bounded[index] == "_" {
                index += 1
                while index < bounded.count && (bounded[index].isLetter || bounded[index].isNumber || bounded[index] == "_") { index += 1 }
                let word = String(bounded[start..<index])
                kind = syntax.keywords.contains(word) ? .keyword : .plain
            } else {
                index += 1
                kind = .plain
            }
            append(String(bounded[start..<index]), kind: kind, to: &result)
        }
        return result
    }

    private static func append(_ text: String, kind: CodeHighlightKind, to result: inout [CodeHighlightFragment]) {
        guard !text.isEmpty else { return }
        if result.last?.kind == kind {
            result[result.count - 1].text.append(contentsOf: text)
        } else {
            result.append(CodeHighlightFragment(text: text, kind: kind))
        }
    }

    private struct Syntax {
        let keywords: Set<String>
        let lineComment: Bool
        let hashComment: Bool
        let blockComment: Bool
        let quotes: Set<Character>

        init?(_ language: String?) {
            let name = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch name {
            case "swift":
                keywords = ["actor", "class", "defer", "else", "enum", "extension", "func", "if", "import", "in", "let", "private", "protocol", "public", "return", "struct", "var", "where", "while", "async", "await", "throws", "true", "false", "nil"]
                lineComment = true; hashComment = false; blockComment = true; quotes = ["\"", "'"]
            case "javascript", "js", "typescript", "ts":
                keywords = ["const", "let", "var", "function", "return", "if", "else", "for", "while", "class", "new", "import", "from", "export", "async", "await", "true", "false", "null", "undefined"]
                lineComment = true; hashComment = false; blockComment = true; quotes = ["\"", "'", "`"]
            case "json":
                keywords = ["true", "false", "null"]
                lineComment = false; hashComment = false; blockComment = false; quotes = ["\""]
            case "python", "py":
                keywords = ["and", "as", "class", "def", "elif", "else", "for", "from", "if", "import", "in", "is", "not", "or", "pass", "return", "True", "False", "None", "async", "await", "while", "with", "yield"]
                lineComment = false; hashComment = true; blockComment = false; quotes = ["\"", "'"]
            default: return nil
            }
        }
    }
}
