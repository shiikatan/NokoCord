/// Called only on the owning controller's serial queue.
protocol CaptureSessionBackend {
    var isRunning: Bool { get }
    func releaseResources()
    func configure() throws
    func start() throws
}

enum CaptureSessionStartError: Error { case notRunning }

enum CaptureSessionLifecycle {
    static func start(_ backend: any CaptureSessionBackend) throws {
        backend.releaseResources()
        do {
            try backend.configure()
            try backend.start()
            guard backend.isRunning else { throw CaptureSessionStartError.notRunning }
        } catch {
            backend.releaseResources()
            throw error
        }
    }
}
