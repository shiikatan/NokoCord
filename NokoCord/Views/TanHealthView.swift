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
    @State private var pendingConfirmation: ConfirmationAction?
    @State private var showingTrustDiff = false

    private enum ConfirmationAction: Identifiable {
        case approve
        case enable
        case disable
        case retry
        case recover
        case safeMode
        case restore

        var id: String { title }
        var title: String {
            switch self {
            case .approve: return "Approve this Tan?"
            case .enable: return "Enable this Tan?"
            case .disable: return "Disable this Tan?"
            case .retry: return "Retry this Tan?"
            case .recover: return "Recover this Tan?"
            case .safeMode: return "Start Safe Mode?"
            case .restore: return "Restore the previous Tan version?"
            }
        }
        var buttonTitle: String {
            switch self {
            case .approve: return "Approve & Enable"
            case .enable: return "Enable Tan"
            case .disable: return "Disable Tan"
            case .retry: return "Retry Tan"
            case .recover: return "Recover Tan"
            case .safeMode: return "Start Safe Mode"
            case .restore: return "Restore Previous Version"
            }
        }
        var message: String {
            switch self {
            case .approve:
                return "This records consent for the displayed code, target, capabilities, and trust origin. A later identity change requires approval again."
            case .enable:
                return "This runs the approved Tan inside Discord."
            case .disable:
                return "The Tan will stop modifying Discord after the next lifecycle update."
            case .retry:
                return "NokoCord will approve the current identity again and attempt to start it."
            case .recover:
                return "The quarantine will be cleared, but the Tan will remain disabled until you approve it again."
            case .safeMode:
                return "Safe Mode reloads Discord without Noko scripts or bridge handlers. Your Discord session data is retained."
            case .restore:
                return "The retained previous package snapshot will replace this version. It will remain disabled and require fresh approval."
            }
        }
        var isDestructive: Bool {
            switch self {
            case .disable, .safeMode, .restore: return true
            case .approve, .enable, .retry, .recover: return false
            }
        }
    }

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
        .sheet(isPresented: $showingTrustDiff) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review Tan trust").font(.title3.bold())
                TanTrustDiffView(package: package, record: tans.trustRecord(for: package.id))
                Button("Done") { showingTrustDiff = false }
                    .keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(24)
            .frame(width: 460)
        }
        .confirmationDialog(
            pendingConfirmation?.title ?? "Confirm Tan action",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingConfirmation {
                Button(action.buttonTitle, role: action.isDestructive ? .destructive : nil) {
                    pendingConfirmation = nil
                    performConfirmed(action)
                }
            }
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
        } message: {
            Text(pendingConfirmation?.message ?? "")
        }
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
                    LabeledContent("Approval", value: record.enabled ? "Enabled" : (record.isApproved ? "Approved, disabled" : "Not approved"))
                    if let category = record.lastFailureCategory {
                        HStack(spacing: 4) {
                            Text("Last issue")
                            Spacer()
                            Text(category.displayName)
                            if let date = record.lastFailureAt {
                                Text("·")
                                Text(date, style: .relative)
                            }
                        }
                    } else if let reason = record.quarantineReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if package.manifest.target == .page {
                    Label(
                        "Page-world code runs beside Discord JavaScript and is not strongly sandboxed.",
                        systemImage: "exclamationmark.shield"
                    )
                    .foregroundStyle(.orange)
                } else {
                    Label(
                        "This Tan runs in an isolated page world under NokoCord’s declared contract.",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            HStack(spacing: 8) {
                if TanTrustDiff.make(package: package, record: tans.trustRecord(for: package.id)).requiresApproval {
                    Button("Review trust changes") { showingTrustDiff = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if let action = presentation.action {
                    Button(actionTitle(for: action)) { requestConfirmation(for: action) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                if presentation.state == .failedDegraded || presentation.state == .quarantined {
                    Button("Start Safe Mode") { pendingConfirmation = .safeMode }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if tans.canRestorePrevious(package.id) {
                    Button("Restore Previous Version") { pendingConfirmation = .restore }
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

    private func requestConfirmation(for action: TanHealthAction) {
        switch action {
        case .approveAndEnable: pendingConfirmation = .approve
        case .enable: pendingConfirmation = .enable
        case .disable: pendingConfirmation = .disable
        case .retry: pendingConfirmation = .retry
        case .recover: pendingConfirmation = .recover
        case .reload: onReload()
        }
    }

    private func performConfirmed(_ action: ConfirmationAction) {
        switch action {
        case .approve, .enable, .retry:
            tans.setEnabled(package.id, true)
        case .disable:
            tans.setEnabled(package.id, false)
        case .recover:
            tans.recoverQuarantined(package.id)
        case .safeMode:
            tans.setSafeMode(true)
        case .restore:
            tans.restorePreviousVersion(package.id)
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
