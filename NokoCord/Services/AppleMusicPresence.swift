import AppKit
import Foundation
import Observation

enum AppleMusicPlaybackState: Equatable, Sendable {
    case playing
    case paused
}

struct AppleMusicTrackSnapshot: Equatable, Sendable {
    let identity: String
    let title: String
    let artist: String?
    let album: String?
    let albumArtist: String?
    let duration: TimeInterval
    let position: TimeInterval
    let playbackState: AppleMusicPlaybackState
}

enum AppleMusicReadResult: Equatable, Sendable {
    case notRunning
    case stopped
    case track(AppleMusicTrackSnapshot)
}

enum AppleMusicReaderError: Error, Equatable, Sendable {
    case permissionDenied
    case unavailable
}

protocol AppleMusicNowPlayingReading: Sendable {
    func readSnapshot() async throws -> AppleMusicReadResult
}

protocol AppleMusicArtworkLookingUp: Sendable {
    func cachedArtwork(for track: AppleMusicTrackSnapshot) async -> AppleMusicArtwork?
    func artwork(for track: AppleMusicTrackSnapshot) async -> AppleMusicArtwork?
    func artistImage(for track: AppleMusicTrackSnapshot) async -> URL?
}

extension AppleMusicArtworkLookingUp {
    func artistImage(for track: AppleMusicTrackSnapshot) async -> URL? { nil }
    func cachedArtwork(for track: AppleMusicTrackSnapshot) async -> AppleMusicArtwork? { nil }
}

protocol AppleMusicArtworkSource: Sendable {
    func cachedArtworkURL(for track: AppleMusicTrackSnapshot) async -> URL?
    func artworkURL(for track: AppleMusicTrackSnapshot) async -> URL?
    func artistImageURL(for track: AppleMusicTrackSnapshot) async -> URL?
}

extension AppleMusicArtworkSource {
    func artistImageURL(for track: AppleMusicTrackSnapshot) async -> URL? { nil }
    func cachedArtworkURL(for track: AppleMusicTrackSnapshot) async -> URL? { nil }
}

enum AppleMusicArtwork: Equatable, Sendable {
    case url(URL)
    case discordAssetKey(String)

    static let genericDiscordAssetKey = "nokocord_apple_music_generic"
    // Apple's public Music app icon. A URL avoids depending on a separately
    // uploaded asset in each Discord application/edition.
    static let genericArtworkURL = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/c2/74/89/c27489c2-2c63-2e32-efee-b0f59b3184ef/musicCalistoga-0-0-1x_U007epad-0-1-0-85-220.png/512x512bb.jpg")!

    var isTrackSpecific: Bool {
        if case .url(let url) = self { return AppleMusicArtworkURL.validArtworkURL(url) != nil }
        return false
    }

    var richPresenceURL: String? {
        switch self {
        case .url(let url):
            return AppleMusicArtworkURL.validArtworkURL(url)?.absoluteString
        case .discordAssetKey(let key) where key == Self.genericDiscordAssetKey:
            return Self.genericArtworkURL.absoluteString
        default:
            return nil
        }
    }

    var registeredDiscordAssetKey: String? {
        switch self {
        case .discordAssetKey(let key) where key == Self.genericDiscordAssetKey:
            return key
        default:
            return nil
        }
    }
}

enum AppleMusicArtworkURL {
    static func validArtworkURL(_ url: URL) -> URL? {
        validAppleArtworkURL(url) ?? validFallbackArtworkURL(url)
    }

    static func validFallbackArtworkURL(_ url: URL) -> URL? { validDeezerArtworkURL(url) }

    static func validDeezerArtworkURL(_ url: URL) -> URL? { validDeezerImageURL(url, kind: "cover") }
    static func validDeezerArtistImageURL(_ url: URL) -> URL? { validDeezerImageURL(url, kind: "artist") }
    private static func validDeezerImageURL(_ url: URL, kind: String) -> URL? {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "cdn-images.dzcdn.net",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.absoluteString.utf8.count <= 300,
              url.path.range(of: #"^/images/\#(kind)/[a-fA-F0-9]{32}/[0-9]{2,4}x[0-9]{2,4}-[0-9-]+\.(jpg|jpeg|png|webp)$"#,
                             options: .regularExpression) != nil else { return nil }
        return url
    }

    static func validAppleArtworkURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "mzstatic.com" || host.hasSuffix(".mzstatic.com") || host == "apple.com" || host.hasSuffix(".apple.com"),
              url.absoluteString.utf8.count <= 300 else { return nil }
        return url
    }
}

enum AppleMusicArtworkPolicy {
    // A failed lookup is temporary. Keep retries bounded without requiring a
    // track change or Tan restart to recover after a network/provider outage.
    static let retryInterval: TimeInterval = 60
}

enum AppleMusicPresenceStatus: String, Equatable, Sendable {
    case disabled
    case waitingForMusic
    case stopped
    case playing
    case paused
    case permissionDenied
    case unavailable
}

enum AppleMusicPresenceLine: String, Codable, CaseIterable, Identifiable, Sendable {
    case song, artist, album, custom, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .song: String(localized: "Song")
        case .artist: String(localized: "Artist")
        case .album: String(localized: "Album")
        case .custom: String(localized: "Custom text")
        case .none: String(localized: "Hidden")
        }
    }
}
enum AppleMusicStatusLine: String, Codable, CaseIterable, Identifiable, Sendable {
    case firstLine, secondLine, application
    var id: String { rawValue }
    var label: String {
        switch self {
        case .firstLine: String(localized: "First line")
        case .secondLine: String(localized: "Second line")
        case .application: "Apple Music"
        }
    }
}
struct AppleMusicDisplayOptions: Codable, Equatable, Sendable {
    static let storageKey = "maomaoAppleMusicDisplayOptions"
    var firstLine: AppleMusicPresenceLine = .artist
    var secondLine: AppleMusicPresenceLine = .song
    var thirdLine: AppleMusicPresenceLine = .album
    var statusLine: AppleMusicStatusLine = .secondLine
    var firstLineTemplate = "{artist}"
    var secondLineTemplate = "{song}"
    var thirdLineTemplate = "{album}"
    var showArtistImage = false
    var showArtwork = true
    var showTimer = true
    var showWhenPaused = true
    init() {}
    private enum CodingKeys: String, CodingKey {
        case firstLine, secondLine, thirdLine, statusLine
        case firstLineTemplate, secondLineTemplate, thirdLineTemplate
        case showArtistImage, showArtwork, showTimer, showWhenPaused
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        firstLine = try values.decodeIfPresent(AppleMusicPresenceLine.self, forKey: .firstLine) ?? .artist
        secondLine = try values.decodeIfPresent(AppleMusicPresenceLine.self, forKey: .secondLine) ?? .song
        thirdLine = try values.decodeIfPresent(AppleMusicPresenceLine.self, forKey: .thirdLine) ?? .album
        statusLine = try values.decodeIfPresent(AppleMusicStatusLine.self, forKey: .statusLine) ?? .secondLine
        firstLineTemplate = try values.decodeIfPresent(String.self, forKey: .firstLineTemplate) ?? "{artist}"
        secondLineTemplate = try values.decodeIfPresent(String.self, forKey: .secondLineTemplate) ?? "{song}"
        thirdLineTemplate = try values.decodeIfPresent(String.self, forKey: .thirdLineTemplate) ?? "{album}"
        showArtistImage = try values.decodeIfPresent(Bool.self, forKey: .showArtistImage) ?? false
        showArtwork = try values.decodeIfPresent(Bool.self, forKey: .showArtwork) ?? true
        showTimer = try values.decodeIfPresent(Bool.self, forKey: .showTimer) ?? true
        showWhenPaused = try values.decodeIfPresent(Bool.self, forKey: .showWhenPaused) ?? true
    }
}

struct AppleMusicHomeSnapshot: Equatable {
    let title: String
    let artist: String?
    let album: String?
    let artworkURL: URL?
    let playbackState: AppleMusicPlaybackState
    let position: Int
    let duration: Int

    init(track: AppleMusicTrackSnapshot, artwork: AppleMusicArtwork?) {
        title = track.title
        artist = track.artist
        album = track.album
        artworkURL = artwork?.richPresenceURL.flatMap(URL.init(string:))
        playbackState = track.playbackState
        position = Self.seconds(track.position)
        duration = Self.seconds(track.duration)
    }

    private static func seconds(_ value: TimeInterval) -> Int {
        value.isFinite && value >= 0 && value < Double(Int.max) ? Int(value) : 0
    }
}

/// Converts Music's sampled position to the absolute timestamps understood by
/// Discord. A paused activity has no running timer; its fixed position is part
/// of the song line instead.
struct AppleMusicActivityMapper {
    private(set) var currentIdentity: String?
    private(set) var lastState: AppleMusicPlaybackState?
    private(set) var lastPosition: TimeInterval?
    private(set) var lastSampleTime: Date?
    private var playbackStart: Date?

    mutating func reset() {
        currentIdentity = nil
        lastState = nil
        lastPosition = nil
        lastSampleTime = nil
        playbackStart = nil
    }

    mutating func activity(
        for track: AppleMusicTrackSnapshot,
        artworkURL: URL?,
        sampledAt: Date
    ) -> NokoActivity? {
        activity(for: track, artwork: artworkURL.map(AppleMusicArtwork.url), sampledAt: sampledAt)
    }

    mutating func activity(
        for track: AppleMusicTrackSnapshot,
        artwork: AppleMusicArtwork?,
        sampledAt: Date,
        options: AppleMusicDisplayOptions = AppleMusicDisplayOptions(),
        artistImage: URL? = nil
    ) -> NokoActivity? {
        let title = Self.discordText(track.title, maximumLength: 128)
        guard let title, !title.isEmpty else { return nil }
        let identityChanged = currentIdentity != track.identity
        let elapsed = lastSampleTime.map { sampledAt.timeIntervalSince($0) } ?? 0
        let positionDelta = lastPosition.map { track.position - $0 } ?? 0
        let likelySeek = !identityChanged && lastState == track.playbackState && {
            switch track.playbackState {
            case .playing: return abs(positionDelta - elapsed) > 2.5
            case .paused: return abs(positionDelta) > 1
            }
        }()

        let start: Date?
        let end: Date?
        switch track.playbackState {
        case .playing:
            if identityChanged || lastState != .playing || likelySeek || playbackStart == nil {
                playbackStart = sampledAt.addingTimeInterval(-max(0, track.position))
            }
            start = playbackStart
            end = track.duration.isFinite && track.duration > 0
                ? playbackStart?.addingTimeInterval(track.duration)
                : nil
        case .paused:
            playbackStart = nil
            start = nil
            end = nil
        }

        currentIdentity = track.identity
        lastState = track.playbackState
        lastPosition = max(0, track.position)
        lastSampleTime = sampledAt

        guard track.playbackState != .paused || options.showWhenPaused else { return nil }
        func text(_ line: AppleMusicPresenceLine, template: String) -> String? {
            switch line {
            case .song: title
            case .artist: track.artist.flatMap { Self.discordText($0, maximumLength: 128) }
            case .album: track.album.flatMap { Self.discordText($0, maximumLength: 128) }
            case .custom:
                Self.discordText(template.replacingOccurrences(of: "{song}", with: track.title)
                    .replacingOccurrences(of: "{artist}", with: track.artist ?? "")
                    .replacingOccurrences(of: "{album}", with: track.album ?? ""), maximumLength: 128)
            case .none: nil
            }
        }
        // A missing artist/album must not accidentally reveal the song through
        // the transport's generic details fallback.
        let details = text(options.firstLine, template: options.firstLineTemplate) ?? "Apple Music"
        var state = text(options.secondLine, template: options.secondLineTemplate)
        if track.playbackState == .paused, let value = state {
            let suffix: String
            if options.showTimer {
                let duration = track.duration.isFinite && track.duration > 0 ? " / \(Self.clock(track.duration))" : ""
                suffix = " · Paused at \(Self.clock(track.position))\(duration)"
            } else { suffix = " · Paused" }
            state = Self.discordText(value + suffix, maximumLength: 128)
        }
        let statusField: NokoActivityStatusDisplayField
        switch options.statusLine {
        case .firstLine: statusField = .details
        case .secondLine: statusField = state == nil ? .name : .state
        case .application: statusField = .name
        }
        return NokoActivity(
            title: title,
            type: .listening,
            name: "Apple Music",
            details: details,
            state: state,
            startedAt: options.showTimer ? start : nil,
            endsAt: options.showTimer ? end : nil,
            largeImageURL: options.showArtwork ? artwork?.richPresenceURL : nil,
            largeImageAssetKey: options.showArtwork ? artwork?.registeredDiscordAssetKey : nil,
            largeImageText: options.showArtwork ? text(options.thirdLine, template: options.thirdLineTemplate) : nil,
            smallImageURL: options.showArtistImage ? artistImage.flatMap(AppleMusicArtworkURL.validDeezerArtistImageURL)?.absoluteString : nil,
            smallImageText: options.showArtistImage ? text(.artist, template: "") : nil,
            statusDisplayField: statusField
        )
    }

    private static func clock(_ value: TimeInterval) -> String {
        let seconds = value.isFinite && value < Double(Int.max)
            ? max(0, Int(value.rounded(.down)))
            : (value.sign == .minus ? 0 : Int.max)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%d:%02d", minutes, remainder)
    }

    private static func discordText(_ value: String, maximumLength: Int) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isNewline && !$0.isControlCharacter }
        guard !clean.isEmpty else { return nil }
        if clean.count <= maximumLength { return clean }
        return String(clean.prefix(maximumLength - 1)) + "…"
    }

}

@MainActor @Observable
final class AppleMusicPresenceService {
    private(set) var status: AppleMusicPresenceStatus = .disabled
    private(set) var hasHomePlayback = false
    private(set) var homeSnapshot: AppleMusicHomeSnapshot?
    @ObservationIgnored private var homeConsumers: Set<UUID> = []

    private let bridge: NokoActivityBridge
    private let reader: any AppleMusicNowPlayingReading
    private let artworkLookup: any AppleMusicArtworkLookingUp
    private let now: @Sendable () -> Date
    private let defaults: UserDefaults?
    private(set) var displayOptions: AppleMusicDisplayOptions
    private let owner = NokoActivityOwner(NokoNativeTanID.appleMusicPresence)
    private var manager: TanManager?
    private var managerObserver: UUID?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artistImageTask: Task<Void, Never>?
    private var artistImageKey: String?
    private var artistImage: URL?
    private var nextArtistLookupAt = Date.distantPast
    private var artistPublicationRetryAfter: Date?
    private var publicationTask: Task<Void, Never>?
    @ObservationIgnored private var displayOptionsPublicationTask: Task<Void, Never>?
    private var publicationID = UUID()
    private var desiredActivity: NokoActivity?
    private var failedActivity: NokoActivity?
    private var failedActivityRetryAfter = Date.distantPast
    private var generation = UUID()
    private var monitoring = false
    private var pollInFlight = false
    @ObservationIgnored private var pendingBridgeStopTask: Task<Void, Never>?
    @ObservationIgnored private var pendingBridgeStopID: UUID?
    @ObservationIgnored private var pendingBridgeStops = 0
    @ObservationIgnored private var reportedCallbackPumpDemand = false
    @ObservationIgnored var onCallbackPumpDemandChanged: ((Bool) -> Void)?
    private var permissionDeniedForCurrentEnable = false
    private var currentIdentity: String?
    private var lastArtworkLookupKey: String?
    private var nextArtworkLookupAt = Date.distantPast
    private var imagePublicationRetryAfter: Date?
    private var resolvedArtwork: AppleMusicArtwork?
    private var currentActivity: NokoActivity?
    private var currentTrack: AppleMusicTrackSnapshot?
    private var mapper = AppleMusicActivityMapper()

    init(
        bridge: NokoActivityBridge,
        reader: any AppleMusicNowPlayingReading = ScriptingBridgeMusicReader(),
        artworkLookup: any AppleMusicArtworkLookingUp = AppleMusicArtworkResolver(),
        now: @escaping @Sendable () -> Date = { Date() },
        defaults: UserDefaults? = .standard
    ) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: AppleMusicDisplayOptions.storageKey),
           let options = try? JSONDecoder().decode(AppleMusicDisplayOptions.self, from: data) {
            displayOptions = options
        } else { displayOptions = AppleMusicDisplayOptions() }
        self.bridge = bridge
        self.reader = reader
        self.artworkLookup = artworkLookup
        self.now = now
    }

    func updateDisplayOptions(_ requested: AppleMusicDisplayOptions) {
        var options = requested
        options.firstLineTemplate = String(options.firstLineTemplate.prefix(1024))
        options.secondLineTemplate = String(options.secondLineTemplate.prefix(1024))
        options.thirdLineTemplate = String(options.thirdLineTemplate.prefix(1024))
        guard displayOptions != options else { return }
        var previousTemplates = options
        previousTemplates.firstLineTemplate = displayOptions.firstLineTemplate
        previousTemplates.secondLineTemplate = displayOptions.secondLineTemplate
        previousTemplates.thirdLineTemplate = displayOptions.thirdLineTemplate
        let onlyTextChanged = previousTemplates == displayOptions
        displayOptions = options
        if !options.showArtistImage { artistImageTask?.cancel(); artistImageTask = nil; artistImageKey = nil; artistImage = nil }
        if let data = try? JSONEncoder().encode(options) { defaults?.set(data, forKey: AppleMusicDisplayOptions.storageKey) }
        displayOptionsPublicationTask?.cancel()
        displayOptionsPublicationTask = nil
        // Persist each keystroke, but coalesce text publication while typing.
        // Closing the editor never discards text or cancels its saved options.
        if monitoring {
            if onlyTextChanged {
                let lease = generation
                displayOptionsPublicationTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                    guard let self, self.generation == lease, self.monitoring else { return }
                    self.displayOptionsPublicationTask = nil
                    self.publishCurrentTrack(sampledAt: self.mapper.lastSampleTime ?? self.now())
                }
            } else {
                publishCurrentTrack(sampledAt: mapper.lastSampleTime ?? now())
                if let currentTrack { scheduleArtistImage(for: currentTrack, generation: generation) }
            }
        }
    }

    private func publishCurrentTrack(sampledAt: Date) {
        guard monitoring, let currentTrack else { return }
        if let activity = mapper.activity(for: currentTrack, artwork: presenceArtwork,
                                          sampledAt: sampledAt, options: displayOptions, artistImage: presenceArtistImage) {
            publishIfChanged(activity, generation: generation)
        } else if currentActivity != nil || desiredActivity != nil {
            cancelPublication(); currentActivity = nil
            scheduleBridgeStop()
        }
    }

    func start(tanManager: TanManager) {
        guard manager == nil else { return }
        manager = tanManager
        managerObserver = tanManager.addChangeObserver { [weak self] in self?.syncEnabledState() }
        syncEnabledState()
    }

    /// Home opts into existing samples only while its card is visible/focused.
    /// This never changes polling or starts an artwork lookup.
    func setHomeConsumer(_ id: UUID, active: Bool) {
        if active { homeConsumers.insert(id) } else { homeConsumers.remove(id) }
        refreshHomeSnapshot()
    }

    private func refreshHomeSnapshot() {
        let hasPlayback = monitoring && (status == .playing || status == .paused) && currentTrack != nil
        if hasHomePlayback != hasPlayback { hasHomePlayback = hasPlayback }
        guard !homeConsumers.isEmpty, hasPlayback,
              let currentTrack else {
            if homeSnapshot != nil { homeSnapshot = nil }
            return
        }
        let sample = AppleMusicHomeSnapshot(track: currentTrack, artwork: resolvedArtwork)
        if homeSnapshot != sample { homeSnapshot = sample }
    }

    func stop() async {
        if let managerObserver { manager?.removeChangeObserver(managerObserver) }
        managerObserver = nil
        manager = nil
        generation = UUID()
        monitoring = false
        pollTask?.cancel(); pollTask = nil
        artworkTask?.cancel(); artworkTask = nil
        clearArtistImage()
        cancelPublication()
        removeMusicLifecycleObservers()
        mapper.reset()
        currentIdentity = nil
        lastArtworkLookupKey = nil
        nextArtworkLookupAt = .distantPast
        imagePublicationRetryAfter = nil
        resolvedArtwork = nil
        currentActivity = nil
        currentTrack = nil
        status = .disabled
        refreshHomeSnapshot()
        scheduleBridgeStop()
        await waitForPendingBridgeStops()
    }

    private func syncEnabledState() {
        guard let manager else { return }
        let shouldMonitor = !manager.safeMode
            && manager.enabledIDs.contains(NokoNativeTanID.appleMusicPresence)
            && hasInstalledBundledNativePackage(manager)
        if shouldMonitor, !monitoring {
            permissionDeniedForCurrentEnable = false
            setMonitoring(true, status: .waitingForMusic)
        } else if !shouldMonitor, monitoring {
            setMonitoring(false, status: .disabled)
        }
    }

    private func hasInstalledBundledNativePackage(_ manager: TanManager) -> Bool {
        guard let bundled = TanPackage.originals.first(where: {
            $0.id == NokoNativeTanID.appleMusicPresence && $0.manifest.target == .native
        }), let installed = manager.installed.first(where: {
            $0.id == NokoNativeTanID.appleMusicPresence
        }) else { return false }

        return installed.manifest.target == .native
            && installed.origin == bundled.origin
            && installed.contentHash == bundled.contentHash
    }

    private func setMonitoring(_ enabled: Bool, status newStatus: AppleMusicPresenceStatus) {
        generation = UUID()
        let currentGeneration = generation
        monitoring = enabled
        pollTask?.cancel()
        pollTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        clearArtistImage()
        status = newStatus
        refreshHomeSnapshot()
        if enabled {
            updateCallbackPumpDemand()
            observeMusicLifecycle()
            pollTask = Task { [weak self] in await self?.pollLoop(generation: currentGeneration) }
        } else {
            removeMusicLifecycleObservers()
            cancelPublication()
            mapper.reset()
            currentIdentity = nil
            lastArtworkLookupKey = nil
            nextArtworkLookupAt = .distantPast
            imagePublicationRetryAfter = nil
            resolvedArtwork = nil
            currentActivity = nil
            failedActivity = nil
            failedActivityRetryAfter = .distantPast
            currentTrack = nil
            scheduleBridgeStop()
        }
    }

    private func scheduleBridgeStop() {
        pendingBridgeStops += 1
        updateCallbackPumpDemand()

        let predecessor = pendingBridgeStopTask
        let requestID = UUID()
        pendingBridgeStopID = requestID
        let bridge = bridge
        let owner = owner
        pendingBridgeStopTask = Task { @MainActor [weak self] in
            await predecessor?.value
            _ = try? await bridge.stop(ownedBy: owner)
            guard let self else { return }
            self.pendingBridgeStops -= 1
            self.updateCallbackPumpDemand()
        }
    }

    private func waitForPendingBridgeStops() async {
        while let pending = pendingBridgeStopTask {
            let requestID = pendingBridgeStopID
            await pending.value
            guard pendingBridgeStopID == requestID else { continue }
            pendingBridgeStopTask = nil
            pendingBridgeStopID = nil
        }
    }

    private func updateCallbackPumpDemand() {
        let demand = monitoring || pendingBridgeStops > 0
        guard demand != reportedCallbackPumpDemand else { return }
        reportedCallbackPumpDemand = demand
        onCallbackPumpDemandChanged?(demand)
    }

    private func pollLoop(generation: UUID) async {
        while !Task.isCancelled, self.generation == generation, monitoring {
            await pollOnce(generation: generation)
            guard !Task.isCancelled, self.generation == generation, monitoring,
                  !permissionDeniedForCurrentEnable else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private func pollOnce(generation: UUID) async {
        guard !pollInFlight else { return }
        pollInFlight = true
        defer { pollInFlight = false }
        do {
            let result = try await reader.readSnapshot()
            guard self.generation == generation, monitoring else { return }
            switch result {
            case .notRunning:
                status = .waitingForMusic
                await clearCurrentActivity(generation: generation)
            case .stopped:
                status = .stopped
                await clearCurrentActivity(generation: generation)
            case .track(let track):
                await accept(track, generation: generation)
            }
        } catch AppleMusicReaderError.permissionDenied {
            permissionDeniedForCurrentEnable = true
            status = .permissionDenied
            artworkTask?.cancel()
            await clearCurrentActivity(generation: generation)
        } catch {
            status = .unavailable
            refreshHomeSnapshot()
        }
    }

    private func accept(_ track: AppleMusicTrackSnapshot, generation: UUID) async {
        let changedTrack = currentIdentity != track.identity
        if changedTrack {
            artworkTask?.cancel()
            artworkTask = nil
            // The portrait belongs to the performer, not the song. Preserve an
            // in-flight lookup, cached photo and retry cooldown for that artist.
            if artistImageKey != track.artist?.trimmingCharacters(in: .whitespacesAndNewlines) {
                clearArtistImage()
            }
            currentIdentity = track.identity
            lastArtworkLookupKey = nil
            nextArtworkLookupAt = .distantPast
            imagePublicationRetryAfter = nil
            resolvedArtwork = nil
            currentActivity = nil
        }
        currentTrack = track
        status = track.playbackState == .playing ? .playing : .paused
        refreshHomeSnapshot()

        publishCurrentTrack(sampledAt: now())
        scheduleArtworkLookup(for: track, generation: generation)
        scheduleArtistImage(for: track, generation: generation)
    }

    private func publishIfChanged(_ activity: NokoActivity, generation: UUID) {
        guard self.generation == generation, monitoring else { return }
        desiredActivity = activity
        guard publicationTask == nil, currentActivity != activity else { return }
        guard failedActivity != activity || now() >= failedActivityRetryAfter else { return }
        let requestID = UUID()
        publicationID = requestID
        publicationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.publicationID == requestID { self.publicationTask = nil }
            }
            await self.publishLatestActivity(generation: generation)
        }
    }

    /// SDK callbacks can take seconds. Keep Music sampling independent, and
    /// coalesce changes into the latest song/state instead of queuing every poll.
    private func publishLatestActivity(generation: UUID) async {
        while !Task.isCancelled, self.generation == generation, monitoring {
            guard let activity = desiredActivity, currentActivity != activity else { return }
            guard failedActivity != activity || now() >= failedActivityRetryAfter else { return }
            await waitForPendingBridgeStops()
            guard !Task.isCancelled, self.generation == generation, monitoring else { return }
            guard desiredActivity == activity else { continue }
            do {
                let result = try await bridge.publish(activity, ownedBy: owner)
                guard !Task.isCancelled, self.generation == generation, monitoring else { return }
                if result == .published || result == .unchanged {
                    currentActivity = activity
                    failedActivity = nil
                } else if desiredActivity == activity {
                    return
                }
            } catch {
                guard !Task.isCancelled, self.generation == generation, monitoring else { return }
                guard desiredActivity == activity else { continue }
                // A failed external image must not prevent the song itself
                // from appearing. Retry this state once with the known asset.
                if activity.largeImageURL != nil, activity.largeImageAssetKey == nil, let track = currentTrack {
                    currentActivity = nil
                    // SDK failures can be connection failures, not bad images.
                    // Publish the song without its external image for now, but
                    // retain the resolved cover and retry it after a cooldown.
                    imagePublicationRetryAfter = now().addingTimeInterval(AppleMusicArtworkPolicy.retryInterval)
                    desiredActivity = mapper.activity(for: track, artwork: .discordAssetKey(AppleMusicArtwork.genericDiscordAssetKey),
                                                      sampledAt: mapper.lastSampleTime ?? Date(), options: displayOptions, artistImage: presenceArtistImage)
                    continue
                }
                if activity.smallImageURL != nil, let track = currentTrack {
                    currentActivity = nil
                    artistPublicationRetryAfter = now().addingTimeInterval(AppleMusicArtworkPolicy.retryInterval)
                    desiredActivity = mapper.activity(for: track, artwork: presenceArtwork,
                        sampledAt: mapper.lastSampleTime ?? now(), options: displayOptions, artistImage: nil)
                    continue
                }
                // Connection failures retry on the next sample without
                // blocking playback reads or building an SDK request backlog.
                // An artwork completion can otherwise resend the identical
                // failed logo immediately, depending on callback ordering.
                failedActivity = activity
                failedActivityRetryAfter = now().addingTimeInterval(1)
                return
            }
        }
    }

    private func cancelPublication() {
        failedActivity = nil
        failedActivityRetryAfter = .distantPast
        displayOptionsPublicationTask?.cancel()
        displayOptionsPublicationTask = nil
        publicationTask?.cancel()
        publicationTask = nil
        publicationID = UUID()
        desiredActivity = nil
    }

    private var presenceArtwork: AppleMusicArtwork {
        if let retryAfter = imagePublicationRetryAfter, now() < retryAfter {
            return .discordAssetKey(AppleMusicArtwork.genericDiscordAssetKey)
        }
        return resolvedArtwork ?? .discordAssetKey(AppleMusicArtwork.genericDiscordAssetKey)
    }

    private var presenceArtistImage: URL? {
        guard artistImageKey == currentTrack?.artist?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let retry = artistPublicationRetryAfter, now() < retry { return nil }
        return artistImage
    }

    private func clearArtistImage() {
        artistImageTask?.cancel(); artistImageTask = nil
        artistImageKey = nil; artistImage = nil; nextArtistLookupAt = .distantPast; artistPublicationRetryAfter = nil
    }
    private func scheduleArtistImage(for track: AppleMusicTrackSnapshot, generation: UUID) {
        guard displayOptions.showArtistImage else { return }
        let key = (track.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { clearArtistImage(); return }
        if key != artistImageKey { clearArtistImage(); artistImageKey = key }
        guard artistImageTask == nil, artistImage == nil, now() >= nextArtistLookupAt else { return }
        artistImageTask = Task { [weak self, artworkLookup] in
            let image = await artworkLookup.artistImage(for: track)
            guard !Task.isCancelled, let self, self.generation == generation,
                  self.artistImageKey == key, self.displayOptions.showArtistImage else { return }
            self.artistImageTask = nil
            self.artistImage = image.flatMap(AppleMusicArtworkURL.validDeezerArtistImageURL)
            self.nextArtistLookupAt = self.now().addingTimeInterval(AppleMusicArtworkPolicy.retryInterval)
            self.publishCurrentTrack(sampledAt: self.mapper.lastSampleTime ?? self.now())
        }
    }

    private func scheduleArtworkLookup(for track: AppleMusicTrackSnapshot, generation: UUID) {
        guard artworkTask == nil else { return }
        let key = track.identity + "|" + AppleMusicArtworkResolver.cacheKey(for: track)
        let changedMetadata = lastArtworkLookupKey != key
        guard changedMetadata || (resolvedArtwork?.isTrackSpecific != true && now() >= nextArtworkLookupAt) else { return }
        lastArtworkLookupKey = key
        artworkTask = Task { [weak self, artworkLookup] in
            defer {
                if let self, self.generation == generation, self.lastArtworkLookupKey == key {
                    self.artworkTask = nil
                    self.nextArtworkLookupAt = self.now().addingTimeInterval(AppleMusicArtworkPolicy.retryInterval)
                }
            }
            // Reuse an already-fetched album cover without another backup
            // request. The normal lookup still gives fresh primary art priority.
            if let cached = await artworkLookup.cachedArtwork(for: track) {
                guard !Task.isCancelled else { return }
                self?.applyArtwork(cached, identity: track.identity, generation: generation)
            }
            let artwork = await artworkLookup.artwork(for: track)
            guard !Task.isCancelled else { return }
            self?.applyArtwork(artwork, identity: track.identity, generation: generation)
        }
    }

    private func applyArtwork(_ artwork: AppleMusicArtwork?, identity: String, generation: UUID) {
        guard self.generation == generation, monitoring, currentIdentity == identity,
              currentTrack != nil else { return }
        if artwork != resolvedArtwork { imagePublicationRetryAfter = nil }
        resolvedArtwork = artwork
        refreshHomeSnapshot()
        let sampleTime = mapper.lastSampleTime ?? Date()
        publishCurrentTrack(sampledAt: sampleTime)
    }

    private func clearCurrentActivity(generation: UUID) async {
        cancelPublication()
        artworkTask?.cancel()
        artworkTask = nil
        clearArtistImage()
        currentIdentity = nil
        lastArtworkLookupKey = nil
        nextArtworkLookupAt = .distantPast
        imagePublicationRetryAfter = nil
        resolvedArtwork = nil
        currentTrack = nil
        refreshHomeSnapshot()
        currentActivity = nil
        mapper.reset()
        guard self.generation == generation else { return }
        await waitForPendingBridgeStops()
        guard self.generation == generation, monitoring else { return }
        _ = try? await bridge.stop(ownedBy: owner)
    }

    private func observeMusicLifecycle() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                guard Self.isMusic(notification) else { return }
                Task { @MainActor [weak self] in
                    self?.pollImmediately()
                }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                guard Self.isMusic(notification) else { return }
                Task { @MainActor [weak self] in
                    await self?.musicTerminated()
                }
            }
        ]
    }

    private func removeMusicLifecycleObservers() {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
    }

    private func pollImmediately() {
        guard monitoring, !permissionDeniedForCurrentEnable else { return }
        let token = generation
        Task { [weak self] in await self?.pollOnce(generation: token) }
    }

    private func musicTerminated() async {
        guard monitoring else { return }
        let token = generation
        status = .waitingForMusic
        await clearCurrentActivity(generation: token)
    }

    nonisolated private static func isMusic(_ notification: Notification) -> Bool {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return false }
        return application.bundleIdentifier == "com.apple.Music"
    }
}

actor AppleMusicArtworkResolver: AppleMusicArtworkLookingUp {
    private let primarySource: any AppleMusicArtworkSource
    private let fallbackSource: any AppleMusicArtworkSource
    private let fallbackAssetKey: String
    private let now: @Sendable () -> Date
    private var successfulArtwork: [String: AppleMusicArtwork] = [:]
    private var successOrder: [String] = []
    private var missExpiry: [String: Date] = [:]
    private let maximumCacheSize = 96
    private let negativeCacheLifetime = AppleMusicArtworkPolicy.retryInterval

    init(
        primarySource: any AppleMusicArtworkSource = AppleMusicCurrentArtworkSource(),
        fallbackSource: any AppleMusicArtworkSource = DeezerArtworkSource(),
        fallbackAssetKey: String = AppleMusicArtwork.genericDiscordAssetKey,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.primarySource = primarySource
        self.fallbackSource = fallbackSource
        self.fallbackAssetKey = fallbackAssetKey
        self.now = now
    }

    func artistImage(for track: AppleMusicTrackSnapshot) async -> URL? {
        guard !Task.isCancelled else { return nil }
        return await fallbackSource.artistImageURL(for: track)
    }

    func cachedArtwork(for track: AppleMusicTrackSnapshot) async -> AppleMusicArtwork? {
        guard !Task.isCancelled else { return nil }
        if let cached = successfulArtwork[Self.cacheKey(for: track)] { return cached }
        guard let url = await fallbackSource.cachedArtworkURL(for: track), !Task.isCancelled,
              let valid = AppleMusicArtworkURL.validFallbackArtworkURL(url) else { return nil }
        return .url(valid)
    }

    func artwork(for track: AppleMusicTrackSnapshot) async -> AppleMusicArtwork? {
        guard !Task.isCancelled else { return nil }
        let key = Self.cacheKey(for: track)
        if let cached = successfulArtwork[key] { return cached }
        if let expiry = missExpiry[key], expiry > now() {
            // Another song may have populated the album cache since this miss.
            if let cached = await cachedArtwork(for: track) {
                cacheSuccess(cached, for: key)
                return cached
            }
            return .discordAssetKey(fallbackAssetKey)
        }
        missExpiry.removeValue(forKey: key)

        // Preserve the current, working source as the authoritative first choice.
        let primaryURL = await primarySource.artworkURL(for: track)
        guard !Task.isCancelled else { return nil }
        if let url = primaryURL,
           let valid = AppleMusicArtworkURL.validAppleArtworkURL(url) {
            let artwork = AppleMusicArtwork.url(valid)
            cacheSuccess(artwork, for: key)
            return artwork
        }

        // Third-party metadata lookup runs only after the current source misses.
        let fallbackURL = await fallbackSource.artworkURL(for: track)
        guard !Task.isCancelled else { return nil }
        if let url = fallbackURL, let valid = AppleMusicArtworkURL.validFallbackArtworkURL(url) {
            let artwork = AppleMusicArtwork.url(valid)
            cacheSuccess(artwork, for: key)
            return artwork
        }

        missExpiry[key] = now().addingTimeInterval(negativeCacheLifetime)
        trimMisses()
        return .discordAssetKey(fallbackAssetKey)
    }

    private func cacheSuccess(_ artwork: AppleMusicArtwork, for key: String) {
        if successfulArtwork[key] == nil { successOrder.append(key) }
        successfulArtwork[key] = artwork
        missExpiry.removeValue(forKey: key)
        while successOrder.count > maximumCacheSize {
            successfulArtwork.removeValue(forKey: successOrder.removeFirst())
        }
    }

    private func trimMisses() {
        let now = now()
        missExpiry = missExpiry.filter { $0.value > now }
        if missExpiry.count > maximumCacheSize {
            for key in missExpiry.keys.sorted(by: { missExpiry[$0, default: .distantPast] < missExpiry[$1, default: .distantPast] })
                .prefix(missExpiry.count - maximumCacheSize) {
                missExpiry.removeValue(forKey: key)
            }
        }
    }

    static func cacheKey(for track: AppleMusicTrackSnapshot) -> String {
        let duration = track.duration.isFinite && track.duration > 0 ? String(Int(track.duration.rounded())) : ""
        return [track.title, track.artist ?? "", track.album ?? "", track.albumArtist ?? "", duration]
            .map(normalized).joined(separator: "|")
    }

    private static func normalized(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }
}

actor AppleMusicCurrentArtworkSource: AppleMusicArtworkSource {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        return URLSession(configuration: configuration)
    }()
    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let trackName: String?
            let artistName: String?
            let collectionName: String?
            let artworkUrl100: URL?
        }
        let results: [Result]
    }

    func artworkURL(for track: AppleMusicTrackSnapshot) async -> URL? {
        guard let requestURL = Self.searchURL(for: track) else { return nil }

        do {
            var request = URLRequest(url: requestURL)
            request.timeoutInterval = 6
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= 2 * 1024 * 1024 else { return nil }
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            let title = Self.normalized(track.title)
            let artist = Self.normalized(track.artist ?? "")
            let album = Self.normalized(track.album ?? "")
            let exact = decoded.results.first { result in
                guard let resultTitle = result.trackName, Self.normalized(resultTitle) == title,
                      let resultArtist = result.artistName, Self.normalized(resultArtist) == artist else { return false }
                return album.isEmpty || result.collectionName.map(Self.normalized) == album
            }
            let fallback = album.isEmpty ? nil : decoded.results.first { result in
                guard let resultTitle = result.trackName, Self.normalized(resultTitle) == title,
                      let resultArtist = result.artistName, Self.normalized(resultArtist) == artist else { return false }
                return true
            }
            guard let image = (exact ?? fallback)?.artworkUrl100 else { return nil }
            return Self.largeArtworkURL(image)
        } catch {
            return nil
        }
    }

    private static func searchURL(for track: AppleMusicTrackSnapshot) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        let term = [track.artist, track.title, track.album].compactMap { $0 }.joined(separator: " ")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10")
        ]
        return components?.url
    }

    private static func normalized(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }

    private static func largeArtworkURL(_ url: URL) -> URL? {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              host.hasSuffix(".mzstatic.com") || host == "mzstatic.com",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = components.path
            .replacingOccurrences(of: "/100x100bb.", with: "/600x600bb.")
            .replacingOccurrences(of: "/100x100-.", with: "/600x600-.")
        guard let large = components.url, large.absoluteString.utf8.count <= 300 else { return nil }
        return large
    }
}

private extension Character {
    var isControlCharacter: Bool {
        unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
    }
}
