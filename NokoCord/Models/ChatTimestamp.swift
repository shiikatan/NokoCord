import Foundation

/// A Discord timestamp markup value that can be rendered with the user's locale and time zone.
struct ChatTimestamp: Equatable, Sendable {
    let date: Date
    let style: String

    private static let supportedStyles: Set<String> = ["t", "T", "d", "D", "f", "F", "s", "S", "R"]
    private static let maximumMarkupLength = 40
    // Unix seconds for the inclusive Gregorian display range 0001-01-01 through 9999-12-31.
    private static let minimumUnixSeconds: Int64 = -62_135_596_800
    private static let maximumUnixSeconds: Int64 = 253_402_300_799

    /// Parses the exact Discord timestamp form, for example `<t:1700000000:R>`.
    static func parse(_ exactMarkup: String) -> ChatTimestamp? {
        guard exactMarkup.utf8.count <= maximumMarkupLength,
              exactMarkup.first == "<", exactMarkup.last == ">" else { return nil }

        let body = exactMarkup.dropFirst().dropLast()
        let pieces = body.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 || pieces.count == 3, pieces[0] == "t" else { return nil }
        let style = pieces.count == 2 ? "f" : String(pieces[2])
        guard supportedStyles.contains(style), !pieces[1].isEmpty else { return nil }

        let secondsText = String(pieces[1])
        var negative = false
        var value: Int64 = 0
        var sawDigit = false
        for (index, byte) in secondsText.utf8.enumerated() {
            if index == 0, byte == 45 {
                negative = true
                continue
            }
            guard byte >= 48 && byte <= 57 else { return nil }
            sawDigit = true
            let digit = Int64(byte - 48)
            guard value <= (Int64.max - digit) / 10 else { return nil }
            value = value * 10 + digit
        }
        guard sawDigit else { return nil }
        if negative {
            guard value != 0 else { /* -0 is a valid integer timestamp */ return timestamp(value: 0, style: style) }
            value = -value
        }
        return timestamp(value: value, style: style)
    }

    /// Formats this timestamp using Foundation's locale and time-zone aware formatters.
    func format(now: Date, locale: Locale, timeZone: TimeZone) -> String {
        if style == "R" {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: now)
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        switch style {
        case "t": formatter.dateStyle = .none; formatter.timeStyle = .short
        case "T": formatter.dateStyle = .none; formatter.timeStyle = .medium
        case "d": formatter.dateStyle = .short; formatter.timeStyle = .none
        case "D": formatter.dateStyle = .long; formatter.timeStyle = .none
        case "f": formatter.dateStyle = .long; formatter.timeStyle = .short
        case "F": formatter.dateStyle = .full; formatter.timeStyle = .short
        case "s": formatter.dateStyle = .short; formatter.timeStyle = .short
        case "S": formatter.dateStyle = .short; formatter.timeStyle = .medium
        default: return ""
        }
        return formatter.string(from: date)
    }

    private static func timestamp(value: Int64, style: String) -> ChatTimestamp? {
        guard (minimumUnixSeconds...maximumUnixSeconds).contains(value) else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(value))
        return ChatTimestamp(date: date, style: style)
    }
}
