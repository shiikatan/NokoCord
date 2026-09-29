import AppKit

// NokoMusicWatch is the small unsandboxed companion NokoCord launches to read
// Apple Music's own playback state. Apple Events to Music require a consent
// macOS only grants to apps outside the sandbox, so this helper runs as its own
// app bundle under NokoCord's Helpers directory, only ever *reads* the player,
// and exits when the app that launched it is gone.

private let notificationName = Notification.Name("com.shiikatan.nokocord.music")
private let defaultOwnerBundleID = "com.shiikatan.nokocord.chiaki"
private let pollInterval: TimeInterval = 5
private let ownerCheckInterval: TimeInterval = 5
private let ownerGracePeriod: TimeInterval = 30
private let heartbeatInterval: TimeInterval = 15

/// Field separator for the AppleScript result. Music track names may contain
/// almost anything, so the script returns one separator-joined line and the
/// parser rejects anything that does not split cleanly.
private let separator = "\u{1F}"

private let playbackScript = NSAppleScript(source: """
    tell application "Music"
        try
            set playerState to player state as string
            if playerState is "stopped" then return "STOPPED"
            set t to current track
            return playerState & "\u{1F}" & (player position as string) & "\u{1F}" & (name of t) & "\u{1F}" & (artist of t) & "\u{1F}" & (album of t) & "\u{1F}" & (duration of t) & "\u{1F}" & (database ID of t as string)
        on error errNumber
            return "ERROR\u{1F}" & errNumber
        end try
    end tell
    """)

struct Playback {
    let state: String
    let position: Double
    let name: String
    let artist: String
    let album: String
    let duration: Double
    let databaseID: Int
}

enum ScriptOutcome {
    case playback(Playback)
    case stopped
    case denied
    case unsupported(String)
    case failed(Int)
}

private func readPlayback() -> ScriptOutcome {
    guard let script = playbackScript else { return .failed(0) }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error {
        let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        // -1743: the user has not allowed this helper to control Music.
        return code == -1743 ? .denied : .failed(code)
    }
    guard let value = result.stringValue else { return .failed(0) }
    if value == "STOPPED" { return .stopped }
    let fields = value.components(separatedBy: separator)
    if fields.first == "ERROR" {
        let code = fields.count > 1 ? Int(fields[1]) ?? 0 : 0
        return code == -1743 ? .denied : .failed(code)
    }
    guard fields.count >= 7 else { return .failed(0) }
    guard fields[0] == "playing" || fields[0] == "paused" else {
        return .unsupported(fields[0])
    }
    let name = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return .stopped }
    return .playback(Playback(state: fields[0],
                              position: max(0, Double(fields[1]) ?? 0),
                              name: name,
                              artist: fields[3],
                              album: fields[4],
                              duration: max(0, Double(fields[5]) ?? 0),
                              databaseID: Int(fields[6]) ?? 0))
}

private func isMusicRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
}

private let ownerBundleID: String = {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--owner"), index + 1 < arguments.count {
        let value = arguments[index + 1]
        if !value.isEmpty { return value }
    }
    return defaultOwnerBundleID
}()

private func isOwnerRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: ownerBundleID).isEmpty
}

/// Evidence for the failure report: a sandboxed helper is handed a container
/// home and an APP_SANDBOX_CONTAINER_ID, which is exactly what stops it sending
/// Apple Events to Music.
private var sandboxDescription: String {
    let container = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]
    return "container=\(container ?? "none") home=\(NSHomeDirectory())"
}

private func post(_ body: [String: Any]) {
    broadcastSequence &+= 1
    var payload = body
    payload["sequence"] = NSNumber(value: broadcastSequence)
    payload["eventTimestamp"] = Date().timeIntervalSince1970
    DistributedNotificationCenter.default().postNotificationName(notificationName,
                                                                 object: ownerBundleID,
                                                                 userInfo: payload,
                                                                 deliverImmediately: true)
}

private var lastBroadcast = ""
private var lastBroadcastAt: Date?
private var broadcastSequence: UInt64 = 0
private var ownerMissingSince: Date?

private func shouldBroadcast(_ key: String) -> Bool {
    let now = Date()
    if key == lastBroadcast,
       let lastBroadcastAt,
       now.timeIntervalSince(lastBroadcastAt) < heartbeatInterval {
        return false
    }
    lastBroadcast = key
    lastBroadcastAt = now
    return true
}

private func poll() {
    guard isOwnerRunning() else { return }

    guard isMusicRunning() else {
        if shouldBroadcast("notRunning") {
            post(["state": "not_running"])
        }
        return
    }

    switch readPlayback() {
    case .playback(let playback):
        let key = "\(playback.databaseID)|\(playback.state)|\(Int(playback.position))"
        guard shouldBroadcast(key) else { return }
        post(["state": playback.state,
              "name": playback.name,
              "artist": playback.artist,
              "album": playback.album,
              "duration": playback.duration,
              "position": playback.position,
              "databaseID": playback.databaseID])
    case .stopped:
        guard shouldBroadcast("stopped") else { return }
        post(["state": "stopped"])
    case .denied:
        guard shouldBroadcast("denied") else { return }
        post(["state": "denied"])
    case .unsupported(let state):
        guard shouldBroadcast("unsupported|\(state)") else { return }
        post(["state": "unsupported", "detail": state])
    case .failed(let code):
        // Never stay silent: if the helper cannot read the player, the app has
        // to know, otherwise the status just quietly stops updating.
        let key = "failed|\(code)"
        guard shouldBroadcast(key) else { return }
        post(["state": "unavailable", "code": code, "sandbox": sandboxDescription])
    }
}

// Reading the player every five seconds is the point of this helper, so it
// takes an activity assertion: without one App Nap coalesces the timer and the
// reported position drifts away from the player.
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                     reason: "Reading Apple Music playback state")

// Polling and the lifetime check live on separate serial queues, and neither
// uses the main queue. An Apple Event can block for a long time when Music is
// busy, and this helper must still notice that NokoCord is gone and exit
// rather than linger forever.
private let pollQueue = DispatchQueue(label: "com.shiikatan.nokocord.musicwatch.poll")
private let ownerQueue = DispatchQueue(label: "com.shiikatan.nokocord.musicwatch.owner")

let pollTimer = DispatchSource.makeTimerSource(queue: pollQueue)
pollTimer.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(250))
pollTimer.setEventHandler { poll() }
pollTimer.resume()

let ownerTimer = DispatchSource.makeTimerSource(queue: ownerQueue)
ownerTimer.schedule(deadline: .now() + ownerCheckInterval, repeating: ownerCheckInterval)
ownerTimer.setEventHandler {
    if isOwnerRunning() {
        ownerMissingSince = nil
        return
    }
    let missingSince = ownerMissingSince ?? Date()
    ownerMissingSince = missingSince
    if Date().timeIntervalSince(missingSince) > ownerGracePeriod {
        exit(EXIT_SUCCESS)
    }
}
ownerTimer.resume()

_ = activity
dispatchMain()
