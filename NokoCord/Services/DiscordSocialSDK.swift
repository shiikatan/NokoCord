import Foundation
import AppKit

// MARK: - Discord Social SDK (Partner SDK) C Signatures
private typealias Discord_Client_GetVersionMajor_Fn = @convention(c) () -> Int32
private typealias Discord_RunCallbacks_Fn = @convention(c) () -> Void

/// Native integration with Discord Social SDK (`libdiscord_partner_sdk.dylib`) and Discord Local IPC.
public final class DiscordSocialSDKBridge: @unchecked Sendable {
    public static let shared = DiscordSocialSDKBridge()

    private var dylibHandle: UnsafeMutableRawPointer?
    public private(set) var isSocialSDKLoaded = false
    public private(set) var sdkVersion: String?

    // Socket IPC Client
    private var ipcClient: DiscordIPCClient?
    public private(set) var isIPCConnected = false

    public init() {
        loadSocialSDK()
        startIPCClient()
    }

    deinit {
        stopIPCClient()
        if let handle = dylibHandle {
            dlclose(handle)
        }
    }

    /// Attempts to dynamically locate and load `libdiscord_partner_sdk.dylib` without hardcoded user paths.
    private func loadSocialSDK() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidateURLs = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libdiscord_partner_sdk.dylib"),
            home.appendingPathComponent("Downloads/discord_social_sdk/lib/release/libdiscord_partner_sdk.dylib"),
            home.appendingPathComponent("Downloads/discord_social_sdk/lib/debug/libdiscord_partner_sdk.dylib")
        ]

        for url in candidateURLs {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) {
                    dylibHandle = handle
                    isSocialSDKLoaded = true

                    if let sym = dlsym(handle, "Discord_Client_GetVersionMajor") {
                        let getMajor = unsafeBitCast(sym, to: Discord_Client_GetVersionMajor_Fn.self)
                        sdkVersion = "1.\(getMajor())"
                    }
                    break
                }
            }
        }
    }

    /// Starts the background Unix IPC client that speaks Discord's standard IPC framing.
    private func startIPCClient() {
        ipcClient = DiscordIPCClient(clientId: "1038520842044874792") // Apple Music RPC App ID
        ipcClient?.onConnectionChange = { [weak self] connected in
            self?.isIPCConnected = connected
        }
        ipcClient?.connect()
    }

    private func stopIPCClient() {
        ipcClient?.disconnect()
        ipcClient = nil
    }

    /// Dispatches an updated Apple Music Rich Presence activity to Discord.
    public func updatePresence(for track: AppleMusicTrack) {
        // Run Social SDK event loop if loaded
        if isSocialSDKLoaded, let handle = dylibHandle, let sym = dlsym(handle, "Discord_RunCallbacks") {
            let runCallbacks = unsafeBitCast(sym, to: Discord_RunCallbacks_Fn.self)
            runCallbacks()
        }

        // Send via local IPC socket to Discord Desktop
        ipcClient?.setActivity(track: track)
    }

    /// Clears any active rich presence.
    public func clearPresence() {
        ipcClient?.clearActivity()
    }
}

// MARK: - Native Discord Unix Domain Socket IPC Client
public final class DiscordIPCClient: @unchecked Sendable {
    public let clientId: String
    public var onConnectionChange: ((Bool) -> Void)?

    private var socketFd: Int32 = -1
    private var isConnected = false
    private let queue = DispatchQueue(label: "com.nokocord.discord.ipc.client", qos: .utility)
    private var reconnectTimer: DispatchSourceTimer?
    private var currentTrack: AppleMusicTrack?

    public init(clientId: String) {
        self.clientId = clientId
    }

    public func connect() {
        queue.async { [weak self] in
            self?.attemptConnection()
        }
    }

    public func disconnect() {
        queue.async { [weak self] in
            self?.reconnectTimer?.cancel()
            self?.reconnectTimer = nil
            self?.closeSocket()
        }
    }

    public func setActivity(track: AppleMusicTrack) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.currentTrack = track
            guard self.isConnected else {
                self.attemptConnection()
                return
            }
            self.sendActivityPayload(track)
        }
    }

    public func clearActivity() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.currentTrack = nil
            guard self.isConnected else { return }
            let payload: [String: Any] = [
                "cmd": "SET_ACTIVITY",
                "args": [
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "activity": NSNull()
                ],
                "nonce": UUID().uuidString
            ]
            self.sendPacket(opcode: 1, json: payload)
        }
    }

    private func attemptConnection() {
        guard socketFd < 0 else { return }

        // Find active Discord IPC socket path
        let home = FileManager.default.homeDirectoryForCurrentUser
        var pathsToTry: [String] = []
        for i in 0..<10 {
            pathsToTry.append("/tmp/discord-ipc-\(i)")
        }
        let tmpDir = NSTemporaryDirectory()
        if !tmpDir.isEmpty && tmpDir != "/tmp/" {
            for i in 0..<10 {
                pathsToTry.append((tmpDir as NSString).appendingPathComponent("discord-ipc-\(i)"))
            }
        }
        pathsToTry.append(home.appendingPathComponent("Library/Containers/com.shiikatan.nokocord.chiaki/Data/tmp/discord-ipc-0").path)

        for path in pathsToTry {
            if connectToSocket(at: path) {
                break
            }
        }

        if !isConnected {
            scheduleReconnect()
        }
    }

    private func connectToSocket(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            path.withCString { strncpy(ptr, $0, 103) }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, len)
            }
        }

        guard res == 0 else {
            Darwin.close(fd)
            return false
        }

        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        self.socketFd = fd
        self.isConnected = true
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionChange?(true)
        }

        // Send Opcode 0 (Handshake)
        let handshake: [String: Any] = [
            "v": 1,
            "client_id": clientId
        ]
        sendPacket(opcode: 0, json: handshake)

        // Read handshake response
        readHandshakeResponse(fd: fd)

        // If we have a pending track, send it immediately
        if let track = currentTrack {
            sendActivityPayload(track)
        }

        return true
    }

    private func readHandshakeResponse(fd: Int32) {
        var header = [UInt8](repeating: 0, count: 8)
        let bytesRead = Darwin.read(fd, &header, 8)
        guard bytesRead == 8 else { return }

        let length = Int(header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian })
        guard length > 0 && length <= 65536 else { return }

        var payload = [UInt8](repeating: 0, count: length)
        _ = Darwin.read(fd, &payload, length)
    }

    private func sendActivityPayload(_ track: AppleMusicTrack) {
        let presence = track.toGamePresence(clientId: clientId)
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "activity": presence.toDiscordPayload()
            ],
            "nonce": UUID().uuidString
        ]
        sendPacket(opcode: 1, json: payload)
    }

    private func sendPacket(opcode: UInt32, json: [String: Any]) {
        guard socketFd >= 0, let jsonData = try? JSONSerialization.data(withJSONObject: json) else { return }

        var op = opcode.littleEndian
        var len = UInt32(jsonData.count).littleEndian

        var packet = Data()
        packet.append(Data(bytes: &op, count: 4))
        packet.append(Data(bytes: &len, count: 4))
        packet.append(jsonData)

        packet.withUnsafeBytes { rawPtr in
            guard let baseAddr = rawPtr.baseAddress else { return }
            _ = Darwin.write(socketFd, baseAddr, packet.count)
        }
    }

    private func closeSocket() {
        if socketFd >= 0 {
            Darwin.close(socketFd)
            socketFd = -1
        }
        if isConnected {
            isConnected = false
            DispatchQueue.main.async { [weak self] in
                self?.onConnectionChange?(false)
            }
        }
    }

    private func scheduleReconnect() {
        guard reconnectTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.socketFd < 0 {
                self.attemptConnection()
            }
        }
        timer.resume()
        reconnectTimer = timer
    }
}
