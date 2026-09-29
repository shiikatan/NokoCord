import AppKit
import Foundation
import ScriptingBridge

/// Reads only an already-running Music process. The PID-bound initializer is
/// used instead of bundle-ID lookup so the provider never asks Launch Services
/// to start Music on the user's behalf.
actor ScriptingBridgeMusicReader: AppleMusicNowPlayingReading {
    private struct TrackMetadata: Equatable {
        let identity: String
        let title: String
        let artist: String?
        let album: String?
        let albumArtist: String?
        let duration: TimeInterval
    }

    private var cachedMetadata: TrackMetadata?

    func readSnapshot() async throws -> AppleMusicReadResult {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
            .first(where: { !$0.isTerminated }) else {
            cachedMetadata = nil
            return .notRunning
        }
        let pid = running.processIdentifier
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
            .contains(where: { $0.processIdentifier == pid && !$0.isTerminated }),
              let application = SBApplication(processIdentifier: pid) else {
            cachedMetadata = nil
            return .notRunning
        }

        let errorDelegate = AppleMusicScriptErrorDelegate()
        application.delegate = errorDelegate
        application.timeout = 8

        guard let rawState = try value(code: 0x70506C53, from: application, delegate: errorDelegate) else {
            throw AppleMusicReaderError.unavailable
        }
        let stateCode: UInt32?
        if let descriptor = rawState as? NSAppleEventDescriptor { stateCode = descriptor.enumCodeValue }
        else if let number = rawState as? NSNumber { stateCode = number.uint32Value }
        else { stateCode = nil }
        guard let stateCode else { throw AppleMusicReaderError.unavailable }
        if stateCode == 0x6B505353 { // kPSS: stopped
            cachedMetadata = nil
            return .stopped
        }

        let playbackState: AppleMusicPlaybackState
        switch stateCode {
        case 0x6B505350, 0x6B505346, 0x6B505352: // playing, fast-forwarding, rewinding
            playbackState = .playing
        case 0x6B505370: // paused
            playbackState = .paused
        default:
            throw AppleMusicReaderError.unavailable
        }

        guard isStillSameRunningProcess(pid), application.isRunning,
              let rawPosition = try value(code: 0x70506F73, from: application, delegate: errorDelegate),
              let position = Self.number(rawPosition), position.isFinite,
              let currentTrack = try value(code: 0x7054726B, from: application, delegate: errorDelegate) as? SBObject else {
            cachedMetadata = nil
            return .stopped
        }
        let rawDatabaseID = try value(code: 0x70444944, from: currentTrack, delegate: errorDelegate)
        let databaseID = rawDatabaseID.flatMap(Self.number).flatMap(AppleMusicDatabaseID.from)
        var metadata = cachedMetadata
        if databaseID == nil || metadata?.identity != "music-db:\(databaseID!)" {
            metadata = try readMetadata(from: currentTrack, databaseID: databaseID, delegate: errorDelegate)
            cachedMetadata = metadata
        }
        guard let metadata, !metadata.title.isEmpty,
              isStillSameRunningProcess(pid), application.isRunning else { return .stopped }

        return .track(AppleMusicTrackSnapshot(
            identity: metadata.identity,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            albumArtist: metadata.albumArtist,
            duration: metadata.duration,
            position: max(0, position),
            playbackState: playbackState
        ))
    }

    private func readMetadata(
        from track: SBObject,
        databaseID: Int64?,
        delegate: AppleMusicScriptErrorDelegate
    ) throws -> TrackMetadata? {
        guard let rawName = try value(code: 0x706E616D, from: track, delegate: delegate),
              let title = Self.string(rawName)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        let artist = try value(code: 0x70417274, from: track, delegate: delegate).flatMap(Self.string)
        let album = try value(code: 0x70416C62, from: track, delegate: delegate).flatMap(Self.string)
        let albumArtist = try value(code: 0x70416C41, from: track, delegate: delegate).flatMap(Self.string)
        let rawDuration = try value(code: 0x70447572, from: track, delegate: delegate)
        let duration = rawDuration.flatMap(Self.number).map { max(0, $0) } ?? 0
        let identity: String
        if let databaseID {
            identity = "music-db:\(databaseID)"
        } else {
            identity = "stream:\(Self.key(title))|\(Self.key(artist ?? ""))|\(Self.key(album ?? ""))"
        }
        return TrackMetadata(identity: identity, title: title, artist: artist, album: album, albumArtist: albumArtist, duration: duration)
    }

    private func value(
        code: AEKeyword,
        from object: SBObject,
        delegate: AppleMusicScriptErrorDelegate
    ) throws -> Any? {
        delegate.lastError = nil
        let property = object.property(withCode: code)
        let value = property.get()
        if let error = delegate.lastError {
            if error.code == -1743 { throw AppleMusicReaderError.permissionDenied }
            throw AppleMusicReaderError.unavailable
        }
        return value
    }

    private func isStillSameRunningProcess(_ pid: pid_t) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
            .contains(where: { $0.processIdentifier == pid && !$0.isTerminated })
    }

    private static func string(_ value: Any) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSAppleEventDescriptor { return value.stringValue }
        return nil
    }

    private static func number(_ value: Any) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? NSAppleEventDescriptor {
            if value.descriptorType == typeIEEE64BitFloatingPoint { return value.doubleValue }
            if value.descriptorType == typeSInt32 { return Double(value.int32Value) }
            if value.descriptorType == typeUInt32 { return Double(UInt32(bitPattern: value.int32Value)) }
        }
        return nil
    }

    private static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }
}

enum AppleMusicDatabaseID {
    /// Music IDs must be positive whole numbers. `Double(Int64.max)` rounds up
    /// to 2^63, so the exclusive upper-bound check avoids an overflowing cast.
    static func from(_ value: Double) -> Int64? {
        guard value.isFinite,
              value > 0,
              value.rounded(.towardZero) == value,
              value < Double(Int64.max) else { return nil }
        return Int64(value)
    }
}

private final class AppleMusicScriptErrorDelegate: NSObject, SBApplicationDelegate {
    var lastError: NSError?

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: any Error) -> Any? {
        lastError = error as NSError
        return nil
    }
}
