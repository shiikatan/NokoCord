import Foundation
import AppKit
import Observation

/// Native Discord IPC Daemon listening on `/tmp/discord-ipc-0` to enable Game Rich Presence.
@MainActor @Observable
public final class GamePresenceService: NSObject {
    public static let shared = GamePresenceService()

    public private(set) var activePresence: GamePresence?
    public var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                startServer()
            } else {
                stopServer()
                clearPresence()
            }
        }
    }

    public var onPresenceChange: ((GamePresence?) -> Void)?

    @ObservationIgnored private var serverFds: [Int32] = []
    @ObservationIgnored private var serverSources: [DispatchSourceRead] = []
    @ObservationIgnored private var clientSources: [Int32: DispatchSourceRead] = [:]
    @ObservationIgnored private var activeClientFds: Set<Int32> = []
    @ObservationIgnored private var clientMetadata: [Int32: String] = [:] // fd -> clientId
    @ObservationIgnored private var boundPaths: [String] = []
    @ObservationIgnored private let queue = DispatchQueue(label: "com.nokocord.gamepresence.ipc", qos: .userInitiated)

    public override init() {
        super.init()
        // Do not auto-bind sockets on startup; enabled on demand
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopServer()
            }
        }
    }

    isolated deinit {
        stopServer()
    }

    public func clearPresence() {
        activePresence = nil
        onPresenceChange?(nil)
    }

    public func startServer() {
        guard serverFds.isEmpty else { return }

        // Standard Discord IPC socket paths on macOS
        var pathsToTry = ["/tmp/discord-ipc-0", "/tmp/discord-ipc-1"]
        let tmpDir = NSTemporaryDirectory()
        if !tmpDir.isEmpty && tmpDir != "/tmp/" {
            pathsToTry.append((tmpDir as NSString).appendingPathComponent("discord-ipc-0"))
        }

        for path in pathsToTry {
            bindSocket(at: path)
        }
    }

    public func stopServer() {
        for src in serverSources {
            src.cancel()
        }
        serverSources.removeAll()

        for (_, src) in clientSources {
            src.cancel()
        }
        clientSources.removeAll()

        for fd in serverFds {
            Darwin.close(fd)
        }
        serverFds.removeAll()

        for fd in activeClientFds {
            Darwin.close(fd)
        }
        activeClientFds.removeAll()
        clientMetadata.removeAll()

        for path in boundPaths {
            Darwin.unlink(path)
        }
        boundPaths.removeAll()
    }

    private func bindSocket(at path: String) {
        Darwin.unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            path.withCString { strncpy(ptr, $0, 103) }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, len)
            }
        }

        guard bindRes == 0, Darwin.listen(fd, 5) == 0 else {
            Darwin.close(fd)
            return
        }

        serverFds.append(fd)
        boundPaths.append(path)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self = self, source != nil else { return }
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(fd, sa, &clientLen)
                }
            }
            if clientFd >= 0 {
                var nosigpipe: Int32 = 1
                setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
                Task { @MainActor [weak self] in
                    self?.acceptClient(clientFd)
                }
            }
        }
        source.resume()
        serverSources.append(source)
    }

    private func acceptClient(_ fd: Int32) {
        activeClientFds.insert(fd)

        let clientSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        clientSources[fd] = clientSource
        var buffer = Data()

        clientSource.setEventHandler { [weak self, weak clientSource] in
            guard let self = self else { return }
            var temp = [UInt8](repeating: 0, count: 4096)
            let bytesRead = Darwin.read(fd, &temp, temp.count)
            if bytesRead <= 0 {
                clientSource?.cancel()
                Task { @MainActor [weak self] in
                    self?.handleClientDisconnect(fd)
                }
                return
            }

            // Guard against unbounded memory allocation / malicious buffer flood (limit buffer to 128KB)
            if buffer.count + bytesRead > 131072 {
                clientSource?.cancel()
                Task { @MainActor [weak self] in
                    self?.handleClientDisconnect(fd)
                }
                return
            }

            buffer.append(temp, count: bytesRead)

            while buffer.count >= 8 {
                let opcode = buffer.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
                let length = Int(buffer.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian })
                // Discord IPC payload length must not exceed standard 64KB packet limits
                guard length >= 0 && length <= 65536 else {
                    clientSource?.cancel()
                    Task { @MainActor [weak self] in
                        self?.handleClientDisconnect(fd)
                    }
                    return
                }
                guard buffer.count >= 8 + length else { break }

                let payloadData = buffer.subdata(in: 8..<(8 + length))
                buffer.removeSubrange(0..<(8 + length))

                if let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                    Task { @MainActor [weak self] in
                        self?.handlePacket(fd: fd, opcode: opcode, json: json)
                    }
                }
            }
        }
        clientSource.resume()
    }

    private func handlePacket(fd: Int32, opcode: UInt32, json: [String: Any]) {
        switch opcode {
        case 0: // HANDSHAKE
            let clientIdStr = (json["client_id"] as? String) ?? "\(json["client_id"] as? Int ?? 0)"
            clientMetadata[fd] = clientIdStr

            let readyResponse: [String: Any] = [
                "cmd": "DISPATCH",
                "evt": "READY",
                "data": [
                    "v": 1,
                    "config": [
                        "cdn_host": "cdn.discordapp.com",
                        "api_endpoint": "//discord.com/api",
                        "environment": "production"
                    ],
                    "user": [
                        "id": "100000000000000000",
                        "username": "NokoCord",
                        "discriminator": "0"
                    ]
                ],
                "nonce": NSNull()
            ]
            sendPacket(fd: fd, opcode: 1, json: readyResponse)

        case 1: // FRAME
            let cmd = json["cmd"] as? String
            let nonce = json["nonce"] as? String

            if cmd == "SET_ACTIVITY" {
                let args = json["args"] as? [String: Any]
                let activityDict = args?["activity"] as? [String: Any]
                let pid = args?["pid"] as? Int

                if let act = activityDict, !act.isEmpty, isEnabled {
                    let clientId = clientMetadata[fd] ?? "0"
                    let presence = parsePresence(from: act, clientId: clientId, pid: pid)
                    self.activePresence = presence
                    self.onPresenceChange?(presence)

                    let reply: [String: Any] = [
                        "cmd": "SET_ACTIVITY",
                        "data": act,
                        "evt": NSNull(),
                        "nonce": nonce ?? NSNull()
                    ]
                    sendPacket(fd: fd, opcode: 1, json: reply)
                } else {
                    // Cleared activity
                    self.activePresence = nil
                    self.onPresenceChange?(nil)

                    let reply: [String: Any] = [
                        "cmd": "SET_ACTIVITY",
                        "data": NSNull(),
                        "evt": NSNull(),
                        "nonce": nonce ?? NSNull()
                    ]
                    sendPacket(fd: fd, opcode: 1, json: reply)
                }
            } else if cmd == "PING" {
                sendPacket(fd: fd, opcode: 4, json: json) // PONG
            }

        case 2: // CLOSE
            handleClientDisconnect(fd)

        case 3: // PING
            sendPacket(fd: fd, opcode: 4, json: json) // PONG

        default:
            break
        }
    }

    private static func sanitize(_ string: String, maxLength: Int) -> String {
        let clean = string.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        return String(clean.prefix(maxLength))
    }

    private func parsePresence(from dict: [String: Any], clientId: String, pid: Int?) -> GamePresence {
        let rawName = (dict["name"] as? String) ?? (dict["details"] as? String) ?? "Active Game"
        let name = Self.sanitize(rawName, maxLength: 128)
        let details = (dict["details"] as? String).map { Self.sanitize($0, maxLength: 128) }
        let state = (dict["state"] as? String).map { Self.sanitize($0, maxLength: 128) }
        let safeClientId = Self.sanitize(clientId, maxLength: 32)

        var startDate: Date?
        var endDate: Date?
        if let timestamps = dict["timestamps"] as? [String: Any] {
            if let start = timestamps["start"] as? Double {
                startDate = Date(timeIntervalSince1970: start > 10000000000 ? start / 1000 : start)
            } else if let start = timestamps["start"] as? Int {
                let s = Double(start)
                startDate = Date(timeIntervalSince1970: s > 10000000000 ? s / 1000 : s)
            }
            if let end = timestamps["end"] as? Double {
                endDate = Date(timeIntervalSince1970: end > 10000000000 ? end / 1000 : end)
            } else if let end = timestamps["end"] as? Int {
                let e = Double(end)
                endDate = Date(timeIntervalSince1970: e > 10000000000 ? e / 1000 : e)
            }
        }

        var largeImg: String?
        var largeTxt: String?
        var smallImg: String?
        var smallTxt: String?
        if let assets = dict["assets"] as? [String: Any] {
            largeImg = (assets["large_image"] as? String).map { Self.sanitize($0, maxLength: 128) }
            largeTxt = (assets["large_text"] as? String).map { Self.sanitize($0, maxLength: 128) }
            smallImg = (assets["small_image"] as? String).map { Self.sanitize($0, maxLength: 128) }
            smallTxt = (assets["small_text"] as? String).map { Self.sanitize($0, maxLength: 128) }
        }

        return GamePresence(
            clientId: safeClientId,
            pid: pid,
            name: name,
            details: details,
            state: state,
            startTimestamp: startDate ?? Date(),
            endTimestamp: endDate,
            largeImageKey: largeImg,
            largeImageText: largeTxt,
            smallImageKey: smallImg,
            smallImageText: smallTxt
        )
    }

    private func handleClientDisconnect(_ fd: Int32) {
        if let src = clientSources.removeValue(forKey: fd) {
            src.cancel()
        }
        activeClientFds.remove(fd)
        Darwin.close(fd)
        clientMetadata.removeValue(forKey: fd)
        if activeClientFds.isEmpty {
            activePresence = nil
            onPresenceChange?(nil)
        }
    }

    private func sendPacket(fd: Int32, opcode: UInt32, json: [String: Any]) {
        queue.async {
            guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
            var header = Data()
            var op = opcode.littleEndian
            var len = UInt32(data.count).littleEndian
            header.append(Data(bytes: &op, count: 4))
            header.append(Data(bytes: &len, count: 4))
            header.append(data)
            _ = header.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, header.count) }
        }
    }
}
