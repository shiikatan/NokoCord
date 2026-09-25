import SwiftUI

/// Native Liquid Glass Game Rich Presence Inspector Popover.
struct GamePresencePopoverView: View {
    let presence: GamePresence
    @State private var gamePresence = GamePresenceService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // MARK: - Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.55, green: 0.35, blue: 0.95),
                                    Color(red: 0.35, green: 0.45, blue: 0.95)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                        .shadow(color: Color.purple.opacity(0.3), radius: 6, y: 2)

                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("PLAYING A GAME")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)

                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)

                        Text("BROADCASTING")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.green)
                    }

                    Text(presence.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let start = presence.startTimestamp {
                        TimelineView(.periodic(from: .now, by: 1.0)) { context in
                            let elapsed = max(0, Int(context.date.timeIntervalSince(start)))
                            let hrs = elapsed / 3600
                            let mins = (elapsed % 3600) / 60
                            let secs = elapsed % 60

                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.system(size: 9))
                                if hrs > 0 {
                                    Text(String(format: "%d:%02d:%02d elapsed", hrs, mins, secs))
                                } else {
                                    Text(String(format: "%02d:%02d elapsed", mins, secs))
                                }
                            }
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            // MARK: - Activity Details & State
            VStack(alignment: .leading, spacing: 8) {
                if let details = presence.details, !details.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Details")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(details)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }

                if let state = presence.state, !state.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("State")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(state)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }

                if presence.details == nil && presence.state == nil {
                    Text("Game is actively broadcasting via local IPC.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            // MARK: - Metadata Info
            HStack(spacing: 8) {
                Label("App ID: \(presence.clientId)", systemImage: "number")
                    .lineLimit(1)
                Spacer()
                if let pid = presence.pid {
                    Label("PID: \(pid)", systemImage: "cpu")
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)

            Divider()

            // MARK: - Controls
            HStack {
                Button(role: .destructive) {
                    gamePresence.clearPresence()
                    dismiss()
                } label: {
                    Label("Stop Broadcasting", systemImage: "xmark.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 310)
    }
}
