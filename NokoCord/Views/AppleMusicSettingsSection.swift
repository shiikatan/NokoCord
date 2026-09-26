import SwiftUI

/// Settings section allowing users to control and monitor Apple Music Discord Rich Presence.
public struct AppleMusicSettingsSection: View {
    @State private var rpc = AppleMusicRPCService.shared

    public init() {}

    public var body: some View {
        Section("Apple Music Rich Presence") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: Binding(
                    get: { rpc.isEnabled },
                    set: { rpc.isEnabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Broadcast Apple Music Activity to Discord")
                            .font(.headline)
                        Text("Shows your active track, artist, album, and animated progress bar on your Discord profile.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if rpc.isEnabled {
                    Divider()

                    if let track = rpc.currentTrack, track.playerState.isPlaying {
                        HStack(spacing: 14) {
                            // Album Artwork Thumbnail
                            if let artURL = track.artworkURL {
                                AsyncImage(url: artURL) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().scaledToFill()
                                    default:
                                        Color.secondary.opacity(0.15)
                                    }
                                }
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                                .shadow(radius: 4, y: 2)
                            } else {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(LinearGradient(colors: [Color.pink.opacity(0.8), Color.purple.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    Image(systemName: "music.note")
                                        .font(.title3)
                                        .foregroundStyle(.white)
                                }
                                .frame(width: 54, height: 54)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(track.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)

                                    Image(systemName: "waveform")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.pink)
                                }

                                Text("by \(track.artist) • \(track.album)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                HStack(spacing: 8) {
                                    ProgressView(value: min(1.0, max(0.0, track.duration > 0 ? track.position / track.duration : 0.0)))
                                        .progressViewStyle(.linear)
                                        .frame(maxWidth: 160)

                                    Text(track.formattedProgress)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "pause.circle")
                                .foregroundStyle(.secondary)
                            Text("Music is currently idle or paused. Play any song in Apple Music to broadcast.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    // Integrations / Detection Status
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(rpc.isLastFMDetected ? Color.green : Color.secondary.opacity(0.5))
                                .frame(width: 7, height: 7)
                            Text(rpc.isLastFMDetected ? "LastFM.app detected in LastFMSwift (status & artwork active)" : "Native Apple Music tracker active")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 6) {
                            Circle()
                                .fill(DiscordSocialSDKBridge.shared.isSocialSDKLoaded ? Color.green : Color.blue)
                                .frame(width: 7, height: 7)
                            Text(DiscordSocialSDKBridge.shared.isSocialSDKLoaded ? "Discord Social SDK loaded (v\(DiscordSocialSDKBridge.shared.sdkVersion ?? "1.x"))" : "Discord Local IPC client active")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
