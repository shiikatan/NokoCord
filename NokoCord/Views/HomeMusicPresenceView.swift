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

/// The card is the editor: every text menu lives where Discord shows its value.
struct AppleMusicDisplaySettings: View {
    @Environment(AppleMusicPresenceService.self) private var presence
    @Environment(\.dismiss) private var dismiss
    @State private var firstTemplate = ""
    @State private var secondTemplate = ""
    @State private var thirdTemplate = ""
    private func option<Value>(_ path: WritableKeyPath<AppleMusicDisplayOptions, Value>) -> Binding<Value> {
        Binding(get: { presence.displayOptions[keyPath: path] }, set: { value in
            var options = presence.displayOptions; options[keyPath: path] = value
            presence.updateDisplayOptions(options)
        })
    }
    private func saveTemplates() {
        var options = presence.displayOptions
        options.firstLineTemplate = firstTemplate; options.secondLineTemplate = secondTemplate; options.thirdLineTemplate = thirdTemplate
        presence.updateDisplayOptions(options)
    }
    private var preview: NokoActivity {
        var mapper = AppleMusicActivityMapper()
        return mapper.activity(for: AppleMusicTrackSnapshot(identity: "display-preview", title: String(localized: "Song title"),
            artist: String(localized: "Artist name"), album: String(localized: "Album name"), albumArtist: nil,
            duration: 240, position: 60, playbackState: .playing), artwork: nil,
            sampledAt: Date(timeIntervalSince1970: 0), options: presence.displayOptions)!
    }
    private var showcase: String {
        let sample = preview
        switch sample.statusDisplayField {
        case .details: return sample.details ?? "Apple Music"
        case .state: return sample.state ?? "Apple Music"
        default: return "Apple Music"
        }
    }
    private func lineMenu(_ label: String, path: WritableKeyPath<AppleMusicDisplayOptions, AppleMusicPresenceLine>, text: String?, bold: Bool = false, allowsHidden: Bool = true) -> some View {
        let current = presence.displayOptions[keyPath: path]
        return Menu {
            ForEach(AppleMusicPresenceLine.allCases.filter { allowsHidden || $0 != .none }) { field in
                Button { option(path).wrappedValue = field } label: {
                    if field == current { Label(field.label, systemImage: "checkmark") }
                    else { Text(field.label) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(text ?? (current == .none ? String(localized: "Hidden") : current.label))
                    .font(bold ? .title3.bold() : .body).lineLimit(2).multilineTextAlignment(.leading)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }.foregroundStyle(current == .none ? Color.secondary : Color.primary)
                .padding(.vertical, 4).padding(.horizontal, 6).contentShape(.rect)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(label).accessibilityValue(current.label)
            .help("Choose what appears on this line")
    }
    private func displayToggle(_ title: LocalizedStringKey, path: WritableKeyPath<AppleMusicDisplayOptions, Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: option(path)).labelsHidden()
        }
    }
    private var editableCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Listening to Apple Music").font(.headline)
            HStack(alignment: .top, spacing: 22) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 15).fill(presence.displayOptions.showArtwork ? AnyShapeStyle(.pink.gradient) : AnyShapeStyle(.quaternary))
                    Image(systemName: presence.displayOptions.showArtwork ? "music.note" : "photo")
                        .font(.system(size: 35, weight: .medium)).foregroundStyle(presence.displayOptions.showArtwork ? .white : .secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if presence.displayOptions.showArtistImage {
                        Image(systemName: "person.fill").font(.body).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(.purple.gradient, in: .circle)
                            .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 3))
                            .offset(x: 6, y: 6).accessibilityLabel("Artist photo badge")
                    }
                }.frame(width: 118, height: 118).accessibilityLabel("Example album cover")
                VStack(alignment: .leading, spacing: 1) {
                    lineMenu("First line", path: \.firstLine, text: preview.details, bold: true, allowsHidden: false)
                    lineMenu("Second line", path: \.secondLine, text: preview.state)
                    lineMenu("Third line", path: \.thirdLine, text: preview.largeImageText)
                        .opacity(presence.displayOptions.showArtwork ? 1 : 0.55)
                    if presence.displayOptions.showTimer {
                        HStack(spacing: 10) {
                            Text("01:00").font(.caption.monospacedDigit())
                            GeometryReader { proxy in
                                Capsule().fill(.quaternary)
                                Capsule().fill(.secondary).frame(width: proxy.size.width / 4)
                            }.frame(height: 3)
                            Text("04:00").font(.caption.monospacedDigit())
                        }.foregroundStyle(.secondary).padding(.leading, 6).padding(.top, 9)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
                Text("Your name").fontWeight(.semibold)
                Image(systemName: "music.note").foregroundStyle(.secondary)
                Menu {
                    ForEach(AppleMusicStatusLine.allCases) { line in
                        Button { option(\.statusLine).wrappedValue = line } label: {
                            let field = line == .firstLine ? presence.displayOptions.firstLine.label : presence.displayOptions.secondLine.label
                            let label = line == .application ? "Apple Music" : "\(field) (\(line.label.lowercased()))"
                            if presence.displayOptions.statusLine == line { Label(label, systemImage: "checkmark") }
                            else { Text(label) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) { Text(showcase).lineLimit(1); Image(systemName: "chevron.down").font(.caption2) }
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).accessibilityLabel("Showcase").accessibilityValue(showcase)
            }.font(.callout)
        }.padding(24).background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.08)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your Apple Music presence").font(.title2.bold())
                    Text("Click a line in the card to choose what it shows.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { saveTemplates(); dismiss() }.buttonStyle(.borderedProminent)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    editableCard
                    Text("Showcase is the text beside your name in Discord’s member list. Click it in the example above to choose the first line, second line, or Apple Music.")
                        .font(.callout).foregroundStyle(.secondary)
                    if presence.displayOptions.firstLine == .custom || presence.displayOptions.secondLine == .custom || presence.displayOptions.thirdLine == .custom {
                        VStack(alignment: .leading, spacing: 10) {
                            if presence.displayOptions.firstLine == .custom { TextField("First line text", text: $firstTemplate).onSubmit(saveTemplates) }
                            if presence.displayOptions.secondLine == .custom { TextField("Second line text", text: $secondTemplate).onSubmit(saveTemplates) }
                            if presence.displayOptions.thirdLine == .custom { TextField("Third line text", text: $thirdTemplate).onSubmit(saveTemplates) }
                            Text("Use {song}, {artist}, and {album}. Each line displays up to 128 characters.").font(.caption).foregroundStyle(.secondary)
                            Button("Apply text", action: saveTemplates)
                        }.textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        displayToggle("Show album cover", path: \.showArtwork)
                        displayToggle("Show artist photo badge", path: \.showArtistImage)
                        displayToggle("Show playback time", path: \.showTimer)
                        displayToggle("Keep activity visible while paused", path: \.showWhenPaused)
                    }.toggleStyle(.switch)
                    Text("Artist photos use an artist-name lookup on Deezer when enabled. The third line uses the cover’s image text; Discord may hide it without cover art. The heading stays ‘Listening to Apple Music’.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Restore default display") { presence.updateDisplayOptions(AppleMusicDisplayOptions()) }
                            .disabled(presence.displayOptions == AppleMusicDisplayOptions())
                        Spacer()
                        Text("Changes apply while Presence is enabled.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 3)
            }
        }.padding(24).frame(width: 740, height: 760)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear { firstTemplate = presence.displayOptions.firstLineTemplate; secondTemplate = presence.displayOptions.secondLineTemplate; thirdTemplate = presence.displayOptions.thirdLineTemplate }
            .onChange(of: presence.displayOptions.firstLineTemplate) { _, value in firstTemplate = value }
            .onChange(of: presence.displayOptions.secondLineTemplate) { _, value in secondTemplate = value }
            .onChange(of: presence.displayOptions.thirdLineTemplate) { _, value in thirdTemplate = value }
    }
}
