import Foundation

/// Carries out agent requests through the same objects the window uses, so the sidebar, the switch, the checklist and
/// the log stay in sync and every hosts write goes through the app's own authorization (one macOS dialog, then the
/// window macOS allows).
@MainActor
public final class AgentService {
    private let model: AppModel
    private let sandbox: SandboxController

    public init(model: AppModel, sandbox: SandboxController) {
        self.model = model
        self.sandbox = sandbox
    }

    public func handle(_ request: AgentRequest) async -> AgentResponse {
        guard let command = AgentCommand(rawValue: request.cmd) else {
            return .failure("Unknown command \u{201C}\(request.cmd)\u{201D}. Agents can read state and turn existing groups and lines on or off; they cannot add, edit or delete them.")
        }
        switch command {
        case .status: return await status()
        case .groups: return await groupsResponse(ok: true, message: "")
        case .sandbox: return await runSandbox(request)
        case .group: return await setGroup(request)
        case .line: return await setLine(request)
        }
    }

    // MARK: Reading

    private func status() async -> AgentResponse {
        await model.reload()
        var response = AgentResponse(ok: true, message: sandbox.isOn ? "Sandbox is on." : "Sandbox is off.",
                                     sandbox: sandboxInfo(), groups: groupInfos(), steps: stepInfos())
        if let message = model.errorMessage { response.message += " \(message)" }
        return response
    }

    private func groupsResponse(ok: Bool, message: String) async -> AgentResponse {
        await model.reload()
        return AgentResponse(ok: ok, message: message, sandbox: sandboxInfo(), groups: groupInfos())
    }

    private func sandboxInfo() -> AgentSandboxInfo {
        AgentSandboxInfo(on: sandbox.isOn, running: sandbox.isRunning, includeAPI: sandbox.includeAPI)
    }

    private func groupInfos() -> [AgentGroupInfo] {
        model.groups.map { group in
            AgentGroupInfo(name: group.name, state: Self.name(model.groupState(group)),
                           lines: group.lines.map { AgentLineInfo(host: $0.hostname, ip: $0.ip, state: Self.name(model.lineState($0))) })
        }
    }

    private func stepInfos() -> [AgentStepInfo] {
        SandboxStep.allCases.map { step in
            switch sandbox.status(of: step) {
            case .pending: return AgentStepInfo(name: sandbox.title(of: step), status: "pending", detail: nil)
            case .running: return AgentStepInfo(name: sandbox.title(of: step), status: "running", detail: nil)
            case .done: return AgentStepInfo(name: sandbox.title(of: step), status: "done", detail: sandbox.notes[step])
            case let .skipped(reason): return AgentStepInfo(name: sandbox.title(of: step), status: "skipped", detail: reason)
            case let .failed(message): return AgentStepInfo(name: sandbox.title(of: step), status: "failed", detail: message)
            }
        }
    }

    private static func name(_ state: GroupState) -> String {
        switch state { case .on: return "on"; case .off: return "off"; case .mixed: return "mixed" }
    }

    private static func name(_ state: LineState) -> String {
        switch state { case .on: return "on"; case .off: return "off"; case .missing: return "missing" }
    }

    // MARK: Acting

    private func runSandbox(_ request: AgentRequest) async -> AgentResponse {
        guard let enable = request.enable else { return .failure("sandbox needs enable: true or false.") }
        guard sandbox.preferences.enabled else {
            return .failure("The sandbox switch is turned off. Ask the user to turn it on in the app's Settings.")
        }
        guard !sandbox.isRunning else { return .failure("A sandbox run is already in progress.") }
        await model.reload()
        // The checkbox is remembered between launches, so an agent's one-off choice must not change it.
        let remembered = sandbox.includeAPI
        if let includeAPI = request.includeAPI { sandbox.includeAPI = includeAPI }
        await sandbox.setEnabled(enable)
        sandbox.includeAPI = remembered
        let failure = sandbox.failureMessage
        return AgentResponse(ok: failure == nil,
                             message: failure ?? (enable ? "Sandbox turned on." : "Sandbox turned off."),
                             sandbox: sandboxInfo(), groups: groupInfos(), steps: stepInfos())
    }

    private func setGroup(_ request: AgentRequest) async -> AgentResponse {
        guard let enable = request.enable, let name = request.name, !name.isEmpty else {
            return .failure("group needs a name and enable: true or false.")
        }
        await model.reload()
        let matches = model.groups.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard let group = matches.first else { return .failure("No group named \u{201C}\(name)\u{201D}.") }
        guard matches.count == 1 else { return .failure("More than one group is named \u{201C}\(name)\u{201D}.") }
        if await model.setGroup(group, enabled: enable) {
            return await groupsResponse(ok: true, message: "Group \u{201C}\(group.name)\u{201D} turned \(enable ? "on" : "off").")
        }
        return await groupsResponse(ok: false, message: model.errorMessage ?? "Authentication was cancelled.")
    }

    private func setLine(_ request: AgentRequest) async -> AgentResponse {
        guard let enable = request.enable, let host = request.host, !host.isEmpty else {
            return .failure("line needs a host and enable: true or false.")
        }
        await model.reload()
        let candidates = model.groups
            .filter { request.group == nil || $0.name.caseInsensitiveCompare(request.group ?? "") == .orderedSame }
            .flatMap { $0.lines }
            .filter { $0.hostname.caseInsensitiveCompare(host) == .orderedSame }
        guard let line = candidates.first else { return .failure("No line for \u{201C}\(host)\u{201D}.") }
        guard candidates.count == 1 else {
            return .failure("\u{201C}\(host)\u{201D} is in more than one place. Say which group with group: \u{201C}name\u{201D}.")
        }
        if await model.setLine(line, enabled: enable) {
            return await groupsResponse(ok: true, message: "\(line.hostname) turned \(enable ? "on" : "off").")
        }
        return await groupsResponse(ok: false, message: model.errorMessage ?? "Authentication was cancelled.")
    }
}
