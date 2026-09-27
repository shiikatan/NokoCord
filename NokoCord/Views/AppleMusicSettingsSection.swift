import SwiftUI

/// Settings section for Apple Music Rich Presence. The feature ships as the
/// bundled `noko.apple-music` Noko-Tan, so this section installs, enables and
/// monitors that Tan instead of keeping a separate preference.
public struct AppleMusicSettingsSection: View {
    @Environment(TanManager.self) private var tans
    @Environment(ActiveBrowserEngine.self) private var browser
    @State private var rpc = AppleMusicRPCService.shared
    @State private var confirmEnable = false

    private var package: TanPackage { TanPackage.appleMusicRPC }
    private var isInstalled: Bool { tans.installed.contains { $0.id == package.id } }
    private var isEnabled: Bool { tans.enabledIDs.contains(package.id) }

    public init() {}

    public var body: some View {
        Section("Apple Music Rich Presence") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Shows the song playing in Apple Music on this Mac as a Listening activity on your Discord profile, with artwork and a progress bar. NokoCord reads playback state locally; nothing is sent anywhere else.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                control
                if isEnabled {
                    Divider()
                    if let track = rpc.currentTrack, track.playerState.isPlaying {
                        playingCard(track)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "pause.circle").foregroundStyle(.secondary)
                            Text("Music is idle or paused. Play any song in Apple Music to broadcast it.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(rpc.lastFMStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if rpc.isPositionAccessDenied {
                        Label("Exact song position needs Automation access: allow NokoCord to control Music in System Settings → Privacy & Security → Automation.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                applicationIDField
                if tans.safeMode {
                    Label("Safe Mode is on, so the Tan and its detector stay paused.", systemImage: "shield.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if tans.reloadRequired {
                    HStack(spacing: 8) {
                        Label("Reload Discord to apply this change.", systemImage: "arrow.clockwise")
                            .font(.caption)
                        Button("Reload Discord") { browser.reload() }
                            .controlSize(.small)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .confirmationDialog("Enable Apple Music RPC?", isPresented: $confirmEnable, titleVisibility: .visible) {
            Button("Enable Tan") { tans.enableOriginal(package) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Tan runs code inside Discord to deliver the activity to your signed-in session. Reload Discord afterwards to apply it.")
        }
        .alert("Apple Music RPC", isPresented: Binding(get: { tans.error != nil }, set: { if !$0 { tans.dismissError() } })) {
            Button("OK") { tans.dismissError() }
        } message: {
            Text(tans.error ?? "")
        }
    }

    @ViewBuilder
    private var applicationIDField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Discord application ID", text: Binding(
                get: { UserDefaults.standard.string(forKey: AppleMusicRPCService.applicationIDKey) ?? "" },
                set: { UserDefaults.standard.set($0, forKey: AppleMusicRPCService.applicationIDKey) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 260)
            Text(isApplicationIDValid
                 ? "Registered application used for the activity. Its name and icon label the presence; artwork and images only resolve through it."
                 : "17–20 digits. Create one at discord.com/developers/applications; artwork and images only resolve through a registered application.")
                .font(.caption)
                .foregroundStyle(isApplicationIDValid ? Color.secondary : Color.orange)
        }
    }

    private var isApplicationIDValid: Bool {
        let stored = (UserDefaults.standard.string(forKey: AppleMusicRPCService.applicationIDKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.allSatisfy(\.isNumber) && (17...20).contains(stored.count)
    }

    @ViewBuilder
    private var control: some View {
        if !isInstalled {
            HStack(spacing: 12) {
                Label("Not installed", systemImage: "circle.dashed").foregroundStyle(.secondary)
                Spacer()
                Button("Install & Enable…") { confirmEnable = true }
            }
        } else if !isEnabled {
            HStack(spacing: 12) {
                Label("Installed, not enabled", systemImage: "circle").foregroundStyle(.secondary)
                Spacer()
                Button("Enable…") { confirmEnable = true }
            }
        } else {
            HStack(spacing: 12) {
                Label("Enabled", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Noko-Tan \(package.manifest.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Disable") { tans.setEnabled(package.id, false) }
            }
        }
    }

    private func playingCard(_ track: AppleMusicTrack) -> some View {
        HStack(spacing: 14) {
            if let artURL = track.artworkURL {
                AsyncImage(url: artURL) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: Color.secondary.opacity(0.15)
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [Color.pink.opacity(0.8), Color.purple.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "music.note").font(.title3).foregroundStyle(.white)
                }
                .frame(width: 54, height: 54)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(track.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Image(systemName: "waveform").font(.system(size: 10, weight: .bold)).foregroundStyle(.pink)
                }
                HStack(spacing: 5) {
                    if let artistImage = track.artistImageURL {
                        AsyncImage(url: artistImage) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFill()
                            default: Color.secondary.opacity(0.15)
                            }
                        }
                        .frame(width: 14, height: 14)
                        .clipShape(Circle())
                    }
                    Text(track.album.isEmpty ? "by \(track.artist)" : "\(track.artist) • \(track.album)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack(spacing: 8) {
                        ProgressView(value: min(1.0, max(0.0, track.duration > 0 ? track.currentPosition / track.duration : 0.0)))
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 160)
                        Text(track.formattedProgress)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}
