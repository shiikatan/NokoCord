import AppKit
import Observation
import WebKit

struct BrowserDownloadRecord: Identifiable {
    enum Status { case choosing, downloading, complete, cancelled, failed }
    let id: UUID
    var name = String(localized: "Download")
    var fraction = 0.0
    var status: Status = .choosing
}

@MainActor @Observable
final class BrowserDownloads: NSObject, WKDownloadDelegate {
    private(set) var records: [BrowserDownloadRecord] = []
    private(set) var error: String?
    @ObservationIgnored private var transfers: [ObjectIdentifier: Transfer] = [:]
    @ObservationIgnored private var panel: NSSavePanel?
    private struct Transfer {
        let download: WKDownload
        let id: UUID
        var observation: NSKeyValueObservation?
        var destination: URL?
        var scoped = false
        var stagingDirectory: URL?
        var stagedFile: URL?
    }
    func attach(_ download: WKDownload) {
        guard transfers[ObjectIdentifier(download)] == nil else { return }
        guard transfers.count < 3 else {
            download.cancel { _ in }
            error = String(localized: "Finish or cancel a download before starting another.")
            return
        }
        let id = UUID()
        transfers[ObjectIdentifier(download)] = Transfer(download: download, id: id)
        records.append(.init(id: id))
        while records.count > 20, let index = records.firstIndex(where: { [.complete, .cancelled, .failed].contains($0.status) }) {
            records.remove(at: index)
        }
        download.delegate = self
    }
    func cancel(_ id: UUID) {
        guard let (key, transfer) = transfers.first(where: { $0.value.id == id }) else { return }
        transfer.download.cancel { _ in }
        finish(key, status: .cancelled)
    }
    func cancelAll() {
        panel?.cancel(nil)
        for key in Array(transfers.keys) {
            transfers[key]?.download.cancel { _ in }
            finish(key, status: .cancelled)
        }
        records.removeAll()
        error = nil
    }
    func dismissError() { error = nil }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let key = ObjectIdentifier(download)
        guard let transfer = transfers[key], panel == nil,
              let window = download.webView?.window ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            completionHandler(nil); finish(key, status: .cancelled); return
        }
        let save = NSSavePanel()
        save.nameFieldStringValue = BrowserPolicy.filename(suggestedFilename)
        update(transfer.id) { $0.name = save.nameFieldStringValue }
        save.title = String(localized: "Save Discord download")
        save.canCreateDirectories = true
        panel = save
        save.beginSheetModal(for: window) { [weak self] result in
            guard let self else { completionHandler(nil); return }
            self.panel = nil
            guard result == .OK, let url = save.url, self.transfers[key] != nil else {
                completionHandler(nil); self.finish(key, status: .cancelled); return
            }
            let scoped = url.startAccessingSecurityScopedResource()
            self.transfers[key]?.destination = url
            self.transfers[key]?.scoped = scoped
            var downloadURL = url
            if FileManager.default.fileExists(atPath: url.path) {
                guard EditionIdentity.current?.id == "maomao" else {
                    self.error = String(localized: "Choose a new filename. This download cannot overwrite an existing file.")
                    completionHandler(nil); self.finish(key, status: .failed); return
                }
                // NSSavePanel has already obtained replacement approval. WKDownload
                // requires a nonexistent destination, so preserve the old file until
                // the new download completes, then replace it on the same volume.
                do {
                    let directory = try FileManager.default.url(for: .itemReplacementDirectory,
                        in: .userDomainMask, appropriateFor: url, create: true)
                    downloadURL = directory.appendingPathComponent(url.lastPathComponent)
                    self.transfers[key]?.stagingDirectory = directory
                    self.transfers[key]?.stagedFile = downloadURL
                } catch {
                    self.error = String(localized: "The replacement could not be prepared. Choose another save location and retry.")
                    completionHandler(nil); self.finish(key, status: .failed); return
                }
            }
            self.update(transfer.id) { $0.name = url.lastPathComponent; $0.status = .downloading }
            self.transfers[key]?.observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor [weak self] in
                    guard let self, self.transfers[key] != nil else { return }
                    self.update(transfer.id) { $0.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0 }
                }
            }
            completionHandler(downloadURL)
        }
    }
    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let transfer = transfers[key] else { return }
        if let staged = transfer.stagedFile, let destination = transfer.destination {
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
                } else {
                    try FileManager.default.moveItem(at: staged, to: destination)
                }
            } catch {
                self.error = String(localized: "The downloaded file could not replace the existing file. Choose another save location and retry.")
                finish(key, status: .failed)
                return
            }
        }
        finish(key, status: .complete)
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard transfers[ObjectIdentifier(download)] != nil else { return }
        finish(ObjectIdentifier(download), status: .failed)
        self.error = String(localized: "The download failed. Retry from Discord when the connection is available.")
        // Resume data can carry request/session details; do not retain or log it.
    }
    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        let url = request.url
        decisionHandler(url?.scheme == "https" && url?.user == nil && url?.password == nil ? .allow : .cancel)
    }
    private func finish(_ key: ObjectIdentifier, status: BrowserDownloadRecord.Status) {
        guard let transfer = transfers.removeValue(forKey: key) else { return }
        transfer.observation?.invalidate()
        if let directory = transfer.stagingDirectory { try? FileManager.default.removeItem(at: directory) }
        if transfer.scoped { transfer.destination?.stopAccessingSecurityScopedResource() }
        update(transfer.id) { $0.status = status; if status == .complete { $0.fraction = 1 } }
    }
    private func update(_ id: UUID, _ change: (inout BrowserDownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
    }
}
