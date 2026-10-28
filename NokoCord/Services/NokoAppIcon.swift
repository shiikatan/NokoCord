import AppKit
import Observation

/// The installed signed bundle selects the icon; Dock keeps its native material.
@MainActor @Observable
final class NokoAppIconController {
    static let shared = NokoAppIconController()
    private(set) var selection: NokoAppIcon
    var pendingIcon: NokoAppIcon?
    private(set) var errorMessage: String?
    private(set) var isPreparing = false
    private(set) var isInstalling = false
    private(set) var progressText = ""
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private let service: NokoIconSwitchService

    init(bundle: Bundle = .main, service: NokoIconSwitchService? = nil) {
        selection = .installed(in: bundle)
        self.service = service ?? NokoIconSwitchService(currentApp: bundle.bundleURL)
    }
    func select(_ icon: NokoAppIcon) {
        guard !isPreparing, icon != selection else { return }
        errorMessage = nil; pendingIcon = icon
    }
    func cancelPreparation() { if !isInstalling { operation?.cancel() } }

    func confirm(_ icon: NokoAppIcon) {
        guard icon != selection, !isPreparing else { return }
        let request = UUID(); operationID = request
        pendingIcon = nil; isPreparing = true; errorMessage = nil; progressText = "Checking icon files…"
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isPreparing = false; self.isInstalling = false; self.operation = nil }
            do {
                let candidate = try await service.prepare(icon) { [weak self] text in
                    Task { @MainActor [weak self] in
                        guard let self, self.operationID == request, self.isPreparing, !self.isInstalling else { return }
                        self.progressText = text
                    }
                }
                if Task.isCancelled { await service.discard(candidate); throw CancellationError() }
                isInstalling = true; progressText = "Changing icon and relaunching…"
                try await service.apply(candidate)
                NokoApplicationDelegate.requestTermination(withdrawDockTile: true)
            } catch is CancellationError {
                errorMessage = "Cancelled. Nothing was changed."
            } catch NokoFetchError.http(404) {
                errorMessage = "Icon switching files for this version are not available yet. Try again after the release is published."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
