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
    @State private var isSaved = false
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        ZStack {
            // Dark liquid glass backdrop
            Color.black.opacity(0.82)
                .background(.ultraThinMaterial.opacity(0.6))
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }

            // Hidden Spacebar dismiss listener for native Quick Look feel
            Button("") {
                onClose()
            }
            .keyboardShortcut(.space, modifiers: [])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

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
                                    openMediaInBrowser()
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
                            Text("Esc / Space")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close media viewer")

                    Spacer()

                    // Action buttons
                    HStack(spacing: 8) {
                        Button {
                            saveMediaToDownloads()
                        } label: {
                            Group {
                                if isSaving {
                                    ProgressView().controlSize(.small).tint(.white)
                                } else {
                                    Image(systemName: isSaved ? "checkmark" : "arrow.down.to.line")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(isSaved ? .green : .white.opacity(0.9))
                                }
                            }
                            .padding(8)
                            .background(Color.white.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                        .keyboardShortcut("s", modifiers: .command)
                        .accessibilityLabel(isSaved ? "Saved to Downloads" : "Save to Downloads")
                        .help(isSaving ? "Saving…" : "Save to Downloads (⌘S)")

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
                        .keyboardShortcut("c", modifiers: .command)
                        .accessibilityLabel("Copy media link")
                        .help("Copy link to clipboard (⌘C)")

                        Button {
                            openMediaInBrowser()
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(8)
                                .background(Color.white.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("o", modifiers: .command)
                        .accessibilityLabel("Open original media in browser")
                        .help("Open in default browser (⌘O)")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)

                Spacer()
            }
        }
        .onDisappear {
            stopAndReleasePlayer()
        }
        .alert("Could not save media", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "Try again when the file is available.")
        }
    }

    private func stopAndReleasePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func saveMediaToDownloads() {
        guard BrowserPolicy.isDiscordMediaURL(mediaURL), !isSaving else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let proposedName = mediaURL.lastPathComponent.isEmpty ? (isVideo ? "video.mp4" : "image.png") : mediaURL.lastPathComponent
        let fileName = BrowserPolicy.filename(proposedName)
        let destURL = uniqueDestination(in: downloads, fileName: fileName)
        isSaving = true
        saveError = nil

        Task { @MainActor in
            do {
                let (tempURL, response) = try await URLSession.shared.download(from: mediaURL)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    throw MediaSaveError.invalidResponse
                }
                try FileManager.default.moveItem(at: tempURL, to: destURL)
                isSaving = false
                withAnimation(.nokoSnappySpring) {
                    isSaved = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.nokoSnappySpring) {
                        isSaved = false
                    }
                }
            } catch {
                isSaving = false
                saveError = String(localized: "The file could not be saved to Downloads. Check your connection or available storage and try again.")
            }
        }
    }

    private func uniqueDestination(in directory: URL, fileName: String) -> URL {
        let ext = URL(fileURLWithPath: fileName).pathExtension
        let stem = ext.isEmpty ? fileName : String(fileName.dropLast(ext.count + 1))
        for index in 0..<1000 {
            let suffix = index == 0 ? "" : " \(index + 1)"
            let candidateName = ext.isEmpty ? stem + suffix : stem + suffix + "." + ext
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent(stem + "-" + UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
    }

    private func openMediaInBrowser() {
        guard BrowserPolicy.isDiscordMediaURL(mediaURL) else { return }
        NSWorkspace.shared.open(mediaURL)
    }

    private func copyMediaToClipboard() {
        guard BrowserPolicy.isDiscordMediaURL(mediaURL) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(mediaURL.absoluteString, forType: .string)
    }
}

private enum MediaSaveError: Error {
    case invalidResponse
}
