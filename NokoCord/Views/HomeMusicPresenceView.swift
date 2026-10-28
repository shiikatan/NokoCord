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
                                .help("Hide this card. Restore it in Settings → Apple Music.")
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

/// Edits the same mapped fields Discord receives; sample artwork is bundled.
struct AppleMusicDisplaySettings: View {
    @Environment(AppleMusicPresenceService.self) private var presence
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var hoveredLine: String?
    @FocusState private var focusedLine: String?

    private var cardBackground: Color {
        scheme == .dark ? Color(.sRGB, red: 0.27, green: 0.26, blue: 0.28, opacity: 1) : Color(.sRGB, red: 0.92, green: 0.91, blue: 0.93, opacity: 1)
    }
    private func option<Value>(_ path: WritableKeyPath<AppleMusicDisplayOptions, Value>) -> Binding<Value> {
        Binding(get: { presence.displayOptions[keyPath: path] }, set: { value in
            var options = presence.displayOptions
            options[keyPath: path] = value
            presence.updateDisplayOptions(options)
        })
    }
    private var preview: NokoActivity {
        var mapper = AppleMusicActivityMapper()
        return mapper.activity(for: AppleMusicTrackSnapshot(identity: "display-preview", title: "Eclipse",
            artist: "Pink Floyd", album: "The Dark Side of the Moon", albumArtist: "Pink Floyd",
            duration: 127, position: 102, playbackState: .playing),
            artwork: .discordAssetKey(AppleMusicArtwork.genericDiscordAssetKey),
            sampledAt: Date(timeIntervalSince1970: 0), options: presence.displayOptions)!
    }
    private var sampleShowcase: String {
        let activity = preview
        switch activity.statusDisplayField {
        case .details: return activity.details ?? "Apple Music"
        case .state: return activity.state ?? "Apple Music"
        default: return activity.name ?? "Apple Music"
        }
    }
    @ViewBuilder private func lineChoices(_ path: WritableKeyPath<AppleMusicDisplayOptions, AppleMusicPresenceLine>, allowsHidden: Bool = true) -> some View {
        ForEach(AppleMusicPresenceLine.allCases.filter { allowsHidden || $0 != .none }) { field in
            Button { option(path).wrappedValue = field } label: {
                if presence.displayOptions[keyPath: path] == field { Label(field.label, systemImage: "checkmark") }
                else { Text(field.label) }
            }
        }
    }
    private func lineMenu(_ label: String, path: WritableKeyPath<AppleMusicDisplayOptions, AppleMusicPresenceLine>, text: String, font: Font, allowsHidden: Bool = true) -> some View {
        Menu { lineChoices(path, allowsHidden: allowsHidden) } label: {
            HStack(spacing: 4) {
                Text(text).font(font).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                    .opacity(hoveredLine == label || focusedLine == label ? 1 : 0.45)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2).padding(.vertical, 1)
                .background(hoveredLine == label || focusedLine == label ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 3))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .focused($focusedLine, equals: label).onHover { hoveredLine = $0 ? label : nil }
        .accessibilityLabel(Text(LocalizedStringKey(label))).accessibilityValue(presence.displayOptions[keyPath: path].label)
        .help("Choose what appears on this line")
    }
    @ViewBuilder private var showcaseChoices: some View {
        ForEach(AppleMusicStatusLine.allCases) { line in
            Button { option(\.statusLine).wrappedValue = line } label: {
                if presence.displayOptions.statusLine == line { Label(line.label, systemImage: "checkmark") }
                else { Text(line.label) }
            }
        }
    }
    private var editableCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Listening to Apple Music").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Menu {
                    Menu("Second line") { lineChoices(\.secondLine) }
                    Menu("Third line / cover text") { lineChoices(\.thirdLine) }
                    Divider()
                    Toggle("Show album cover", isOn: option(\.showArtwork))
                    Toggle("Show artist photo badge", isOn: option(\.showArtistImage))
                    Toggle("Show playback time", isOn: option(\.showTimer))
                } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .accessibilityLabel("Presence display options")
            }
            HStack(alignment: .center, spacing: 12) {
                if presence.displayOptions.showArtwork {
                    Image("AppleMusicPreviewCover").resizable().scaledToFit().frame(width: 60, height: 60)
                        .clipShape(.rect(cornerRadius: 8))
                        .help(preview.largeImageText ?? "")
                        .accessibilityLabel("The Dark Side of the Moon album cover")
                        .overlay(alignment: .bottomTrailing) {
                            if presence.displayOptions.showArtistImage {
                                Image("AppleMusicPreviewArtist").resizable().scaledToFill().frame(width: 22, height: 22)
                                    .clipShape(.circle).overlay(Circle().stroke(cardBackground, lineWidth: 2))
                                    .offset(x: 4, y: 4).help("Pink Floyd").accessibilityLabel("Pink Floyd artist photo badge")
                            }
                        }
                }
                VStack(alignment: .leading, spacing: 1) {
                    lineMenu("First line", path: \.firstLine, text: preview.details ?? "Apple Music", font: .system(size: 14, weight: .semibold), allowsHidden: false)
                    if let state = preview.state { lineMenu("Second line", path: \.secondLine, text: state, font: .system(size: 13)) }
                    if let third = preview.largeImageText { lineMenu("Third line", path: \.thirdLine, text: third, font: .system(size: 12)) }
                    if presence.displayOptions.showTimer {
                        HStack(spacing: 7) {
                            Text("01:42")
                            GeometryReader { proxy in
                                Capsule().fill(.primary.opacity(0.15))
                                Capsule().fill(.primary.opacity(0.75)).frame(width: proxy.size.width * 102 / 127)
                            }.frame(height: 3).accessibilityHidden(true)
                            Text("02:07")
                        }.font(.system(size: 10, design: .monospaced)).padding(.top, 5)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14).frame(width: 360, alignment: .leading)
        .background(cardBackground, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06)))
    }
    private var nameplatePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Discord nameplate preview").font(.callout.weight(.medium))
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .resizable().scaledToFit().foregroundStyle(.secondary)
                    .frame(width: 40, height: 40).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Username").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Menu { showcaseChoices } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "music.note").foregroundStyle(.green)
                            Text(sampleShowcase).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.secondary)
                        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .accessibilityLabel("Showcase").accessibilityValue(presence.displayOptions.statusLine.label)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(9).frame(width: 360, height: 62)
                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 9))
            Text("Choose the activity text beneath your name. This template uses the sample song above.")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(width: 360)
    }
    private var displayOptions: some View {
        VStack(spacing: 12) {
            displayToggle("Show album cover", path: \.showArtwork)
            displayToggle("Show artist photo badge", path: \.showArtistImage)
            displayToggle("Show playback time", path: \.showTimer)
            displayToggle("Keep activity visible while paused", path: \.showWhenPaused)
        }.toggleStyle(.switch)
    }
    private func displayToggle(_ title: LocalizedStringKey, path: WritableKeyPath<AppleMusicDisplayOptions, Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: option(path)).labelsHidden()
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your Apple Music presence").font(.title2.bold())
                    Text("Click the text in the card to choose what appears.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(spacing: 18) {
                    editableCard
                    Text("Use the card’s ••• menu to restore a hidden line.")
                        .font(.caption).foregroundStyle(.secondary)
                    nameplatePreview
                    if presence.displayOptions.firstLine == .custom || presence.displayOptions.secondLine == .custom || presence.displayOptions.thirdLine == .custom {
                        GroupBox("Custom text") {
                            VStack(alignment: .leading, spacing: 10) {
                                if presence.displayOptions.firstLine == .custom { TextField("First line text", text: option(\.firstLineTemplate)) }
                                if presence.displayOptions.secondLine == .custom { TextField("Second line text", text: option(\.secondLineTemplate)) }
                                if presence.displayOptions.thirdLine == .custom { TextField("Third line text", text: option(\.thirdLineTemplate)) }
                                Text("Use {song}, {artist}, and {album}. Each line displays up to 128 characters.").font(.caption).foregroundStyle(.secondary)
                            }.textFieldStyle(.roundedBorder).padding(6)
                        }
                    }
                    GroupBox("Display") {
                        VStack(alignment: .leading, spacing: 14) {
                            displayOptions
                            Text("Artist photos use an artist-name lookup on Deezer when enabled. The third line is attached to the cover image; Discord may hide it without cover art.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(6)
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 3)
            }
            HStack {
                Button("Restore default display") { presence.updateDisplayOptions(AppleMusicDisplayOptions()) }
                    .disabled(presence.displayOptions == AppleMusicDisplayOptions())
                Spacer()
                Text("Saved automatically").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(width: 740, height: 760)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
