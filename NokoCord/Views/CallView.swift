import SwiftUI

struct CallView: View {
    let state: CallState
    let title: String
    var onMute: ((Bool) -> Void)? = nil
    var onDeafen: ((Bool) -> Void)? = nil
    var onDisconnect: (() -> Void)? = nil
    @State private var focusedParticipantID: String?

    private var isSessionActive: Bool {
        switch state.status { case .connecting, .connected, .reconnecting: true; default: false }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            controls
        }
        .frame(minWidth: 420, minHeight: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .onChange(of: state.sessionID) { _, _ in focusedParticipantID = nil }
        .onChange(of: state) { _, _ in
            if focusedParticipantID != nil && !state.participants.contains(where: { $0.id == focusedParticipantID }) { focusedParticipantID = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "phone.fill").foregroundStyle(.tint)
            Text(title).font(.headline).lineLimit(1)
            Spacer()
            Text(statusLabel).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        switch state.status {
        case .unavailable(let reason): stateMessage(String(localized: "Calls unavailable"), reason: reason, icon: "phone.down")
        case .idle: stateMessage(String(localized: "No active call"), reason: String(localized: "A verified call session will appear here when one is available."), icon: "phone")
        case .connecting: stateMessage(String(localized: "Connecting"), reason: String(localized: "Establishing the approved encrypted call transport."), icon: "ellipsis")
        case .reconnecting(_, let attempt): stateMessage(String(localized: "Reconnecting"), reason: String(localized: "Trying to restore the call (attempt \(attempt))."), icon: "arrow.trianglehead.2.clockwise")
        case .failed(let reason): stateMessage(String(localized: "Call failed"), reason: reason, icon: "exclamationmark.triangle")
        case .connected:
            if state.participants.isEmpty {
                stateMessage(String(localized: "No participants"), reason: String(localized: "The connected call has not reported any participants."), icon: "person.2")
            } else { participantGrid }
        }
    }

    private var participantGrid: some View {
        ScrollView {
            if let focused = state.participants.first(where: { $0.id == focusedParticipantID }) {
                VStack(spacing: 16) {
                    ParticipantTile(participant: focused, isFocused: true).frame(minHeight: 220)
                    Button("Show all participants") { focusedParticipantID = nil }
                }.padding(18)
            } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(state.participants) { participant in
                    Button { focusedParticipantID = focusedParticipantID == participant.id ? nil : participant.id } label: {
                        ParticipantTile(participant: participant, isFocused: focusedParticipantID == participant.id)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(String(localized: "Select or clear focused participant."))
                }
            }
            .padding(18)
            }
        }
        .accessibilityLabel(String(localized: "Call participants"))
    }

    private func stateMessage(_ title: String, reason: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(reason).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { controlButtons }
            VStack(spacing: 8) { controlButtons }
        }
        .padding(14)
    }

    @ViewBuilder private var controlButtons: some View {
        Group {
            Button { onMute?(!state.isMuted) } label: { Label(state.isMuted ? String(localized: "Unmute") : String(localized: "Mute"), systemImage: state.isMuted ? "mic.slash" : "mic") }
                .disabled(!isSessionActive || onMute == nil).help(isSessionActive ? "" : String(localized: "Available only during an active call."))
            Button { onDeafen?(!state.isDeafened) } label: { Label(state.isDeafened ? String(localized: "Undeafen") : String(localized: "Deafen"), systemImage: state.isDeafened ? "ear" : "ear.badge.waveform") }
                .disabled(!isSessionActive || onDeafen == nil).help(isSessionActive ? "" : String(localized: "Available only during an active call."))
            Menu {
                Button(String(localized: "Camera unavailable"), systemImage: "video.slash") {}
                    .disabled(true)
                Button(String(localized: "Screen sharing unavailable"), systemImage: "rectangle.inset.filled.and.person.filled") {}
                    .disabled(true)
                Text(String(localized: "No approved video transport is configured."))
            } label: { Label("Video", systemImage: "video.slash") }
            .menuStyle(.borderlessButton)
            Button(role: .destructive) { onDisconnect?() } label: { Label("Disconnect", systemImage: "phone.down.fill") }
                .disabled(!isSessionActive || onDisconnect == nil)
        }
        .buttonStyle(.bordered)
    }

    private var statusLabel: String {
        switch state.status { case .unavailable: String(localized: "Unavailable"); case .idle: String(localized: "Idle"); case .connecting: String(localized: "Connecting"); case .connected: String(localized: "Connected"); case .reconnecting: String(localized: "Reconnecting"); case .failed: String(localized: "Failed") }
    }
}

private struct ParticipantTile: View {
    let participant: CallParticipant
    let isFocused: Bool
    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Text(String(participant.displayName.prefix(2)).uppercased())
                    .font(.title2.weight(.semibold)).foregroundStyle(.tint)
                    .frame(width: 68, height: 68).background(Color.accentColor.opacity(0.12), in: Circle())
                Circle().fill(participant.isSpeaking ? .green : .gray).frame(width: 14, height: 14).overlay(Circle().stroke(.background, lineWidth: 2))
            }
            Text(participant.displayName).lineLimit(1)
            Text(participant.isSpeaking ? String(localized: "Speaking") : String(localized: "Not speaking"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .padding(10)
        .background(isFocused ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isFocused ? Color.accentColor : .clear, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(participant.displayName), \(participant.isSpeaking ? String(localized: "speaking") : String(localized: "not speaking"))")
    }
}
