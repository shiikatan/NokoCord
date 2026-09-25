import Foundation
import Observation

/// Local preview state with injected platform operations, never a screen stream.
@MainActor @Observable
final class ScreenPreviewSession<Window, Preview> {
    private(set) var windows: [Window] = []
    private(set) var preview: Preview?
    private(set) var errorMessage: String?
    private(set) var isBusy = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private let discover: @MainActor () async throws -> [Window]
    @ObservationIgnored private let capture: @MainActor (Window) async throws -> Preview

    init(discover: @escaping @MainActor () async throws -> [Window],
         capture: @escaping @MainActor (Window) async throws -> Preview) {
        self.discover = discover; self.capture = capture
    }

    deinit { operation?.cancel() }

    @discardableResult
    func loadWindows() -> Task<Void, Never> {
        stop()
        isBusy = true
        let token = generation
        let discover = discover
        let previous = operation
        let task = Task { [weak self] in
            // Platform capture can ignore cancellation; serialize replacements.
            await previous?.value
            do {
                try Task.checkCancellation()
                let windows = try await discover()
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.windows = Array(windows.prefix(32)); self.isBusy = false
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.errorMessage = String(localized: "Screen content is unavailable.")
                self.isBusy = false
            }
        }
        operation = task
        return task
    }

    @discardableResult
    func captureWindow(_ window: Window) -> Task<Void, Never> {
        operation?.cancel(); generation = UUID()
        preview = nil; errorMessage = nil; isBusy = true
        let token = generation
        let capture = capture
        let previous = operation
        let task = Task { [weak self] in
            // Platform capture can ignore cancellation; serialize replacements.
            await previous?.value
            do {
                try Task.checkCancellation()
                let preview = try await capture(window)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.preview = preview; self.isBusy = false
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.errorMessage = String(localized: "A preview frame could not be captured.")
                self.isBusy = false
            }
        }
        operation = task
        return task
    }

    func stop() {
        operation?.cancel(); generation = UUID()
        windows = []; preview = nil; errorMessage = nil; isBusy = false
    }
}
