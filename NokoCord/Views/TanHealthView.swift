import SwiftUI
import AppKit

/// Shared health and recovery surface used by the Home hub, Inspector, and
/// Tan details sheet. Actions only call existing TanManager controls.
struct TanHealthView: View {
    @Environment(TanManager.self) private var tans

    let package: TanPackage
    let compact: Bool
    let onReload: () -> Void

    @State private var copiedDiagnostics = false

    init(package: TanPackage, compact: Bool = false, onReload: @escaping () -> Void = {}) {
        self.package = package
        self.compact = compact
        self.onReload = onReload
    }

    private var presentation: TanHealthPresentation {
        TanHealthPresentation.make(
            record: tans.trustRecord(for: package.id),
            isEnabled: tans.enabledIDs.contains(package.id) && !tans.safeMode,
            reloadRequired: tans.reloadRequired
        )
    }

    var body: some View {
        Group {
            if compact {
                compactBody
            } else {
                fullBody
            }
        }
        .animation(.nokoFluidSpring, value: presentation.state)
    }

    private var compactBody: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(presentation.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tan health: \(presentation.title)")
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.12), in: .rect(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title)
                        .font(.headline)
                    Text(presentation.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Target", value: package.manifest.target.rawValue)
                LabeledContent(
                    "Capabilities",
                    value: package.manifest.capabilities.isEmpty
                        ? "None"
                        : package.manifest.capabilities.map(\.rawValue).joined(separator: ", ")
                )
                LabeledContent("Trust origin", value: package.origin == "Noko Original" ? "Noko-Tan" : package.origin)
                if let record = tans.trustRecord(for: package.id) {
                    LabeledContent("Approved code", value: shortHash(record.contentHash))
                    if let reason = record.quarantineReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let lastFailure {
                    HStack(spacing: 4) {
                        Text("Last issue")
                        Spacer()
                        Text(lastFailure.event.rawValue)
                        Text("·")
                        Text(lastFailure.date, style: .relative)
                    }
                }
            }
            .font(.caption)

            HStack(spacing: 8) {
                if let action = presentation.action {
                    Button(actionTitle(for: action)) { perform(action) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                if presentation.state == .failedDegraded || presentation.state == .quarantined {
                    Button("Start Safe Mode") { tans.setSafeMode(true) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button(copiedDiagnostics ? "Copied" : "Copy redacted diagnostics") {
                    copyRedactedDiagnostics()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.2)))
    }

    private var iconName: String {
        switch presentation.state {
        case .awaitingApproval: "checkmark.shield"
        case .enabledHealthy: "checkmark.circle.fill"
        case .disabled: "pause.circle"
        case .failedDegraded: "exclamationmark.triangle.fill"
        case .quarantined: "lock.trianglebadge.exclamationmark"
        case .reloadRequired: "arrow.clockwise.circle"
        }
    }

    private var tint: Color {
        switch presentation.state {
        case .awaitingApproval, .reloadRequired: .orange
        case .enabledHealthy: .green
        case .disabled: .secondary
        case .failedDegraded, .quarantined: .red
        }
    }

    private var lastFailure: TanDiagnostic? {
        tans.diagnostics.last {
            $0.tanID == package.id && ($0.event == .failed || $0.event == .rejected)
        }
    }

    private func actionTitle(for action: TanHealthAction) -> String {
        switch action {
        case .approveAndEnable: "Approve & Enable"
        case .enable: "Enable"
        case .disable: "Disable"
        case .retry: "Retry"
        case .recover: "Recover"
        case .reload: "Reload Discord"
        }
    }

    private func perform(_ action: TanHealthAction) {
        switch action {
        case .approveAndEnable, .enable, .retry:
            tans.setEnabled(package.id, true)
        case .disable:
            tans.setEnabled(package.id, false)
        case .recover:
            tans.recoverQuarantined(package.id)
        case .reload:
            onReload()
        }
    }

    private func shortHash(_ hash: String) -> String {
        guard hash.count > 12 else { return hash }
        return String(hash.prefix(12)) + "…"
    }

    private func copyRedactedDiagnostics() {
        let events = tans.diagnostics
            .filter { $0.tanID == package.id }
            .suffix(20)
            .map { "\($0.date.ISO8601Format()) \($0.event.rawValue)" }
            .joined(separator: "\n")
        let text = [
            "Tan: \(package.id)",
            "State: \(presentation.state.rawValue)",
            "Events:",
            events.isEmpty ? "none" : events
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedDiagnostics = true
    }
}
