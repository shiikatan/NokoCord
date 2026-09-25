import AppKit
import SwiftUI

struct ChatComposer: View {
    @Binding var text: String
    let availability: ComposerAvailability
    let maxCharacters: Int
    let returnSends: Bool
    let replyLabel: String?
    let onCancelReply: (() -> Void)?
    let send: @Sendable (String) async throws -> Void

    @State private var composerState = ComposerState()
    @State private var submissionID = UUID()
    @State private var sendTask: Task<Void, Never>?

    init(text: Binding<String>, availability: ComposerAvailability, maxCharacters: Int = 4_000,
         returnSends: Bool = false, replyLabel: String? = nil, onCancelReply: (() -> Void)? = nil,
         send: @escaping @Sendable (String) async throws -> Void) {
        _text = text; self.availability = availability; self.maxCharacters = maxCharacters
        self.returnSends = returnSends; self.replyLabel = replyLabel; self.onCancelReply = onCancelReply; self.send = send
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let replyLabel {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left")
                        Text(replyLabel).lineLimit(1)
                    Spacer()
                    if let onCancelReply { Button("Cancel reply", systemImage: "xmark") { onCancelReply() }.labelStyle(.iconOnly) }
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    NativeComposerTextView(text: $text, returnSends: returnSends, isEditable: availability.isReady, onSubmit: submit)
                        .frame(minHeight: 42, maxHeight: 150)
                        .padding(7)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                    if text.isEmpty {
                        Text(availability.isReady ? String(localized: "Write a message…") : availability.reason ?? String(localized: "Messaging unavailable"))
                            .foregroundStyle(.secondary).padding(.horizontal, 13).padding(.vertical, 14)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                Button(action: submit) {
                    Image(systemName: composerState.sendState.isFailed ? "arrow.clockwise" : "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!availability.isReady || composerState.sendState == .sending)
                .accessibilityLabel(composerState.sendState.isFailed ? "Retry" : "Send")
            }
            HStack {
                if let reason = availability.reason { Label(reason, systemImage: "info.circle") }
                else if case .failed(let reason) = composerState.sendState { Label(reason, systemImage: "exclamationmark.triangle"); Button("Retry", action: submit).buttonStyle(.link) }
                Spacer()
                Text(String(localized: "\(text.count)/\(maxCharacters)" )).foregroundStyle(text.count > maxCharacters ? .red : .secondary)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
        }
        .onChange(of: availability) { _, value in
            composerState.availability = value
            guard value.isReady else {
                sendTask?.cancel(); submissionID = UUID(); composerState.sendState = .idle
                return
            }
        }
        .onAppear { composerState.availability = availability }
        .onDisappear { sendTask?.cancel(); submissionID = UUID(); composerState.sendState = .idle }
    }

    private func submit() {
        composerState.availability = availability
        guard case .success(let submittedText) = composerState.beginSending(text, maxCharacters: maxCharacters) else { return }
        let id = UUID(); submissionID = id
        sendTask?.cancel()
        sendTask = Task {
            do {
                try await send(submittedText)
                guard !Task.isCancelled, submissionID == id else { return }
                composerState.finish(.success(()))
                if text == submittedText { text = "" }
            } catch {
                guard !Task.isCancelled, submissionID == id else { return }
                composerState.finish(.failure(error))
            }
        }
    }
}

private extension ComposerSendState {
    var isFailed: Bool { if case .failed = self { return true }; return false }
}

private struct NativeComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let returnSends: Bool
    let isEditable: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.drawsBackground = false
        let view = ComposerNSTextView()
        view.delegate = context.coordinator; view.string = text; view.returnSends = returnSends; view.onSubmit = onSubmit
        view.setAccessibilityLabel(String(localized: "Message composer"))
        view.isEditable = isEditable; view.isRichText = false; view.allowsUndo = true; view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textContainerInset = NSSize(width: 2, height: 3); view.backgroundColor = .clear; view.isVerticallyResizable = true; view.autoresizingMask = [.width]
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ComposerNSTextView else { return }
        context.coordinator.parent = self
        view.returnSends = returnSends; view.onSubmit = onSubmit; view.isEditable = isEditable
        if view.string != text { view.string = text }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposerTextView
        init(_ parent: NativeComposerTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { parent.text = view.string } }
    }
}

private final class ComposerNSTextView: NSTextView {
    var returnSends = false
    var onSubmit: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let commandSend = isReturn && event.modifierFlags.contains(.command)
        let returnSend = isReturn && returnSends && !event.modifierFlags.contains(.shift)
        if (commandSend || returnSend) && !hasMarkedText() { onSubmit?() } else { super.keyDown(with: event) }
    }
}
