import SwiftUI

struct CallReadinessView: View {
    let readiness: CallReadiness
    var onRetry: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                evidence
                if !readiness.blockers.isEmpty {
                    blockers
                }
                capture
                if let onRetry = onRetry {
                    Button("Check again", action: onRetry)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 420, minHeight: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: stateIcon)
                .font(.title2)
                .foregroundStyle(stateColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Call readiness")
                    .font(.title3.weight(.semibold))
                Text(stateTitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(stateColor)
                Text(stateDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Verified signals")
                .font(.headline)
            readinessRow("Origin", value: readiness.origin.isEmpty ? "Unavailable" : readiness.origin,
                         isGood: !readiness.blockers.contains(.invalidOrigin))
            readinessRow("Media devices", value: readiness.mediaDevicesAvailable ? "Available" : "Unavailable",
                         isGood: readiness.mediaDevicesAvailable)
            readinessRow("Microphone", value: permissionLabel(readiness.microphonePermission),
                         isGood: readiness.microphonePermission == .granted)
            readinessRow("Camera", value: permissionLabel(readiness.cameraPermission),
                         isGood: readiness.cameraPermission == .granted)
            readinessRow("Encoded transform", value: readiness.encodedTransformAvailable ? "Available" : "Unavailable",
                         isGood: readiness.encodedTransformAvailable)
            readinessRow("Discord call surface", value: readiness.discordCallSurfaceReady ? "Ready" : "Not verified",
                         isGood: readiness.discordCallSurfaceReady)
        }
    }

    private var blockers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What needs attention")
                .font(.headline)
            ForEach(readiness.blockers, id: \.self) { blocker in
                Label {
                    Text(blocker.title)
                } icon: {
                    Image(systemName: blocker.isBlocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(blocker.isBlocking ? .red : .orange)
                }
                .font(.callout)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var capture: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Current capture")
                .font(.headline)
            Text(readiness.captureState.summary)
                .font(.callout)
            Text(readiness.isCallConfirmed
                 ? "The Discord call surface and capture state agree."
                 : "Capture alone does not confirm a Discord call.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func readinessRow(_ label: String, value: String, isGood: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isGood ? "checkmark.circle.fill" : "minus.circle.fill")
                .foregroundStyle(isGood ? .green : .secondary)
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private func permissionLabel(_ permission: CallPermissionState) -> String {
        switch permission {
        case .granted: "Granted"
        case .denied: "Denied"
        case .notDetermined: "Needs approval"
        case .restricted: "Restricted"
        case .unknown: "Unknown"
        }
    }

    private var stateTitle: String {
        switch readiness.state {
        case .ready: "Ready to join"
        case .degraded: "Ready with limitations"
        case .blocked: "Cannot verify readiness"
        }
    }

    private var stateDescription: String {
        switch readiness.state {
        case .ready: "Required Discord and media checks passed."
        case .degraded: "Audio can be checked, but an optional capability needs attention."
        case .blocked: "The app will not claim that a Discord call is active."
        }
    }

    private var stateIcon: String {
        switch readiness.state {
        case .ready: "checkmark.shield.fill"
        case .degraded: "exclamationmark.shield.fill"
        case .blocked: "xmark.shield.fill"
        }
    }

    private var stateColor: Color {
        switch readiness.state {
        case .ready: .green
        case .degraded: .orange
        case .blocked: .red
        }
    }
}
