import Foundation
import Observation

/// The things the sandbox switch does, in the order it does them (for both directions).
public enum SandboxStep: CaseIterable, Hashable, Sendable {
    case mainGroup, apiGroup, network, dnsCache, socketPools, mcp, remote, verify

    /// The row label. The two group rows name the groups chosen in Settings.
    public func title(_ preferences: SandboxPreferences) -> String {
        switch self {
        case .mainGroup: return "\(preferences.mainGroup) group"
        case .apiGroup: return "\(preferences.apiGroup) group"
        case .network: return "Proxy bypass & DNS"
        case .dnsCache: return "Dia: host cache"
        case .socketPools: return "Dia: socket pools"
        case .mcp: return "MCP servers: proxy"
        case .remote: return "Sandbox: remote command"
        case .verify: return "Sandbox answers"
        }
    }
}

public enum StepStatus: Equatable, Sendable {
    case pending, running, done
    case skipped(String)
    case failed(String)
}

/// The sandbox switch: flips two host groups, sets the proxy bypass and flushes DNS, and clears Dia's caches. Which
/// groups and which host are settings (`SandboxPreferences`).
///
/// Switching on with `includeAPI` off leaves the API group alone and skips the proxy bypass for the sandbox host
/// (which would otherwise sandbox that host anyway). Switching off always does everything.
/// After those come three steps that make MCP servers use the sandbox: point the chosen servers at the SOCKS proxy
/// (off removes it again), run a command on the sandbox over ssh (on only), and fetch a check page through the proxy
/// (on only). They need the API host sandboxed, so leaving the API group out skips them too.
///
/// A step that fails stops the run; nothing already done is rolled back.
@MainActor @Observable
public final class SandboxController {
    static let includeAPIKey = "sandbox.includeAPI"

    private let model: AppModel
    private let network: SandboxNetworking
    private let browser: BrowserCacheClearing
    private let mcp: SandboxMCPRouting
    private let remote: SandboxRemoteRunning
    private let verifier: SandboxVerifying
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log: @Sendable (String) -> Void

    public private(set) var statuses: [SandboxStep: StepStatus] = SandboxController.pendingStatuses
    public private(set) var isRunning = false
    /// A reminder to show under a step once it is done, for things the app cannot do itself.
    public private(set) var notes: [SandboxStep: String] = [:]

    /// Whether switching on should also enable the api group and set the proxy bypass. Remembered between launches.
    public var includeAPI: Bool {
        didSet { defaults.set(includeAPI, forKey: Self.includeAPIKey) }
    }

    /// Which groups and host the switch acts on, and whether it is available. Saved as they change.
    public var preferences: SandboxPreferences {
        didSet { preferences.save(to: defaults) }
    }

    /// The MCP, ssh and check steps default to ones that skip themselves, so the switch works with only the groups and network.
    public init(model: AppModel, network: SandboxNetworking, browser: BrowserCacheClearing, mcp: SandboxMCPRouting = NoSandboxExtras(),
                remote: SandboxRemoteRunning = NoSandboxExtras(), verifier: SandboxVerifying = NoSandboxExtras(),
                defaults: UserDefaults = .standard, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.log = log
        self.model = model
        self.network = network
        self.browser = browser
        self.mcp = mcp
        self.remote = remote
        self.verifier = verifier
        self.defaults = defaults
        includeAPI = defaults.object(forKey: Self.includeAPIKey) as? Bool ?? true
        preferences = SandboxPreferences.load(from: defaults)
    }

    public func title(of step: SandboxStep) -> String { step.title(preferences) }

    // MARK: Export and import

    /// The settings as a file. The panel's on/off choice is left out.
    public func exportSettings() throws -> Data {
        try SandboxSettingsFile.export(preferences, includeAPI: includeAPI)
    }

    /// Checks a settings file against the current settings without applying it.
    public func previewImport(_ data: Data) throws -> SandboxSettingsFile.Imported {
        try SandboxSettingsFile.read(data, current: preferences, currentIncludeAPI: includeAPI)
    }

    /// Applies a checked import. The panel's on/off choice stays as it is. Ignored while a run is in progress.
    public func applyImport(_ imported: SandboxSettingsFile.Imported) {
        guard !isRunning else { return }
        var next = imported.preferences
        next.enabled = preferences.enabled
        preferences = next
        includeAPI = imported.includeAPI
    }

    /// The steps that only make sense when the API host is sandboxed.
    private static let needsAPI: Set<SandboxStep> = [.apiGroup, .network, .mcp, .remote, .verify]

    private static var pendingStatuses: [SandboxStep: StepStatus] {
        Dictionary(uniqueKeysWithValues: SandboxStep.allCases.map { ($0, StepStatus.pending) })
    }

    // MARK: Derived state

    public func status(of step: SandboxStep) -> StepStatus { statuses[step] ?? .pending }

    /// On when the main group is fully on, and so is the api group if it is included. Read from the hosts file, never remembered.
    public var isOn: Bool {
        guard let main = group(named: preferences.mainGroup), model.groupState(main) == .on else { return false }
        guard includeAPI else { return true }
        guard let api = group(named: preferences.apiGroup) else { return false }
        return model.groupState(api) == .on
    }

    /// The error of the first failed step, for a summary line.
    public var failureMessage: String? {
        for step in SandboxStep.allCases {
            if case let .failed(message) = status(of: step) { return message }
        }
        return nil
    }

    private func group(named name: String) -> HostGroup? {
        model.groups.first { $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Running

    /// Ignored while a run is in progress.
    public func setEnabled(_ on: Bool) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        statuses = Self.pendingStatuses
        notes = [:]
        let includeAPI = self.includeAPI
        let mode: SandboxMode = on ? .on : .off
        log("run start mode=\(mode.rawValue) includeAPI=\(includeAPI)")
        defer { log("run end") }

        for step in SandboxStep.allCases {
            if on, !includeAPI, Self.needsAPI.contains(step) {
                statuses[step] = .skipped("Not included")
                log("\(step) skipped: Not included")
                continue
            }
            statuses[step] = .running
            log("\(step) running")
            let outcome = await perform(step, on: on, mode: mode)
            log("\(step) \(outcome)")
            switch outcome {
            case .done, .doneWith:
                statuses[step] = .done
                var note: [String] = []
                if step == .mcp, on { note.append("Restart or reconnect (/mcp) the server in running Claude Code, Codex and Grok sessions.") }
                if case let .doneWith(extra) = outcome { note.append(extra) }
                if !note.isEmpty { notes[step] = note.joined(separator: " ") }
            case let .skipped(reason): statuses[step] = .skipped(reason)
            case let .failed(message):
                statuses[step] = .failed(message)
                return
            }
        }
    }

    private func perform(_ step: SandboxStep, on: Bool, mode: SandboxMode) async -> StepOutcome {
        switch step {
        case .mainGroup: return await setGroup(named: preferences.mainGroup, enabled: on)
        case .apiGroup: return await setGroup(named: preferences.apiGroup, enabled: on)
        case .network: return await network.apply(mode)
        case .dnsCache: return await browser.clearHostCache()
        case .socketPools: return await browser.flushSocketPools()
        case .mcp: return await mcp.apply(mode)
        case .remote: return on ? await remote.runRemote() : .skipped("Nothing to undo")
        case .verify: return on ? await verifier.verify() : .skipped("Only checked when switching on")
        }
    }

    private func setGroup(named name: String, enabled: Bool) async -> StepOutcome {
        guard let group = group(named: name) else { return .failed("No group named \u{201C}\(name)\u{201D}.") }
        if await model.setGroup(group, enabled: enabled) { return .done }
        // A cancelled authentication dialog is the one failure the model does not turn into an error message.
        return .failed(model.errorMessage ?? "Authentication was cancelled.")
    }
}

/// Stands in for the MCP, ssh and check steps when none is given: each skips itself.
public struct NoSandboxExtras: SandboxMCPRouting, SandboxRemoteRunning, SandboxVerifying {
    public init() {}
    public func apply(_ mode: SandboxMode) async -> StepOutcome { .skipped("Not set up") }
    public func runRemote() async -> StepOutcome { .skipped("Not set up") }
    public func verify() async -> StepOutcome { .skipped("Not set up") }
}
