import SwiftUI
import AppKit
import ImageIO

/// No timer or independent Music reader. Observe only the existing Presence
/// samples while Home is the key window, and unmount when navigating away.
struct HomeMusicPresenceView: View {
    @Environment(AppleMusicPresenceService.self) private var presence
    @Environment(\.controlActiveState) private var controlActiveState
    @AppStorage("maomaoShowMusicOnHome") private var showCard = true
    @State private var consumerID = UUID()
    @State private var lastSnapshot: AppleMusicHomeSnapshot?

    private var isEligible: Bool {
        showCard && presence.hasHomePlayback
    }
    private var isActive: Bool { isEligible && controlActiveState == .key }
    // Retain a static card in the background without observing new samples.
    private var visibleSnapshot: AppleMusicHomeSnapshot? { isActive ? presence.homeSnapshot : lastSnapshot }

    var body: some View {
        Group {
            if isEligible, let sample = visibleSnapshot {
                HStack(alignment: .center, spacing: 14) {
                    HomeMusicArtwork(url: sample.artworkURL, isActive: isActive)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Label(sample.playbackState == .playing ? "Listening to Apple Music" : "Paused in Apple Music",
                                  systemImage: sample.playbackState == .playing ? "music.note" : "pause.fill")
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Button("Hide Apple Music card", systemImage: "eye.slash") { showCard = false }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                                .help("Hide this card. Restore it in Settings → General → Apple Music.")
                        }
                        Text(sample.title).font(.headline).lineLimit(1)
                            .help(sample.title)
                        if let artist = sample.artist, !artist.isEmpty {
                            Text(artist).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(artist)
                        }
                        if sample.duration > 0 {
                            HStack(spacing: 10) {
                                // A static sample, not a per-frame animation.
                                GeometryReader { proxy in
                                    Capsule().fill(Color.primary.opacity(0.12))
                                    Capsule().fill(Color.primary.opacity(0.55))
                                        .frame(width: proxy.size.width * min(1, Double(sample.position) / Double(sample.duration)))
                                }.frame(height: 3).accessibilityHidden(true)
                                Text(Self.clock(sample.duration))
                            }
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .padding(.top, 3)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Song progress")
                        }
                    }
                }
                .padding(12).modifier(NokoSurface(cornerRadius: 14))
            }
        }
        .onAppear { presence.setHomeConsumer(consumerID, active: isActive) }
        .onChange(of: isActive) { _, active in presence.setHomeConsumer(consumerID, active: active) }
        .onChange(of: visibleSnapshot, initial: true) { _, sample in
            if isActive { lastSnapshot = sample }
        }
        .onChange(of: isEligible) { _, eligible in
            if !eligible { lastSnapshot = nil }
        }
        .onDisappear { presence.setHomeConsumer(consumerID, active: false) }
    }

    private static func clock(_ seconds: Int) -> String {
        seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct HomeMusicArtwork: View {
    let url: URL?
    let isActive: Bool
    @State private var image: NSImage?
    // Small, decoded thumbnails; covers are fetched only while visible.
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 12
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()
    private static let misses: NSCache<NSURL, NSDate> = {
        let cache = NSCache<NSURL, NSDate>()
        cache.countLimit = 24
        return cache
    }()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .systemPink))
            }
        }
        .frame(width: 80, height: 80).clipShape(.rect(cornerRadius: 12))
        .accessibilityHidden(true)
        .task(id: isActive ? url : nil) {
            guard isActive else { return }
            image = nil
            guard let url, AppleMusicArtworkURL.validArtworkURL(url) != nil else { return }
            if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
            if let expiry = Self.misses.object(forKey: url as NSURL), expiry.timeIntervalSinceNow > 0 { return }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 4
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      data.count <= 2 * 1024 * 1024 else {
                    Self.recordMiss(url)
                    return
                }
                // Decode a bounded thumbnail off the UI thread, once per URL.
                let decoded = await Task.detached(priority: .utility) { () -> NSImage? in
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: 160,
                            kCGImageSourceCreateThumbnailWithTransform: true
                          ] as CFDictionary) else { return nil }
                    return NSImage(cgImage: thumbnail, size: NSSize(width: 80, height: 80))
                }.value
                guard !Task.isCancelled else { return }
                guard let decoded else { Self.recordMiss(url); return }
                Self.cache.setObject(decoded, forKey: url as NSURL, cost: 160 * 160 * 4)
                image = decoded
            } catch {
                // A missing thumbnail never affects Discord Presence.
                if !Task.isCancelled { Self.recordMiss(url) }
            }
        }
    }

    private static func recordMiss(_ url: URL) {
        misses.setObject(Date().addingTimeInterval(60) as NSDate, forKey: url as NSURL)
    }
}
