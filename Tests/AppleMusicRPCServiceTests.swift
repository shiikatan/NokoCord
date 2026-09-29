import Foundation
import XCTest
@testable import NokoCordCore

final class AppleMusicRPCServiceTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000)

    private func track(name: String = "First Song",
                       album: String = "Album",
                       databaseID: Int? = nil,
                       state: AppleMusicTrack.PlayerState = .playing,
                       position: TimeInterval = 12) -> AppleMusicTrack {
        AppleMusicTrack(databaseID: databaseID ?? (name == "First Song" ? 1 : 2),
                        name: name,
                        artist: "Artist",
                        album: album,
                        duration: 240,
                        position: position,
                        playerState: state,
                        updatedAt: epoch)
    }

    func testReducerKeepsPlayingPausedAndStoppedAsDistinctStates() {
        var reducer = AppleMusicPlaybackReducer()

        let playing = reducer.reduce(.init(generation: 1,
                                            timestamp: epoch,
                                            kind: .playing(track: track(), accuracy: .exact)))
        XCTAssertEqual(playing.currentTrack?.playerState, .playing)
        XCTAssertEqual(playing.positionAccuracy, .exact)

        let pausedTrack = track(state: .paused, position: 42)
        let paused = reducer.reduce(.init(generation: 2,
                                          timestamp: epoch.addingTimeInterval(1),
                                          kind: .paused(track: pausedTrack, accuracy: .exact)))
        XCTAssertEqual(paused.currentTrack?.playerState, .paused)
        XCTAssertEqual(paused.currentTrack?.position, 42)

        let stoppedTrack = track(state: .stopped, position: 42)
        let stopped = reducer.reduce(.init(generation: 3,
                                           timestamp: epoch.addingTimeInterval(2),
                                           kind: .stopped(track: stoppedTrack, accuracy: .unavailable)))
        XCTAssertEqual(stopped.currentTrack?.playerState, .stopped)
        XCTAssertEqual(stopped.positionAccuracy, .unavailable)
    }

    func testDelayedClearCannotEraseNewerTrack() {
        var reducer = AppleMusicPlaybackReducer()
        _ = reducer.reduce(.init(generation: 1,
                                 timestamp: epoch,
                                 kind: .playing(track: track(), accuracy: .exact)))
        _ = reducer.reduce(.init(generation: 2,
                                 timestamp: epoch.addingTimeInterval(1),
                                 kind: .stopped(track: track(state: .stopped), accuracy: .unavailable)))
        _ = reducer.reduce(.init(generation: 3,
                                 timestamp: epoch.addingTimeInterval(4),
                                 kind: .playing(track: track(name: "Second Song"), accuracy: .exact)))

        let afterLateClear = reducer.reduce(.init(generation: 2,
                                                  timestamp: epoch.addingTimeInterval(9),
                                                  kind: .clear))
        XCTAssertEqual(afterLateClear.currentTrack?.name, "Second Song")
        XCTAssertEqual(afterLateClear.generation, 3)
    }

    func testOlderTimestampCannotEraseNewerGeneration() {
        var reducer = AppleMusicPlaybackReducer()
        _ = reducer.reduce(.init(generation: 4,
                                 timestamp: epoch.addingTimeInterval(5),
                                 kind: .playing(track: track(name: "Second Song"), accuracy: .exact)))

        let stale = reducer.reduce(.init(generation: 5,
                                         timestamp: epoch.addingTimeInterval(2),
                                         kind: .stopped(track: track(state: .stopped), accuracy: .unavailable)))
        XCTAssertEqual(stale.currentTrack?.name, "Second Song")
        XCTAssertEqual(stale.generation, 4)
    }

    func testHelperFailuresExposeTruthfulStatusAndLoseExactPosition() {
        var reducer = AppleMusicPlaybackReducer()
        _ = reducer.reduce(.init(generation: 1,
                                 timestamp: epoch,
                                 kind: .playing(track: track(), accuracy: .exact)))

        let missing = reducer.reduce(.init(generation: 2,
                                           timestamp: epoch.addingTimeInterval(20),
                                           kind: .helperDisconnected))
        XCTAssertEqual(missing.helperStatus, .missing)
        XCTAssertEqual(missing.positionAccuracy, .unavailable)
        XCTAssertTrue(missing.message?.contains("unavailable") == true)

        let denied = reducer.reduce(.init(generation: 3,
                                          timestamp: epoch.addingTimeInterval(21),
                                          kind: .helperDenied))
        XCTAssertEqual(denied.helperStatus, .accessDenied)
        XCTAssertTrue(denied.message?.contains("Automation") == true)

        let stale = reducer.reduce(.init(generation: 4,
                                         timestamp: epoch.addingTimeInterval(22),
                                         kind: .helperStale))
        XCTAssertEqual(stale.helperStatus, .stale)
        XCTAssertTrue(stale.message?.contains("stale") == true)

        let unsupported = reducer.reduce(.init(generation: 5,
                                               timestamp: epoch.addingTimeInterval(23),
                                               kind: .helperUnsupported))
        XCTAssertEqual(unsupported.helperStatus, .unsupported)
        XCTAssertTrue(unsupported.message?.contains("unsupported") == true)
    }

    func testReconnectBackoffIsBoundedAndResetsAfterAReport() {
        var policy = AppleMusicWatcherReconnectPolicy(baseDelay: 5, maximumDelay: 20)
        let first = epoch

        XCTAssertTrue(policy.canAttempt(at: first))
        policy.recordAttempt(at: first)
        XCTAssertFalse(policy.canAttempt(at: first.addingTimeInterval(4.9)))
        XCTAssertTrue(policy.canAttempt(at: first.addingTimeInterval(5)))

        policy.recordAttempt(at: first.addingTimeInterval(5))
        policy.recordAttempt(at: first.addingTimeInterval(15))
        policy.recordAttempt(at: first.addingTimeInterval(35))
        XCTAssertEqual(policy.nextAttemptAt, first.addingTimeInterval(55))

        policy.recordReport(at: first.addingTimeInterval(40))
        XCTAssertEqual(policy.attemptCount, 0)
        XCTAssertTrue(policy.canAttempt(at: first.addingTimeInterval(40)))
    }

    func testReducerCoversPauseResumeStopSeekRepeatAndNextTrack() {
        var reducer = AppleMusicPlaybackReducer()

        let coldStart = reducer.reduce(.init(generation: 1,
                                              timestamp: epoch,
                                              kind: .playing(track: track(position: 4), accuracy: .estimated)))
        XCTAssertEqual(coldStart.playbackState, .playing)

        let paused = reducer.reduce(.init(generation: 2,
                                          timestamp: epoch.addingTimeInterval(1),
                                          kind: .paused(track: nil, accuracy: .estimated)))
        XCTAssertEqual(paused.playbackState, .paused)
        XCTAssertEqual(paused.currentTrack?.position, 4)

        let resumed = reducer.reduce(.init(generation: 3,
                                           timestamp: epoch.addingTimeInterval(2),
                                           kind: .playing(track: track(position: 5), accuracy: .estimated)))
        XCTAssertEqual(resumed.playbackState, .playing)
        XCTAssertEqual(resumed.currentTrack?.position, 5)

        let seeked = reducer.reduce(.init(generation: 4,
                                          timestamp: epoch.addingTimeInterval(3),
                                          kind: .seeked(track: track(position: 90), accuracy: .estimated)))
        XCTAssertEqual(seeked.playbackState, .playing)
        XCTAssertEqual(seeked.currentTrack?.position, 90)

        let repeated = reducer.reduce(.init(generation: 5,
                                            timestamp: epoch.addingTimeInterval(4),
                                            kind: .repeated(track: track(position: 0), accuracy: .estimated)))
        XCTAssertEqual(repeated.playbackState, .playing)
        XCTAssertEqual(repeated.currentTrack?.position, 0)

        let next = track(name: "Second Song", position: 0)
        let nextTrack = reducer.reduce(.init(generation: 6,
                                             timestamp: epoch.addingTimeInterval(5),
                                             kind: .nextTrack(track: next, accuracy: .estimated)))
        XCTAssertEqual(nextTrack.playbackState, .playing)
        XCTAssertEqual(nextTrack.currentTrack?.id, next.id)

        let stopped = reducer.reduce(.init(generation: 7,
                                           timestamp: epoch.addingTimeInterval(6),
                                           kind: .stopped(track: nil, accuracy: .unavailable)))
        XCTAssertEqual(stopped.playbackState, .stopped)
        XCTAssertEqual(stopped.currentTrack?.playerState, .stopped)
    }

    func testSameTitleDifferentAlbumIsARealIdentityChange() {
        var reducer = AppleMusicPlaybackReducer()
        let first = track(name: "Same Song", album: "First Album", databaseID: 10)
        let second = track(name: "Same Song", album: "Second Album", databaseID: 11)

        XCTAssertNotEqual(first.id, second.id)
        _ = reducer.reduce(.init(generation: 1, timestamp: epoch, kind: .playing(track: first, accuracy: .estimated)))
        let snapshot = reducer.reduce(.init(generation: 2,
                                            timestamp: epoch.addingTimeInterval(1),
                                            kind: .nextTrack(track: second, accuracy: .estimated)))

        XCTAssertEqual(snapshot.currentTrack?.album, "Second Album")
        XCTAssertEqual(snapshot.currentTrack?.databaseID, 11)
    }

    func testNotRunningClearsPlaybackWithoutClaimingPosition() {
        var reducer = AppleMusicPlaybackReducer()
        _ = reducer.reduce(.init(generation: 1,
                                 timestamp: epoch,
                                 kind: .playing(track: track(), accuracy: .estimated)))

        let snapshot = reducer.reduce(.init(generation: 2,
                                            timestamp: epoch.addingTimeInterval(1),
                                            kind: .notRunning))

        XCTAssertNil(snapshot.currentTrack)
        XCTAssertEqual(snapshot.playbackState, .idle)
        XCTAssertEqual(snapshot.helperStatus, .notRunning)
        XCTAssertEqual(snapshot.positionAccuracy, .unavailable)
    }

    func testUnavailableHelperIsNotReportedAsAutomationDenied() {
        var reducer = AppleMusicPlaybackReducer()
        let snapshot = reducer.reduce(.init(generation: 1,
                                             timestamp: epoch,
                                             kind: .helperUnavailable))

        XCTAssertEqual(snapshot.helperStatus, .missing)
        XCTAssertFalse(snapshot.helperStatus == .accessDenied)
    }

    func testOwnerPolicyTerminatesOnlyAfterBoundedGracePeriod() {
        var policy = AppleMusicWatcherOwnerPolicy(gracePeriod: 30)

        XCTAssertFalse(policy.shouldTerminate(ownerIsRunning: true, at: epoch))
        XCTAssertFalse(policy.shouldTerminate(ownerIsRunning: false, at: epoch))
        XCTAssertFalse(policy.shouldTerminate(ownerIsRunning: false, at: epoch.addingTimeInterval(29.9)))
        XCTAssertTrue(policy.shouldTerminate(ownerIsRunning: false, at: epoch.addingTimeInterval(30)))
        XCTAssertFalse(policy.shouldTerminate(ownerIsRunning: true, at: epoch.addingTimeInterval(31)))
    }

    func testOnlyOneWatcherOwnerCanHoldTheLease() {
        var ownership = AppleMusicWatcherOwnership()

        XCTAssertTrue(ownership.acquire(ownerID: "com.shiikatan.nokocord.chiaki"))
        XCTAssertFalse(ownership.acquire(ownerID: "another-instance"))
        XCTAssertFalse(ownership.release(ownerID: "another-instance"))
        XCTAssertTrue(ownership.release(ownerID: "com.shiikatan.nokocord.chiaki"))
        XCTAssertTrue(ownership.acquire(ownerID: "another-instance"))
    }
}
