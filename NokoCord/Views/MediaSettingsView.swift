import AVFoundation
import ScreenCaptureKit
import SwiftUI

struct MediaSettingsView: View {
    @State private var diagnostics = MediaDiagnostics()

    var body: some View {
        Form {
            Section {
                Text("These checks use local macOS capture only. Nothing is sent to Discord or a call.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Label("Local diagnostics", systemImage: "waveform.and.mic") }

            Section("Camera") {
                Picker("Device", selection: $diagnostics.selectedCameraID) {
                    Text("Choose a camera").tag(Optional<String>.none)
                    ForEach(diagnostics.cameras, id: \.uniqueID) { device in Text(device.localizedName).tag(Optional(device.uniqueID)) }
                }
                HStack {
                    Button("Refresh devices", systemImage: "arrow.clockwise") { diagnostics.refreshCameras() }
                    Button((diagnostics.cameraRunning || diagnostics.cameraStarting) ? String(localized: "Stop preview") : String(localized: "Start local preview"), systemImage: (diagnostics.cameraRunning || diagnostics.cameraStarting) ? "stop.fill" : "video.fill") {
                        (diagnostics.cameraRunning || diagnostics.cameraStarting) ? diagnostics.stopCamera() : diagnostics.startCamera()
                    }.disabled(diagnostics.selectedCameraID == nil && !diagnostics.cameraRunning && !diagnostics.cameraStarting)
                }
                CameraPreviewView(previewLayer: diagnostics.previewLayer)
                    .frame(height: 180).background(.black, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(String(localized: "Local camera preview"))
            }

            Section("Microphone") {
                HStack {
                    Button((diagnostics.microphoneRunning || diagnostics.microphoneStarting) ? String(localized: "Stop microphone") : String(localized: "Test microphone"), systemImage: (diagnostics.microphoneRunning || diagnostics.microphoneStarting) ? "stop.fill" : "mic.fill") {
                        (diagnostics.microphoneRunning || diagnostics.microphoneStarting) ? diagnostics.stopMicrophone() : diagnostics.startMicrophone()
                    }
                    ProgressView(value: diagnostics.microphoneLevel).frame(maxWidth: 180)
                    Text(diagnostics.microphoneStarting ? String(localized: "Starting…") : (diagnostics.microphoneRunning ? String(localized: "Listening locally") : String(localized: "Stopped"))).foregroundStyle(.secondary)
                }
            }

            Section("Screen or window") {
                Button("List displays and windows", systemImage: "rectangle.on.rectangle") { diagnostics.loadScreenWindows() }
                if diagnostics.screen.isBusy {
                    HStack { ProgressView().controlSize(.small); Button("Cancel screen check") { diagnostics.screen.stop() } }
                }
                if let error = diagnostics.screen.errorMessage { Text(error).foregroundStyle(.secondary) }
                if !diagnostics.screen.windows.isEmpty {
                    ForEach(diagnostics.screen.windows) { target in
                        Button(target.title, systemImage: target.symbol) { diagnostics.captureWindow(target) }
                    }
                }
                if let image = diagnostics.screen.preview { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 8)) }
                Text("A single bounded preview frame is captured after you choose a display or window. No screen stream is started.").font(.footnote).foregroundStyle(.secondary)
            }

            if let message = diagnostics.message { Text(message).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .frame(width: 680, height: 700)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in diagnostics.stopAll() }
        .onDisappear { diagnostics.stopAll() }
    }
}
