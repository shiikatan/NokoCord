import SwiftUI
import ImageIO
import Observation

@MainActor
final class MLImageLoader {
    private struct Pending { let id: UUID; let task: Task<NSImage?, Never>; var consumers: Set<UUID>; let source: String }
    private struct Source { let data: Data; let image: CGImage; let pixels: Int }
    private struct PendingBytes { let task: Task<Source?, Never>; var consumers: Set<UUID> }
    private let memory = NSCache<NSString, NSImage>()
    private var disk: MLDiskCache
    private let cacheBase: URL?
    private let session: URLSession
    private var pending: [String: Pending] = [:]
    private var pendingBytes: [String: PendingBytes] = [:]
    private var stopped = false
    init(session: URLSession? = nil, cacheBase: URL? = nil) {
        self.cacheBase = cacheBase
        disk = MLDiskCache(namespace: "artwork", limit: 96_000_000, base: cacheBase)
        memory.countLimit = 48
        memory.totalCostLimit = 24_000_000
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        self.session = session ?? URLSession(configuration: config)
    }
    private static func permitted(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        return host == "anilist.co" || host.hasSuffix(".anilist.co")
    }
    static func decodeSize(_ pixels: Int) -> Int {
        let clamped = min(max(pixels, 80), 1600)
        let step = clamped <= 256 ? 32 : 64
        return min(1600, ((clamped + step - 1) / step) * step)
    }
    func image(_ url: URL?, pixels: Int) async -> NSImage? {
        guard !stopped, !Task.isCancelled, let url, Self.permitted(url) else { return nil }
        let size = Self.decodeSize(pixels)
        let key = url.absoluteString + "@\(size)"
        if let image = memory.object(forKey: key as NSString) { return image }
        let consumer = UUID()
        if var existing = pending[key] {
            existing.consumers.insert(consumer); pending[key] = existing
            let image = await withTaskCancellationHandler { await existing.task.value } onCancel: { Task { @MainActor [weak self] in self?.release(key, consumer: consumer) } }
            release(key, consumer: consumer)
            return Task.isCancelled || stopped ? nil : image
        }
        let id = UUID()
        // Share original bytes across cover/banner/avatar sizes; decoded images
        // remain size-specific and bounded in the memory cache.
        let bytes = sharedBytes(url, pixels: size, consumer: id)
        let task = Task<NSImage?, Never> {
            guard let source = await bytes.value, !Task.isCancelled else { return nil }
            let decoded = source.pixels == size ? source.image : await Self.decode(source.data, pixels: size)
            guard !Task.isCancelled, let decoded else { return nil }
            return NSImage(cgImage: decoded, size: .zero)
        }
        pending[key] = Pending(id: id, task: task, consumers: [consumer], source: url.absoluteString)
        let image = await withTaskCancellationHandler { await task.value } onCancel: { Task { @MainActor [weak self] in self?.release(key, consumer: consumer) } }
        if pending[key]?.id == id { pending[key] = nil }
        releaseBytes(url.absoluteString, consumer: id)
        guard !stopped, !Task.isCancelled else { return nil }
        if let image { memory.setObject(image, forKey: key as NSString, cost: size * size * 4) }
        return image
    }
    private func release(_ key: String, consumer: UUID) {
        guard var value = pending[key] else { return }
        value.consumers.remove(consumer)
        if value.consumers.isEmpty {
            value.task.cancel(); pending[key] = nil
            releaseBytes(value.source, consumer: value.id)
        }
        else { pending[key] = value }
    }
    private static func decode(_ data: Data, pixels: Int) async -> CGImage? {
        await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
    private func sharedBytes(_ url: URL, pixels: Int, consumer: UUID) -> Task<Source?, Never> {
        let key = url.absoluteString
        if var value = pendingBytes[key] {
            value.consumers.insert(consumer); pendingBytes[key] = value
            return value.task
        }
        let task = Task<Source?, Never> { [session, disk] in
            // Decode once at the first consumer's size, reusing that thumbnail.
            // Invalid disk bytes are discarded and repaired by one shared fetch.
            if let saved = await disk.read(key) {
                guard !Task.isCancelled else { return nil }
                if let image = await Self.decode(saved.data, pixels: pixels) {
                    return Task.isCancelled ? nil : Source(data: saved.data, image: image, pixels: pixels)
                }
                await disk.remove(key, matching: saved)
            }
            do {
                try Task.checkCancellation()
                let (received, response) = try await session.data(from: url)
                guard !Task.isCancelled, received.count < 6_000_000,
                      let finalURL = response.url, Self.permitted(finalURL),
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let image = await Self.decode(received, pixels: pixels), !Task.isCancelled else { return nil }
                await disk.write(received, key: key)
                return Task.isCancelled ? nil : Source(data: received, image: image, pixels: pixels)
            } catch { return nil }
        }
        pendingBytes[key] = PendingBytes(task: task, consumers: [consumer])
        return task
    }
    private func releaseBytes(_ key: String, consumer: UUID) {
        guard var value = pendingBytes[key], value.consumers.remove(consumer) != nil else { return }
        if value.consumers.isEmpty { value.task.cancel(); pendingBytes[key] = nil }
        else { pendingBytes[key] = value }
    }
    func suspend() {
        pending.values.forEach { $0.task.cancel() }; pending.removeAll()
        pendingBytes.values.forEach { $0.task.cancel() }; pendingBytes.removeAll()
    }
    func clear() { suspend(); memory.removeAllObjects() }
    func removeDiskData() async {
        clear()
        let oldDisk = disk
        disk = MLDiskCache(namespace: "artwork", limit: 96_000_000, base: cacheBase)
        await oldDisk.retire(clear: true)
    }
    func stop() { stopped = true; clear(); session.invalidateAndCancel() }
}

@MainActor @Observable
final class MLArtworkState {
    private(set) var image: NSImage?
    private(set) var source: URL?
    private var lease = UUID()
    func load(_ url: URL?, pixels: Int, loader: MLImageLoader) async {
        let id = UUID(); lease = id
        if source != url { source = url; image = nil }
        let value = await loader.image(url, pixels: pixels)
        guard !Task.isCancelled, lease == id else { return }
        if let value { image = value }
    }
}

struct MLArtwork: View {
    @Environment(MLRuntime.self) private var runtime
    @Environment(\.nokoWorkspaceVisible) private var workspaceVisible
    @Environment(\.controlActiveState) private var activeState
    let url: URL?
    var width: CGFloat = 132
    var height: CGFloat = 198
    var radius: CGFloat = 9
    @State private var artwork = MLArtworkState()
    private var pixels: Int { MLImageLoader.decodeSize(Int(max(width, height) * 2)) }
    var body: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.055))
            if artwork.source == url, let image = artwork.image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.tertiary).accessibilityHidden(true) }
        }
        .frame(width: width, height: height).clipped().clipShape(.rect(cornerRadius: radius))
        .accessibilityHidden(true)
        .task(id: "\(url?.absoluteString ?? "")/\(pixels)/\(activeState != .inactive && workspaceVisible)") {
            guard activeState != .inactive && workspaceVisible else { return }
            await artwork.load(url, pixels: pixels, loader: runtime.images)
        }
    }
}
