import HostsCore
import SwiftUI

/// Right-hand panel: one switch for the sandbox and a checklist of what it does.
struct SandboxPanelView: View {
    let controller: SandboxController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sandbox")
                .font(.headline)

            HStack(spacing: 10) {
                Toggle("Sandbox", isOn: Binding(
                    get: { controller.isOn },
                    set: { newValue in Task { await controller.setEnabled(newValue) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
                .disabled(controller.isRunning)
                Text(controller.isOn ? "On" : "Off")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(controller.isOn ? Color.green : Color.secondary)
                if controller.isRunning { ProgressView().controlSize(.small) }
            }

            Toggle("Include \(controller.preferences.apiGroup)", isOn: Binding(get: { controller.includeAPI }, set: { controller.includeAPI = $0 }))
                .disabled(controller.isRunning)
                .help("When off, switching on leaves the API group alone and skips the proxy bypass. Switching off always does both.")

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                ForEach(SandboxStep.allCases, id: \.self) { step in
                    row(step)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func row(_ step: SandboxStep) -> some View {
        let status = controller.status(of: step)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon(status).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.title(of: step))
                    .foregroundStyle(status == .pending ? Color.secondary : Color.primary)
                if let detail = detail(step, status) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isFailure(status) ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func icon(_ status: StepStatus) -> some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func detail(_ step: SandboxStep, _ status: StepStatus) -> String? {
        switch status {
        case let .skipped(reason): return "Skipped: \(reason)"
        case let .failed(message): return message
        case .done: return controller.notes[step]
        default: return nil
        }
    }

    private func isFailure(_ status: StepStatus) -> Bool {
        if case .failed = status { return true }
        return false
    }
}
