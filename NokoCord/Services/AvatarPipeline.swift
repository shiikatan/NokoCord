import AppKit
import ImageIO

actor AvatarPipeline {
    static let shared = AvatarPipeline()
    private let http = HTTPClient()
    private var cache: [URL: CGImage] = [:]
    private var generation = UUID()
    private var order: [URL] = []
    private var pending: [URL: Task<CGImage?, Never>] = [:]
    func image(for url: URL) async -> CGImage? {
        guard url.scheme == "https", url.host == "cdn.discordapp.com", url.user == nil, url.password == nil else { return nil }
        if let image = cache[url] {
            order.removeAll { $0 == url }; order.append(url)
            return image
        }
        if let task = pending[url] { return await task.value }
        guard pending.count < 16 else { return nil }
        let http = http
        let id = generation
        let task = Task<CGImage?, Never> {
            guard let data = try? await http.request(URLRequest(url: url)),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192,
                  width * height <= 16_777_216 else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceThumbnailMaxPixelSize: 128,
                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceShouldCacheImmediately: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        pending[url] = task
        let result = await task.value
        guard generation == id else { return nil }
        pending[url] = nil
        if let result {
            cache[url] = result; order.append(url)
            while order.count > 128 { cache[order.removeFirst()] = nil }
        }
        return result
    }
    func clear() { generation = UUID(); cache.removeAll(); order.removeAll(); pending.values.forEach { $0.cancel() }; pending.removeAll() }
}

enum DiscordImageURL {
    static func avatar(id: String, hash: String?) -> URL? { make(category: "avatars", id: id, hash: hash) }
    static func guild(id: String, hash: String?) -> URL? { make(category: "icons", id: id, hash: hash) }
    private static func make(category: String, id: String, hash: String?) -> URL? {
        guard !id.isEmpty, id.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let hash, !hash.isEmpty,
              hash.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95 }) else { return nil }
        // A static PNG respects Reduce Motion and avoids animated-avatar work.
        return URL(string: "https://cdn.discordapp.com/\(category)/\(id)/\(hash).png?size=128")
    }
}
