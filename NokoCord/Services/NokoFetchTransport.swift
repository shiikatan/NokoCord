import Foundation
import Darwin

protocol NokoFetchDownloading: Sendable {
    func download(_ url: URL, to destination: URL, limit: Int64, expectedSize: Int64?,
                  progress: @escaping @Sendable (Int64) -> Void) async throws
}

struct NokoFetchTransport: NokoFetchDownloading {
    var configuration: @Sendable () -> URLSessionConfiguration = { .ephemeral }
    func download(_ url: URL, to destination: URL, limit: Int64, expectedSize: Int64?,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard Self.allowsOrigin(url) else { throw NokoFetchError.unsafeURL }
        let transfer = try NokoFetchTransfer(url: url, destination: destination, limit: limit,
                                             expectedSize: expectedSize, configuration: configuration(), progress: progress)
        try await withTaskCancellationHandler {
            try await transfer.run()
        } onCancel: {
            transfer.cancel()
        }
    }

    static func allowsOrigin(_ url: URL) -> Bool {
        if (1...10).contains(where: {
            url.absoluteString == "https://api.github.com/repos/shiikatan/NokoCord/releases?per_page=100&page=\($0)"
        }) { return true }
        let parts = url.pathComponents
        guard parts.count == 7, parts[5].hasPrefix("maomao-M"),
              let version = try? ManualUpdateVersion(String(parts[5].dropFirst(8))),
              parts[5] == "maomao-M\(version)" else { return false }
        let prefix = "\(NokoFetchSelection.repository)/releases/download/\(parts[5])/"
        return url.absoluteString == prefix + "SHA256SUMS"
            || url.absoluteString == prefix + "NokoCord-Maomao-M\(version).zip"
    }

    static func allowsRedirect(from original: URL, to target: URL) -> Bool {
        guard allowsOrigin(original), target.scheme == "https", target.user == nil, target.password == nil,
              target.port == nil, target.fragment == nil else { return false }
        // Metadata must stay on the fixed API endpoint. Release downloads may
        // redirect only to the repository's real GitHub release-asset CDN path.
        if target == original { return true }
        return original.host == "github.com"
            && original.path.hasPrefix("/shiikatan/NokoCord/releases/download/maomao-M")
            && target.host == "release-assets.githubusercontent.com"
            && target.path.hasPrefix("/github-production-release-asset/1379001893/")
    }
}

/// A short-lived, cookie-free session per request. Delegate callbacks stream
/// directly to a bounded private file and report byte progress without polling.
/// The lock also covers cancellation before the continuation has been installed.
private final class NokoFetchTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let limit: Int64
    private let expectedSize: Int64?
    private let progress: @Sendable (Int64) -> Void
    private let configuration: URLSessionConfiguration
    private var descriptor: Int32
    private var received: Int64 = 0
    private var redirects = 0
    private var reportedPercent = -1
    private var done = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?

    init(url: URL, destination: URL, limit: Int64, expectedSize: Int64?, configuration: URLSessionConfiguration,
         progress: @escaping @Sendable (Int64) -> Void) throws {
        try MaomaoDataPaths.validateNoSymlinkComponents(at: destination)
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NokoFetchError.storage }
        self.url = url
        self.limit = limit
        self.expectedSize = expectedSize
        self.progress = progress
        self.configuration = configuration
        descriptor = fd
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock {
                guard !done else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = configuration
                config.httpCookieStorage = nil
                config.httpShouldSetCookies = false
                config.urlCredentialStorage = nil
                config.urlCache = nil
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.timeoutIntervalForRequest = 30
                config.timeoutIntervalForResource = 600
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                self.session = session
                var request = URLRequest(url: url)
                request.setValue("NokoCord-NokoFetch", forHTTPHeaderField: "User-Agent")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                if url.host == "api.github.com" {
                    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
                }
                session.dataTask(with: request).resume()
            }
        }
    }

    func cancel() { lock.withLock { finishLocked(CancellationError()) } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.withLock {
            redirects += 1
            guard !done, redirects <= 5, let target = request.url,
                  NokoFetchTransport.allowsRedirect(from: url, to: target) else {
                completionHandler(nil)
                finishLocked(NokoFetchError.unsafeURL)
                return
            }
            completionHandler(request)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.withLock {
            guard !done else { completionHandler(.cancel); return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                completionHandler(.cancel)
                finishLocked(NokoFetchError.http((response as? HTTPURLResponse)?.statusCode ?? 0))
                return
            }
            guard response.expectedContentLength <= limit else {
                completionHandler(.cancel)
                finishLocked(NokoFetchError.oversized)
                return
            }
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            guard !done else { return }
            guard Int64(data.count) <= limit - received else { finishLocked(NokoFetchError.oversized); return }
            let written = data.withUnsafeBytes { bytes -> Bool in
                var offset = 0
                while offset < bytes.count {
                    let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            guard written else { finishLocked(NokoFetchError.storage); return }
            received += Int64(data.count)
            let percent = expectedSize.map { Int(received * 100 / max(1, $0)) } ?? 0
            if percent != reportedPercent {
                reportedPercent = percent
                progress(received)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock {
            guard !done else { return }
            if let error {
                let code = (error as? URLError)?.code
                finishLocked(code == .cancelled ? CancellationError() : code == .timedOut ? NokoFetchError.timeout : NokoFetchError.network)
            } else if received == 0 || (expectedSize != nil && received != expectedSize) {
                finishLocked(NokoFetchError.incomplete)
            } else if fsync(descriptor) != 0 {
                finishLocked(NokoFetchError.storage)
            } else {
                finishLocked(nil)
            }
        }
    }

    private func finishLocked(_ error: Error?) {
        guard !done else { return }
        done = true
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
        let continuation = self.continuation
        self.continuation = nil
        session?.invalidateAndCancel()
        session = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
}
