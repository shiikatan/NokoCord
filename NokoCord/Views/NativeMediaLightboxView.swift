import SwiftUI
import AppKit
import AVKit

/// High-performance native macOS media viewer for images and videos clicked in Discord.
/// Bypasses Discord's heavy React modal lightbox to save GPU texture and JavaScript heap memory.
struct NativeMediaLightboxView: View {
    let mediaURL: URL
    let isVideo: Bool
    var onClose: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isHoveringClose = false
    @State private var isHoveringAction = false
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            // Dark liquid glass backdrop
            Color.black.opacity(0.82)
                .background(.ultraThinMaterial.opacity(0.6))
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }

            // Media Presentation Canvas
            Group {
                if isVideo {
                    if let player {
                        VideoPlayer(player: player)
                            .frame(maxWidth: 960, maxHeight: 640)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
                            .onAppear {
                                player.play()
                            }
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .onAppear {
                                player = AVPlayer(url: mediaURL)
                                player?.play()
                            }
                    }
                } else {
                    AsyncImage(url: mediaURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .scaleEffect(scale)
                                .offset(offset)
                                .gesture(
                                    MagnificationGesture()
                                        .onChanged { value in
                                            let delta = value / lastScale
                                            lastScale = value
                                            scale = max(0.8, min(scale * delta, 5.0))
                                        }
                                        .onEnded { _ in
                                            lastScale = 1.0
                                            if scale < 1.0 {
                                                withAnimation(.nokoSnappySpring) {
                                                    scale = 1.0
                                                    offset = .zero
                                                }
                                            }
                                        }
                                )
                                .simultaneousGesture(
                                    DragGesture()
                                        .onChanged { value in
                                            if scale > 1.0 {
                                                offset = CGSize(
                                                    width: lastOffset.width + value.translation.width,
                                                    height: lastOffset.height + value.translation.height
                                                )
                                            }
                                        }
                                        .onEnded { _ in
                                            lastOffset = offset
                                        }
                                )
                                .onTapGesture(count: 2) {
                                    withAnimation(.nokoFluidSpring) {
                                        if scale > 1.0 {
                                            scale = 1.0
                                            offset = .zero
                                            lastOffset = .zero
                                        } else {
                                            scale = 2.0
                                        }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: .black.opacity(0.55), radius: 28, y: 12)
                        case .failure:
                            VStack(spacing: 12) {
                                Image(systemName: "photo.badge.exclamationmark")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.secondary)
                                Text("Could not preview media")
                                    .font(.headline)
                                Button("Open Original in Browser") {
                                    NSWorkspace.shared.open(mediaURL)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(48)
                }
            }

            // Top Floating Controls Capsule
            VStack {
                HStack(spacing: 12) {
                    // Close button
                    Button {
                        onClose()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                            Text("Esc")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    // Action buttons
                    HStack(spacing: 8) {
                        Button {
                            copyMediaToClipboard()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(8)
                                .background(Color.white.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Copy link or image to clipboard (⌘C)")

                        Button {
                            NSWorkspace.shared.open(mediaURL)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(8)
                                .background(Color.white.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Open in default browser (⌘O)")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)

                Spacer()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func copyMediaToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(mediaURL.absoluteString, forType: .string)
    }
}
