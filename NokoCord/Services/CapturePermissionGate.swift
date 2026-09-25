import Foundation

/// Owns pending local permission work. Revocation invalidates both permission
/// results and controller callbacks, even when a platform prompt cannot cancel.
@MainActor
final class CapturePermissionGate {
    private(set) var generation = 0
    private var request: Task<Void, Never>?

    deinit { request?.cancel() }

    func accepts(_ token: Int) -> Bool { token == generation }

    @discardableResult
    func invalidate() -> Int {
        generation += 1
        request?.cancel()
        request = nil
        return generation
    }

    @discardableResult
    func begin(permission: @escaping @Sendable () async -> Bool,
               granted: @escaping @MainActor (Int) -> Void,
               denied: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        let token = invalidate()
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let allowed = await permission()
            guard !Task.isCancelled, let self, self.accepts(token) else { return }
            self.request = nil
            if allowed { granted(token) } else { denied() }
        }
        request = task
        return task
    }
}
