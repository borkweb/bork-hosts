import Foundation

/// What an agent (or any script) can ask the running app to do. There is deliberately no command to add, edit or
/// delete a group or a line: agents only turn existing things on and off, and read state.
public enum AgentCommand: String, Codable, CaseIterable, Sendable {
    case status, groups, sandbox, group, line
}

/// One request per connection, as a single line of JSON.
public struct AgentRequest: Codable, Equatable, Sendable {
    /// Kept as text so an unknown command gets a clear refusal instead of a decoding failure.
    public var cmd: String
    public var enable: Bool?
    public var name: String?
    public var host: String?
    public var group: String?
    public var includeAPI: Bool?

    public init(cmd: String, enable: Bool? = nil, name: String? = nil, host: String? = nil, group: String? = nil, includeAPI: Bool? = nil) {
        self.cmd = cmd
        self.enable = enable
        self.name = name
        self.host = host
        self.group = group
        self.includeAPI = includeAPI
    }
}

public struct AgentLineInfo: Codable, Equatable, Sendable {
    public var host: String
    public var ip: String
    /// `on`, `off`, or `missing` (not in the hosts file's managed block).
    public var state: String
}

public struct AgentGroupInfo: Codable, Equatable, Sendable {
    public var name: String
    /// `on`, `off`, or `mixed`.
    public var state: String
    public var lines: [AgentLineInfo]
}

public struct AgentStepInfo: Codable, Equatable, Sendable {
    public var name: String
    /// `pending`, `running`, `done`, `skipped` or `failed`.
    public var status: String
    public var detail: String?
}

public struct AgentSandboxInfo: Codable, Equatable, Sendable {
    public var on: Bool
    public var running: Bool
    public var includeAPI: Bool
}

public struct AgentResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var sandbox: AgentSandboxInfo?
    public var groups: [AgentGroupInfo]?
    public var steps: [AgentStepInfo]?

    public init(ok: Bool, message: String, sandbox: AgentSandboxInfo? = nil, groups: [AgentGroupInfo]? = nil, steps: [AgentStepInfo]? = nil) {
        self.ok = ok
        self.message = message
        self.sandbox = sandbox
        self.groups = groups
        self.steps = steps
    }

    public static func failure(_ message: String) -> AgentResponse { AgentResponse(ok: false, message: message) }
}
