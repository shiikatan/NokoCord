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
    func artwork(for track: AppleMusicTrackSnapshot) async -> AppleMusicArtwork?
}

protocol AppleMusicArtworkSource: Sendable {
    func artworkURL(for track: AppleMusicTrackSnapshot) async -> URL?
}

enum AppleMusicArtwork: Equatable, Sendable {
    case url(URL)
    case discordAssetKey(String)

    static let genericDiscordAssetKey = "nokocord_apple_music_generic"

    var richPresenceURL: String? {
        switch self {
        case .url(let url):
            return AppleMusicArtworkURL.validAppleArtworkURL(url)?.absoluteString
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
    static func validAppleArtworkURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "mzstatic.com" || host.hasSuffix(".mzstatic.com") || host == "apple.com" || host.hasSuffix(".apple.com"),
              url.absoluteString.utf8.count <= 300 else { return nil }
        return url
    }
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
        sampledAt: Date
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

        let stateText: String
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
            stateText = title
        case .paused:
            playbackStart = nil
            let position = Self.clock(track.position)
            let duration = track.duration.isFinite && track.duration > 0 ? " / \(Self.clock(track.duration))" : ""
            stateText = Self.discordText("\(title) · Paused at \(position)\(duration)", maximumLength: 128) ?? title
            start = nil
            end = nil
        }

        currentIdentity = track.identity
        lastState = track.playbackState
        lastPosition = max(0, track.position)
        lastSampleTime = sampledAt

        let artist = track.artist.flatMap { Self.discordText($0, maximumLength: 128) }
        return NokoActivity(
            title: title,
            type: .listening,
            name: "Apple Music",
            details: artist,
            state: stateText,
            startedAt: start,
            endsAt: end,
            largeImageURL: artwork?.richPresenceURL,
            largeImageAssetKey: artwork?.registeredDiscordAssetKey,
            largeImageText: nil,
            statusDisplayField: .state
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

    private let bridge: NokoActivityBridge
    private let reader: any AppleMusicNowPlayingReading
    private let artworkLookup: any AppleMusicArtworkLookingUp
    private let owner = NokoActivityOwner(NokoNativeTanID.appleMusicPresence)
    private var manager: TanManager?
    private var managerObserver: UUID?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
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
    private var lastArtworkLookupIdentity: String?
    private var resolvedArtwork: AppleMusicArtwork?
    private var currentActivity: NokoActivity?
    private var currentTrack: AppleMusicTrackSnapshot?
    private var mapper = AppleMusicActivityMapper()

    init(
        bridge: NokoActivityBridge,
        reader: any AppleMusicNowPlayingReading = ScriptingBridgeMusicReader(),
        artworkLookup: any AppleMusicArtworkLookingUp = AppleMusicArtworkResolver()
    ) {
        self.bridge = bridge
        self.reader = reader
        self.artworkLookup = artworkLookup
    }

    func start(tanManager: TanManager) {
        guard manager == nil else { return }
        manager = tanManager
        managerObserver = tanManager.addChangeObserver { [weak self] in self?.syncEnabledState() }
        syncEnabledState()
    }

    func stop() async {
        if let managerObserver { manager?.removeChangeObserver(managerObserver) }
        managerObserver = nil
        manager = nil
        generation = UUID()
        monitoring = false
        pollTask?.cancel(); pollTask = nil
        artworkTask?.cancel(); artworkTask = nil
        removeMusicLifecycleObservers()
        mapper.reset()
        currentIdentity = nil
        lastArtworkLookupIdentity = nil
        resolvedArtwork = nil
        currentActivity = nil
        currentTrack = nil
        status = .disabled
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
        status = newStatus
        if enabled {
            updateCallbackPumpDemand()
            observeMusicLifecycle()
            pollTask = Task { [weak self] in await self?.pollLoop(generation: currentGeneration) }
        } else {
            removeMusicLifecycleObservers()
            mapper.reset()
            currentIdentity = nil
            lastArtworkLookupIdentity = nil
            resolvedArtwork = nil
            currentActivity = nil
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
        }
    }

    private func accept(_ track: AppleMusicTrackSnapshot, generation: UUID) async {
        let changedTrack = currentIdentity != track.identity
        if changedTrack {
            artworkTask?.cancel()
            currentIdentity = track.identity
            lastArtworkLookupIdentity = nil
            resolvedArtwork = nil
            currentActivity = nil
        }
        currentTrack = track
        status = track.playbackState == .playing ? .playing : .paused

        let activity = mapper.activity(for: track, artwork: resolvedArtwork, sampledAt: Date())
        if let activity { await publishIfChanged(activity, generation: generation) }
        scheduleArtworkLookup(for: track, generation: generation)
    }

    private func publishIfChanged(_ activity: NokoActivity, generation: UUID) async {
        guard self.generation == generation, monitoring else { return }
        await waitForPendingBridgeStops()
        guard self.generation == generation, monitoring else { return }
        guard currentActivity != activity else { return }
        do {
            let result = try await bridge.publish(activity, ownedBy: owner)
            guard self.generation == generation, monitoring else { return }
            guard result == .published || result == .unchanged else { return }
            currentActivity = activity
        } catch {
            // Leave currentActivity unchanged so the next sampled state retries.
        }
    }

    private func scheduleArtworkLookup(for track: AppleMusicTrackSnapshot, generation: UUID) {
        guard lastArtworkLookupIdentity != track.identity else { return }
        lastArtworkLookupIdentity = track.identity
        artworkTask = Task { [weak self, artworkLookup] in
            let artwork = await artworkLookup.artwork(for: track)
            guard let self, self.generation == generation, self.monitoring,
                  self.currentIdentity == track.identity, let currentTrack = self.currentTrack else { return }
            self.resolvedArtwork = artwork
            let sampleTime = self.mapper.lastSampleTime ?? Date()
            if let updated = self.mapper.activity(for: currentTrack, artwork: artwork, sampledAt: sampleTime) {
                await self.publishIfChanged(updated, generation: generation)
            }
        }
    }

    private func clearCurrentActivity(generation: UUID) async {
        artworkTask?.cancel()
        artworkTask = nil
        currentIdentity = nil
        lastArtworkLookupIdentity = nil
        resolvedArtwork = nil
        currentTrack = nil
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
    private let fallbackAssetKey: String
    private var successfulArtwork: [String: AppleMusicArtwork] = [:]
    private var successOrder: [String] = []
    private var missExpiry: [String: Date] = [:]
    private let maximumCacheSize = 96
    private let negativeCacheLifetime: TimeInterval = 10 * 60

    init(
        primarySource: any AppleMusicArtworkSource = AppleMusicCurrentArtworkSource(),
        fallbackAssetKey: String = AppleMusicArtwork.genericDiscordAssetKey
    ) {
        self.primarySource = primarySource
        self.fallbackAssetKey = fallbackAssetKey
    }

    func artwork(for track: AppleMusicTrackSnapshot) async -> AppleMusicArtwork? {
        let key = Self.cacheKey(for: track)
        if let cached = successfulArtwork[key] { return cached }
        if let expiry = missExpiry[key], expiry > Date() {
            return .discordAssetKey(fallbackAssetKey)
        }
        missExpiry.removeValue(forKey: key)

        // Preserve the current, working source as the authoritative first choice.
        if let url = await primarySource.artworkURL(for: track),
           let valid = AppleMusicArtworkURL.validAppleArtworkURL(url) {
            let artwork = AppleMusicArtwork.url(valid)
            cacheSuccess(artwork, for: key)
            return artwork
        }

        missExpiry[key] = Date().addingTimeInterval(negativeCacheLifetime)
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
        let now = Date()
        missExpiry = missExpiry.filter { $0.value > now }
        if missExpiry.count > maximumCacheSize {
            for key in missExpiry.keys.sorted(by: { missExpiry[$0, default: .distantPast] < missExpiry[$1, default: .distantPast] })
                .prefix(missExpiry.count - maximumCacheSize) {
                missExpiry.removeValue(forKey: key)
            }
        }
    }

    private static func cacheKey(for track: AppleMusicTrackSnapshot) -> String {
        let duration = track.duration.isFinite && track.duration > 0 ? String(Int(track.duration.rounded())) : ""
        return [track.title, track.artist ?? "", track.album ?? "", duration]
            .map(normalized).joined(separator: "|")
    }

    private static func normalized(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }
}

actor AppleMusicCurrentArtworkSource: AppleMusicArtworkSource {
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
            request.timeoutInterval = 8
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
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
