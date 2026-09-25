import Foundation
import SwiftUI

struct ChatTimeline: View {
    let messages: [ChatMessage]
    var calendar: Calendar = .current

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(messages.groupedRows(calendar: calendar)) { row in
                    if row.isDateBreak {
                        ChatDateBreak(date: row.message.date)
                    }
                    ChatMessageRowView(row: row)
                        .id(row.id)
                }
            }
            .padding(.vertical, 16)
        }
        .textSelection(.enabled)
        .accessibilityLabel(String(localized: "Chat timeline"))
    }

}

private struct ChatDateBreak: View {
    let date: Date
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().frame(height: 1).foregroundStyle(.quaternary)
            Text(date, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).fixedSize()
            Rectangle().frame(height: 1).foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct ChatMessageRowView: View {
    let row: ChatMessageRow
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if row.isGrouped { Color.clear.frame(width: 34, height: 1) } else { avatar }
            VStack(alignment: .leading, spacing: 5) {
                if !row.isGrouped {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.message.authorName).font(.headline)
                        Text(row.message.date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let reply = row.message.replyTo {
                    Label("Reply to \(reply)", systemImage: "arrowshape.turn.up.left")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SafeChatMarkdown(row.message.text)
                ForEach(row.message.attachments) { attachment in
                    ChatAttachmentView(attachment: attachment)
                }
                if row.message.isEdited { Text("edited").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, row.isGrouped ? 2 : 7)
        .accessibilityLabel(String(localized: "Message from \(row.message.authorName), \(row.message.date.formatted(date: .abbreviated, time: .shortened))"))
    }

    private var avatar: some View {
        Text(String(row.message.authorName.prefix(1)).uppercased())
            .font(.caption.weight(.bold)).foregroundStyle(.tint)
            .frame(width: 34, height: 34)
            .background(Color.accentColor.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }
}

private struct ChatAttachmentView: View {
    let attachment: ChatAttachment
    @State private var confirmOpen = false
    private var safeURL: URL? {
        attachment.url.flatMap { ChatMarkdownParser.allowedURL($0) ? $0 : nil }
    }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip")
            Text(attachment.filename).lineLimit(1)
            if let size = attachment.size { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).foregroundStyle(.secondary) }
            if safeURL != nil {
                Button("Open attachment", systemImage: "arrow.up.right.square") { confirmOpen = true }
                    .labelStyle(.iconOnly).help("Open attachment in your default browser")
            }
        }
        .font(.callout).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityLabel(String(localized: "Attachment \(attachment.filename)"))
        .confirmationDialog("Open attachment?", isPresented: $confirmOpen) {
            if let url = safeURL {
                Button("Open \(url.host() ?? url.absoluteString)") { NSWorkspace.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let url = safeURL {
                Text("This opens \(url.host() ?? url.absoluteString) in your default browser. The site may download the file.")
            }
        }
    }
}

struct SafeChatMarkdown: View {
    let source: String
    @State private var pendingURL: URL?
    init(_ source: String) { self.source = source }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(ChatMarkdownParser.blocks(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value): InlineChatText(source: value, pendingURL: $pendingURL)
                case .code(let language, let value): CodeBlock(language: language, source: value)
                case .heading(let level, let value):
                    InlineChatText(source: value, pendingURL: $pendingURL)
                        .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .accessibilityAddTraits(.isHeader)
                case .quote(let value):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.4)).frame(width: 3)
                        InlineChatText(source: value, pendingURL: $pendingURL)
                    }.fixedSize(horizontal: false, vertical: true)
                case .listItem(let marker, let value):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: marker).foregroundStyle(.secondary)
                        InlineChatText(source: value, pendingURL: $pendingURL)
                    }
                }
            }
        }
        .confirmationDialog("Open link?", isPresented: Binding(get: { pendingURL != nil }, set: { if !$0 { pendingURL = nil } }), presenting: pendingURL) { url in
            Button("Open \(url.host() ?? url.absoluteString)") { NSWorkspace.shared.open(url); pendingURL = nil }
            Button("Cancel", role: .cancel) { pendingURL = nil }
        } message: { url in Text("This will open \(url.host() ?? url.absoluteString) in your default browser.") }
    }

}

private struct InlineChatText: View {
    let source: String
    @Binding var pendingURL: URL?
    @State private var revealedSpoilers: Set<Int> = []
    var body: some View {
        FlowText(source: source, revealedSpoilers: $revealedSpoilers, pendingURL: $pendingURL)
            .onChange(of: source) { _, _ in revealedSpoilers.removeAll() }
    }
}

private struct FlowText: View {
    let source: String
    @Binding var revealedSpoilers: Set<Int>
    @Binding var pendingURL: URL?
    var body: some View {
        let parts = splitSpoilers(source)
        return WrappingChatLayout {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .plain(let value): TimestampInlineText(source: value)
                case .spoiler(let index, let value):
                    Button {
                        if revealedSpoilers.contains(index) { revealedSpoilers.remove(index) } else { revealedSpoilers.insert(index) }
                    } label: {
                        if revealedSpoilers.contains(index) { TimestampInlineText(source: value) } else { Text("••••").underline() }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: revealedSpoilers.contains(index) ? "Hide spoiler" : "Show spoiler"))
                }
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard ChatMarkdownParser.allowedURL(url) else { return .discarded }
            pendingURL = url
            return .handled
        })
    }

    private enum Part { case plain(String), spoiler(Int, String) }
    private func splitSpoilers(_ input: String) -> [Part] {
        var output: [Part] = [], cursor = input.startIndex, index = 0
        while let start = input[cursor...].range(of: "||"), let end = input[start.upperBound...].range(of: "||") {
            if start.lowerBound > cursor { output.append(.plain(String(input[cursor..<start.lowerBound]))) }
            output.append(.spoiler(index, String(input[start.upperBound..<end.lowerBound]))); index += 1; cursor = end.upperBound
        }
        if cursor < input.endIndex { output.append(.plain(String(input[cursor...]))) }
        return output
    }
}

private struct TimestampInlineText: View {
    let source: String
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    var body: some View {
        let plan = ChatTimestampScanner.plan(source)
        if plan.hasRelativeTime {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(plan.attributed(now: context.date, locale: locale, timeZone: timeZone))
            }
        } else {
            Text(plan.attributed(locale: locale, timeZone: timeZone))
        }
    }
}

// Spoiler controls remain individually accessible while flowing within the
// available message width, including narrow windows and longer translations.
private struct WrappingChatLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(width: proposal.width ?? 600, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = positions(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), anchor: .topLeading,
                                 proposal: ProposedViewSize(width: result.sizes[index].width, height: result.sizes[index].height))
        }
    }
    private func positions(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint], sizes: [CGSize]) {
        let width = max(1, width)
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        var points: [CGPoint] = [], sizes: [CGSize] = []
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width { y += height + 2; x = 0; height = 0 }
            points.append(CGPoint(x: x, y: y)); sizes.append(size)
            x += size.width; height = max(height, size.height)
        }
        return (CGSize(width: width, height: y + height), points, sizes)
    }
}

private struct CodeBlock: View {
    @Environment(\.colorScheme) private var colorScheme
    let language: String?
    let source: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(language?.isEmpty == false ? language! : String(localized: "Code")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(copied ? String(localized: "Copied") : String(localized: "Copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source, forType: .string); copied = true }.buttonStyle(.borderless) }
            ScrollView(.horizontal) {
                Text(highlightedSource).font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false).textSelection(.enabled)
                    .padding(.top, 6)
            }
        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: source) { _, _ in copied = false }
    }
    private var highlightedSource: AttributedString {
        var output = AttributedString()
        for fragment in CodeHighlighter.highlight(source: source, language: language) {
            var text = AttributedString(fragment.text)
            switch fragment.kind {
            case .plain: text.foregroundColor = .primary
            case .keyword: text.foregroundColor = colorScheme == .dark
                ? Color(red: 0.82, green: 0.6, blue: 1) : Color(red: 0.45, green: 0.12, blue: 0.65)
            case .string: text.foregroundColor = colorScheme == .dark
                ? Color(red: 0.5, green: 0.85, blue: 0.6) : Color(red: 0, green: 0.38, blue: 0.16)
            case .number: text.foregroundColor = colorScheme == .dark
                ? Color(red: 0.5, green: 0.7, blue: 1) : Color(red: 0, green: 0.25, blue: 0.6)
            case .comment: text.foregroundColor = .secondary
            }
            output.append(text)
        }
        return output
    }
}
