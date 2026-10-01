import XCTest
@testable import NokoCordCore

final class AppleMusicPresenceTests: XCTestCase {
    func testListeningActivityMapsArtistAndSongWithStableTimeline() throws {
        var mapper = AppleMusicActivityMapper()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try XCTUnwrap(mapper.activity(for: track(position: 30), artworkURL: URL(string: "https://is1-ssl.mzstatic.com/image/600x600bb.jpg"), sampledAt: start))

        XCTAssertEqual(first.details, "Radiohead")
        XCTAssertEqual(first.state, "Jigsaw Falling Into Place")
        XCTAssertEqual(first.title, "Jigsaw Falling Into Place")
        XCTAssertEqual(first.type, .listening)
        XCTAssertEqual(first.name, "Apple Music")
        XCTAssertEqual(first.statusDisplayField, .state)
        XCTAssertEqual(first.largeImageURL, "https://is1-ssl.mzstatic.com/image/600x600bb.jpg")
        XCTAssertNil(first.largeImageText)
        XCTAssertEqual(first.startedAt, start.addingTimeInterval(-30))
        XCTAssertEqual(first.endsAt, start.addingTimeInterval(150))
        XCTAssertFalse([first.title, first.details, first.state, first.largeImageText].compactMap { $0 }.contains("In Rainbows"))

        let next = try XCTUnwrap(mapper.activity(for: track(position: 32), artworkURL: URL(string: "https://is1-ssl.mzstatic.com/image/600x600bb.jpg"), sampledAt: start.addingTimeInterval(2)))
        XCTAssertEqual(next, first, "Normal playback must keep the same absolute timeline instead of republishing each sample")
    }

    func testPauseFreezesAtSampledPositionAndResumeReanchorsFromMusicPosition() throws {
        var mapper = AppleMusicActivityMapper()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = mapper.activity(for: track(position: 42), artworkURL: nil, sampledAt: start)

        let pausedAt = try XCTUnwrap(mapper.activity(
            for: track(position: 45, playbackState: .paused), artworkURL: nil,
            sampledAt: start.addingTimeInterval(3)
        ))
        XCTAssertEqual(pausedAt.details, "Radiohead")
        XCTAssertEqual(pausedAt.state, "Jigsaw Falling Into Place · Paused at 0:45 / 3:00")
        XCTAssertNil(pausedAt.startedAt)
        XCTAssertNil(pausedAt.endsAt)

        let stillPaused = try XCTUnwrap(mapper.activity(
            for: track(position: 45, playbackState: .paused), artworkURL: nil,
            sampledAt: start.addingTimeInterval(20)
        ))
        XCTAssertEqual(stillPaused, pausedAt)

        let resumed = try XCTUnwrap(mapper.activity(
            for: track(position: 50), artworkURL: nil,
            sampledAt: start.addingTimeInterval(25)
        ))
        XCTAssertEqual(resumed.startedAt, start.addingTimeInterval(-25))
        XCTAssertEqual(resumed.endsAt, start.addingTimeInterval(155))
        XCTAssertEqual(resumed.state, "Jigsaw Falling Into Place")
    }

    func testSeekAndTrackChangeResetTheTimeline() throws {
        var mapper = AppleMusicActivityMapper()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = mapper.activity(for: track(position: 20), artworkURL: nil, sampledAt: start)

        let seeked = try XCTUnwrap(mapper.activity(for: track(position: 100), artworkURL: nil, sampledAt: start.addingTimeInterval(5)))
        XCTAssertEqual(seeked.startedAt, start.addingTimeInterval(-95))

        let nextTrack = try XCTUnwrap(mapper.activity(for: track(identity: "music-db:2", title: "New Song", position: 10), artworkURL: nil, sampledAt: start.addingTimeInterval(10)))
        XCTAssertEqual(nextTrack.startedAt, start)
    }

    func testInvalidOrNonAppleArtworkURLIsOmitted() throws {
        var mapper = AppleMusicActivityMapper()
        let sample = track(position: 1)
        let rejected = try XCTUnwrap(mapper.activity(for: sample, artworkURL: URL(string: "file:///tmp/synthetic-artwork.jpg"), sampledAt: Date()))
        XCTAssertNil(rejected.largeImageURL)
        XCTAssertNil(rejected.largeImageText)
    }

    func testGenericFallbackUsesRegisteredAssetKeyWithoutChangingPresenceFields() throws {
        var mapper = AppleMusicActivityMapper()
        let sample = track(position: 12)
        let activity = try XCTUnwrap(mapper.activity(
            for: sample,
            artwork: .discordAssetKey(AppleMusicArtwork.genericDiscordAssetKey),
            sampledAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))

        XCTAssertNil(activity.largeImageURL)
        XCTAssertEqual(activity.largeImageAssetKey, AppleMusicArtwork.genericDiscordAssetKey)
        XCTAssertEqual(activity.name, "Apple Music")
        XCTAssertEqual(activity.details, "Radiohead")
        XCTAssertEqual(activity.state, "Jigsaw Falling Into Place")
        XCTAssertEqual(activity.statusDisplayField, .state)
    }

    func testArtworkResolverKeepsCurrentArtworkAndCachesSuccess() async {
        let currentURL = URL(string: "https://is1-ssl.mzstatic.com/image/current.jpg")!
        let current = CountingArtworkSource(url: currentURL)
        let resolver = AppleMusicArtworkResolver(primarySource: current)

        let first = await resolver.artwork(for: track(position: 0))
        let second = await resolver.artwork(for: track(position: 9))

        XCTAssertEqual(first, .url(currentURL))
        XCTAssertEqual(second, .url(currentURL))
        let currentCount = await current.lookupCount
        XCTAssertEqual(currentCount, 1)
    }

    func testArtworkResolverUsesGenericAssetAfterPrimaryMissAndCachesFallback() async {
        let current = CountingArtworkSource(url: nil)
        let resolver = AppleMusicArtworkResolver(primarySource: current)

        let first = await resolver.artwork(for: track(position: 0))
        let second = await resolver.artwork(for: track(position: 9))

        XCTAssertEqual(first, .discordAssetKey(AppleMusicArtwork.genericDiscordAssetKey))
        XCTAssertEqual(second, .discordAssetKey(AppleMusicArtwork.genericDiscordAssetKey))
        let currentCount = await current.lookupCount
        XCTAssertEqual(currentCount, 1)
    }

    func testArtworkResolverUsesGenericAssetWhenPrimaryURLIsInvalid() async {
        let invalidPrimary = URL(string: "http://example.com/artwork.jpg")!
        let current = CountingArtworkSource(url: invalidPrimary)
        let resolver = AppleMusicArtworkResolver(primarySource: current)

        let artwork = await resolver.artwork(for: track(position: 0))

        XCTAssertEqual(artwork, .discordAssetKey(AppleMusicArtwork.genericDiscordAssetKey))
    }

    @MainActor
    func testPresenceRequiresEnabledBundledNativePackageHash() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = try XCTUnwrap(TanPackage.originals.first(where: {
            $0.id == NokoNativeTanID.appleMusicPresence
        }))
        let manager = TanManager(root: root)
        try manager.install(bundled)

        let transport = PresenceRecordingTransport()
        let service = AppleMusicPresenceService(
            bridge: NokoActivityBridge(transport: transport),
            reader: FixedMusicReader(result: .notRunning),
            artworkLookup: NoArtworkLookup()
        )
        service.start(tanManager: manager)
        XCTAssertEqual(service.status, .disabled, "An installed but disabled original must not be monitored")

        manager.setEnabled(bundled.id, true)
        XCTAssertEqual(service.status, .waitingForMusic, "The enabled, exact bundled package should start monitoring")
        await service.stop()

        let forgedRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: forgedRoot) }
        let forged = TanPackage(
            manifest: TanManifest(
                id: bundled.id,
                name: "Forged Apple Music Presence",
                version: "9.9.9",
                description: "A local file claiming to be the bundled native Tan.",
                authors: ["untrusted-author"],
                target: .native
            ),
            javascript: nil,
            css: nil,
            origin: "Noko Original"
        )
        try JSONEncoder().encode(forged).write(to: forgedRoot.appendingPathComponent(bundled.id + ".tan.json"))
        struct ForgedState: Encodable {
            let version = 1
            let enabled = [NokoNativeTanID.appleMusicPresence]
            let safeMode = false
            let enableLog = [NokoNativeTanID.appleMusicPresence]
        }
        try JSONEncoder().encode(ForgedState()).write(to: forgedRoot.appendingPathComponent("state.json"))
        let forgedManager = TanManager(root: forgedRoot)
        XCTAssertTrue(forgedManager.enabledIDs.contains(bundled.id))

        let forgedService = AppleMusicPresenceService(
            bridge: NokoActivityBridge(transport: PresenceRecordingTransport()),
            reader: FixedMusicReader(result: .notRunning),
            artworkLookup: NoArtworkLookup()
        )
        forgedService.start(tanManager: forgedManager)
        XCTAssertEqual(forgedService.status, .disabled, "Matching ID and origin are insufficient without the bundled package hash")
        await forgedService.stop()
    }

    @MainActor
    func testDisableEnableWaitsForClearBeforePublishingNewGeneration() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = try XCTUnwrap(TanPackage.originals.first(where: {
            $0.id == NokoNativeTanID.appleMusicPresence
        }))
        let manager = TanManager(root: root)
        try manager.install(bundled)
        manager.setEnabled(bundled.id, true)

        let transport = PresenceBlockingClearTransport()
        let bridge = NokoActivityBridge(transport: transport)
        let service = AppleMusicPresenceService(
            bridge: bridge,
            reader: FixedMusicReader(result: .track(track(position: 30))),
            artworkLookup: NoArtworkLookup()
        )
        var callbackDemand: [Bool] = []
        service.onCallbackPumpDemandChanged = { callbackDemand.append($0) }
        service.start(tanManager: manager)
        await transport.waitForUpdateCount(1)

        await transport.blockNextClear()
        manager.setEnabled(bundled.id, false)
        manager.setEnabled(bundled.id, true)
        await transport.waitForBlockedClear()

        let whileClearIsPending = await transport.events
        XCTAssertEqual(whileClearIsPending.count, 2)
        XCTAssertEqual(whileClearIsPending[0], .update("Jigsaw Falling Into Place"))
        XCTAssertEqual(whileClearIsPending[1], .clear)
        XCTAssertEqual(callbackDemand.last, true, "The callback pump must remain requested while the async clear is pending")

        await transport.releaseBlockedClear()
        await transport.waitForUpdateCount(2)
        let completedEvents = await transport.events
        XCTAssertEqual(completedEvents, [
            .update("Jigsaw Falling Into Place"),
            .clear,
            .update("Jigsaw Falling Into Place")
        ])
        let snapshot = await bridge.snapshot()
        XCTAssertEqual(snapshot.lastPublishedActivity?.state, "Jigsaw Falling Into Place")
        XCTAssertEqual(callbackDemand.last, true, "The callback pump remains needed while presence is active")

        manager.setEnabled(bundled.id, false)
        await service.stop()
        XCTAssertEqual(callbackDemand.last, false, "The callback pump can stop once disable clearing completes")
        await transport.waitForClearCount(2)
    }

    private func track(
        identity: String = "music-db:1",
        title: String = "Jigsaw Falling Into Place",
        artist: String? = "Radiohead",
        album: String? = "In Rainbows",
        duration: TimeInterval = 180,
        position: TimeInterval,
        playbackState: AppleMusicPlaybackState = .playing
    ) -> AppleMusicTrackSnapshot {
        AppleMusicTrackSnapshot(
            identity: identity,
            title: title,
            artist: artist,
            album: album,
            albumArtist: artist,
            duration: duration,
            position: position,
            playbackState: playbackState
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NokoCord-AppleMusicTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor FixedMusicReader: AppleMusicNowPlayingReading {
    private let result: AppleMusicReadResult

    init(result: AppleMusicReadResult) {
        self.result = result
    }

    func readSnapshot() async throws -> AppleMusicReadResult { result }
}

private actor NoArtworkLookup: AppleMusicArtworkLookingUp {
    func artwork(for track: AppleMusicTrackSnapshot) async -> AppleMusicArtwork? { nil }
}

private actor CountingArtworkSource: AppleMusicArtworkSource {
    private let url: URL?
    private(set) var lookupCount = 0

    init(url: URL?) { self.url = url }

    func artworkURL(for track: AppleMusicTrackSnapshot) async -> URL? {
        lookupCount += 1
        return url
    }
}

private actor PresenceRecordingTransport: NokoActivityTransport {
    func update(activity: NokoActivity) async throws {}
    func clear() async throws {}
}

private actor PresenceBlockingClearTransport: NokoActivityTransport {
    enum Event: Equatable {
        case update(String)
        case clear
    }

    private(set) var events: [Event] = []
    private var blockClear = false
    private var blockedClearStarted = false
    private var clearStartContinuation: CheckedContinuation<Void, Never>?
    private var releaseClearContinuation: CheckedContinuation<Void, Never>?
    private var updateWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var clearWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func update(activity: NokoActivity) async throws {
        events.append(.update(activity.state ?? activity.title))
        resumeReadyWaiters(&updateWaiters, reached: updateCount)
    }

    func clear() async throws {
        events.append(.clear)
        resumeReadyWaiters(&clearWaiters, reached: clearCount)
        guard blockClear else { return }
        blockClear = false
        blockedClearStarted = true
        clearStartContinuation?.resume()
        clearStartContinuation = nil
        await withCheckedContinuation { releaseClearContinuation = $0 }
        blockedClearStarted = false
    }

    func blockNextClear() { blockClear = true }

    func waitForBlockedClear() async {
        guard !blockedClearStarted else { return }
        await withCheckedContinuation { clearStartContinuation = $0 }
    }

    func releaseBlockedClear() {
        releaseClearContinuation?.resume()
        releaseClearContinuation = nil
    }

    func waitForUpdateCount(_ count: Int) async {
        guard updateCount < count else { return }
        await withCheckedContinuation { updateWaiters[count, default: []].append($0) }
    }

    func waitForClearCount(_ count: Int) async {
        guard clearCount < count else { return }
        await withCheckedContinuation { clearWaiters[count, default: []].append($0) }
    }

    private var updateCount: Int { events.reduce(into: 0) { if case .update = $1 { $0 += 1 } } }
    private var clearCount: Int { events.reduce(into: 0) { if case .clear = $1 { $0 += 1 } } }

    private func resumeReadyWaiters(
        _ waiters: inout [Int: [CheckedContinuation<Void, Never>]],
        reached count: Int
    ) {
        let readyKeys = waiters.keys.filter { $0 <= count }
        for key in readyKeys {
            for waiter in waiters.removeValue(forKey: key) ?? [] { waiter.resume() }
        }
    }
}
