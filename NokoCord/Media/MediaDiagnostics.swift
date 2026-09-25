@preconcurrency import AVFoundation
import AVFAudio
import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI

/// Local-only diagnostics. This type deliberately has no Discord transport or call state.
@MainActor @Observable
final class MediaDiagnostics {
    private(set) var cameras: [AVCaptureDevice] = []
    var selectedCameraID: String? {
        didSet { if oldValue != selectedCameraID { stopCamera() } }
    }
    private(set) var cameraRunning = false
    private(set) var cameraStarting = false
    private(set) var microphoneRunning = false
    private(set) var microphoneStarting = false
    private(set) var microphoneLevel: Double = 0
    private(set) var message: String?

    let camera = LocalCameraController()
    private let microphone = LocalMicrophoneMeter()
    private let cameraPermission = CapturePermissionGate()
    private let microphonePermission = CapturePermissionGate()
    let screen = ScreenPreviewSession<LocalScreenTarget, NSImage>(discover: {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let displays = content.displays.prefix(8).enumerated().map { LocalScreenTarget.display($0.element, number: $0.offset + 1) }
        let windows = content.windows.prefix(32 - displays.count).map { LocalScreenTarget.window($0) }
        return displays + windows
    }, capture: { window in
        let filter = window.filter
        let configuration = SCStreamConfiguration()
        let aspect = max(0.1, min(10, window.frame.width / max(1, window.frame.height)))
        configuration.width = Int(min(1280, 720 * aspect))
        configuration.height = Int(min(720, 1280 / aspect))
        configuration.showsCursor = false
        let image: CGImage = try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    })

    var previewLayer: AVCaptureVideoPreviewLayer { camera.previewLayer }

    init() {
        refreshCameras()
        camera.onRunningChanged = { [weak self] token, running in
            Task { @MainActor [weak self] in
                guard let self, self.cameraPermission.accepts(token) else { return }; self.cameraRunning = running; self.cameraStarting = false
            }
        }
        microphone.onLevel = { [weak self] token, level in
            Task { @MainActor [weak self] in
                guard let self, self.microphonePermission.accepts(token) else { return }; self.microphoneLevel = level
            }
        }
        microphone.onRunningChanged = { [weak self] token, running in
            Task { @MainActor [weak self] in
                guard let self, self.microphonePermission.accepts(token) else { return }; self.microphoneRunning = running; self.microphoneStarting = false
            }
        }
    }

    func refreshCameras() {
        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
        if !cameras.contains(where: { $0.uniqueID == selectedCameraID }) {
            selectedCameraID = cameras.first?.uniqueID
        }
    }

    func startCamera() {
        // Stop previous capture before awaiting permission or validating a new device.
        stopCamera()
        guard let id = selectedCameraID, let device = cameras.first(where: { $0.uniqueID == id }) else {
            message = String(localized: "Choose a camera first."); return
        }
        cameraStarting = true
        cameraPermission.begin(permission: {
            await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
            }
        }, granted: { [weak self] token in
            guard let self else { return }
            self.message = nil
            self.camera.start(device: device, generation: token) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.cameraPermission.accepts(token) else { return }
                    self.message = error
                }
            }
        }, denied: { [weak self] in
            self?.cameraStarting = false
            self?.message = String(localized: "Camera permission was not granted.")
        })
    }

    func stopCamera() {
        let token = cameraPermission.invalidate()
        cameraRunning = false; cameraStarting = false
        camera.stop(generation: token)
    }

    func startMicrophone() {
        stopMicrophone()
        microphoneStarting = true
        microphonePermission.begin(permission: {
            await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        }, granted: { [weak self] token in
            guard let self else { return }
            self.message = nil
            self.microphone.start(generation: token) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.microphonePermission.accepts(token) else { return }
                    self.message = error
                }
            }
        }, denied: { [weak self] in
            self?.microphoneStarting = false
            self?.message = String(localized: "Microphone permission was not granted.")
        })
    }

    func stopMicrophone() {
        let token = microphonePermission.invalidate()
        microphoneRunning = false; microphoneStarting = false; microphoneLevel = 0
        microphone.stop(generation: token)
    }

    func loadScreenWindows() { screen.loadWindows() }
    func captureWindow(_ window: LocalScreenTarget) { screen.captureWindow(window) }

    func stopAll() {
        stopCamera()
        stopMicrophone()
        screen.stop()
    }

}

private final class CameraSessionBackend: CaptureSessionBackend {
    let session: AVCaptureSession
    let device: AVCaptureDevice
    var isRunning: Bool { session.isRunning }

    init(session: AVCaptureSession, device: AVCaptureDevice) { self.session = session; self.device = device }

    func releaseResources() { Self.release(session) }
    static func release(_ session: AVCaptureSession) {
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.commitConfiguration()
    }

    func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw NSError(domain: "LocalCamera", code: 1) }
        session.addInput(input)
    }
    func start() throws { session.startRunning() }
}

final class LocalCameraController {
    let previewLayer: AVCaptureVideoPreviewLayer
    var onRunningChanged: ((Int, Bool) -> Void)?
    private let queue = DispatchQueue(label: "com.nokocord.local-camera", qos: .userInitiated)
    private let session = AVCaptureSession()

    deinit {
        let session = self.session
        queue.async { CameraSessionBackend.release(session) }
    }

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
    }

    func start(device: AVCaptureDevice, generation: Int, completion: @escaping (String?) -> Void) {
        queue.async { [self] in
            var failure: String?
            do { try CaptureSessionLifecycle.start(CameraSessionBackend(session: self.session, device: device)) }
            catch { failure = String(localized: "Camera could not be started. Check the device and try again.") }
            let running = failure == nil && self.session.isRunning
            DispatchQueue.main.async { [weak self] in
                self?.onRunningChanged?(generation, running); completion(failure)
            }
        }
    }

    func stop(generation: Int) {
        queue.async { [self] in
            CameraSessionBackend.release(self.session)
            DispatchQueue.main.async { [weak self] in self?.onRunningChanged?(generation, false) }
        }
    }
}

private enum MicrophoneBackendError: Error { case unavailableFormat }

/// All lifecycle methods and onLevel assignment run on the meter's serial queue.
private final class MicrophoneSessionBackend: CaptureSessionBackend {
    private let engine = AVAudioEngine()
    private var installedTap = false
    private var prepared = false
    var onLevel: ((Double) -> Void)?
    var isRunning: Bool { engine.isRunning }

    func releaseResources() {
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        if prepared || engine.isRunning { engine.stop(); engine.reset(); prepared = false }
    }

    func configure() throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicrophoneBackendError.unavailableFormat }
        let publish = onLevel
        // This timestamp belongs to this tap alone, never to a replacement tap.
        var lastMeterTime = CFAbsoluteTimeGetCurrent()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastMeterTime >= 0.1 else { return }
            lastMeterTime = now
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += data[index] * data[index] }
            let level = min(1, max(0, Double(sqrt(sum / Float(buffer.frameLength))) * 4))
            publish?(level)
        }
        installedTap = true
    }

    func start() throws {
        prepared = true
        engine.prepare()
        try engine.start()
    }
}

final class LocalMicrophoneMeter {
    var onLevel: ((Int, Double) -> Void)?
    var onRunningChanged: ((Int, Bool) -> Void)?
    private let backend = MicrophoneSessionBackend()
    private let queue = DispatchQueue(label: "com.nokocord.local-microphone", qos: .userInitiated)

    deinit {
        let backend = self.backend
        queue.async { backend.releaseResources() }
    }

    func start(generation: Int, completion: @escaping (String?) -> Void) {
        queue.async { [self] in
            self.backend.onLevel = { [weak self] level in
                DispatchQueue.main.async { [weak self] in self?.onLevel?(generation, level) }
            }
            var failure: String?
            do { try CaptureSessionLifecycle.start(self.backend) }
            catch MicrophoneBackendError.unavailableFormat { failure = String(localized: "Microphone format is unavailable.") }
            catch { failure = String(localized: "Microphone could not be started.") }
            let running = failure == nil && self.backend.isRunning
            DispatchQueue.main.async { [weak self] in self?.onRunningChanged?(generation, running); completion(failure) }
        }
    }

    func stop(generation: Int) {
        queue.async { [self] in
            self.backend.releaseResources()
            DispatchQueue.main.async { [weak self] in self?.onRunningChanged?(generation, false); self?.onLevel?(generation, 0) }
        }
    }
}

struct CameraPreviewView: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    func makeNSView(context: Context) -> NSView {
        let view = PreviewContainerView(previewLayer: previewLayer); view.wantsLayer = true; view.layer?.addSublayer(previewLayer); return view
    }
    func updateNSView(_ view: NSView, context: Context) { previewLayer.frame = view.bounds }
    static func dismantleNSView(_ view: NSView, coordinator: ()) { view.layer?.sublayers?.forEach { $0.removeFromSuperlayer() } }
}

private final class PreviewContainerView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    init(previewLayer: AVCaptureVideoPreviewLayer) { self.previewLayer = previewLayer; super.init(frame: .zero) }
    required init?(coder: NSCoder) { return nil }
    override func layout() { super.layout(); previewLayer.frame = bounds }
}
