import Foundation

public struct AgentUsageError: Error, Equatable, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// What the command-line tool was asked to do. Pure parsing and rendering, so it is tested without a process.
public struct AgentInvocation: Equatable {
    public var request: AgentRequest?
    public var json = false
    public var timeout: TimeInterval = 120
    public var launchApp = true
    public var wantsHelp = false
}

public enum AgentCommandLine {
    public static let usage = """
    bork-hosts: turn the sandbox, host groups and host lines on or off in the running bork-hosts app.

    Usage:
      bork-hosts status                          Sandbox state, groups and the last run's steps
      bork-hosts groups                          Groups, their lines, and each one's state
      bork-hosts sandbox on|off [--no-api]       Turn the sandbox on or off (it must be enabled in Settings)
      bork-hosts sandbox status                  Same as status
      bork-hosts group on|off <group name>       Turn a group on or off
      bork-hosts line on|off <hostname> [--group <group name>]

    Options:
      --json             Print the reply as JSON
      --timeout <secs>   How long to wait, including for the macOS authentication dialog (default 120)
      --no-launch        Do not start the app if it is not running
      -h, --help         Show this help

    Notes:
      --no-api leaves the API group alone when switching on (switching off always does everything).
      The app asks you to authenticate the first time, then not again for about 5 minutes.
      Adding, editing and deleting groups and lines is not available here; do that in the app.

    Exit codes: 0 done, 1 the app reported a failure, 2 bad usage, 3 the app could not be reached, 4 timed out.
    """

    public static func parse(_ arguments: [String]) throws -> AgentInvocation {
        var invocation = AgentInvocation()
        var words: [String] = []
        var groupFlag: String?
        var apiFlag: Bool?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json": invocation.json = true
            case "--no-launch": invocation.launchApp = false
            case "-h", "--help": invocation.wantsHelp = true
            case "--no-api": apiFlag = false
            case "--api": apiFlag = true
            case "--timeout":
                index += 1
                guard index < arguments.count, let seconds = TimeInterval(arguments[index]), seconds > 0 else {
                    throw AgentUsageError("--timeout needs a number of seconds.")
                }
                invocation.timeout = seconds
            case "--group":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw AgentUsageError("--group needs a group name.") }
                groupFlag = arguments[index]
            default:
                if argument.hasPrefix("-") && argument.count > 1 { throw AgentUsageError("Unknown option \(argument).") }
                words.append(argument)
            }
            index += 1
        }
        if invocation.wantsHelp || words.isEmpty {
            invocation.wantsHelp = true
            return invocation
        }

        let command = words[0]
        let rest = Array(words.dropFirst())
        func enable(_ word: String?) throws -> Bool {
            switch word?.lowercased() {
            case "on", "enable": return true
            case "off", "disable": return false
            default: throw AgentUsageError("Say on or off.")
            }
        }
        if apiFlag != nil, command != "sandbox" { throw AgentUsageError("--api and --no-api only apply to sandbox.") }
        if groupFlag != nil, command != "line" { throw AgentUsageError("--group only applies to line.") }

        switch command {
        case "status":
            guard rest.isEmpty else { throw AgentUsageError("status takes no arguments.") }
            invocation.request = AgentRequest(cmd: "status")
        case "groups":
            guard rest.isEmpty else { throw AgentUsageError("groups takes no arguments.") }
            invocation.request = AgentRequest(cmd: "groups")
        case "sandbox":
            if rest.first?.lowercased() == "status" {
                guard rest.count == 1, apiFlag == nil else { throw AgentUsageError("sandbox status takes no arguments.") }
                invocation.request = AgentRequest(cmd: "status")
            } else {
                guard rest.count == 1 else { throw AgentUsageError("Usage: sandbox on|off [--no-api]") }
                invocation.request = AgentRequest(cmd: "sandbox", enable: try enable(rest.first), includeAPI: apiFlag)
            }
        case "group":
            guard rest.count >= 2 else { throw AgentUsageError("Usage: group on|off <group name>") }
            invocation.request = AgentRequest(cmd: "group", enable: try enable(rest.first), name: rest.dropFirst().joined(separator: " "))
        case "line":
            guard rest.count == 2 else { throw AgentUsageError("Usage: line on|off <hostname> [--group <group name>]") }
            invocation.request = AgentRequest(cmd: "line", enable: try enable(rest.first), host: rest[1], group: groupFlag)
        default:
            throw AgentUsageError("Unknown command \u{201C}\(command)\u{201D}. Run bork-hosts --help.")
        }
        return invocation
    }

    // MARK: Output

    public static func render(_ response: AgentResponse, for request: AgentRequest) -> String {
        var lines: [String] = []
        if let sandbox = response.sandbox, request.cmd == "status" || request.cmd == "sandbox" {
            lines.append("Sandbox: \(sandbox.on ? "on" : "off")\(sandbox.running ? " (running)" : "")")
        }
        if let steps = response.steps {
            for step in steps {
                switch step.status {
                case "done": lines.append("  [ok]      \(step.name)\(step.detail.map { " (\($0))" } ?? "")")
                case "skipped": lines.append("  [skipped] \(step.name)\(step.detail.map { " (\($0))" } ?? "")")
                case "failed": lines.append("  [FAILED]  \(step.name)\(step.detail.map { ": \($0)" } ?? "")")
                case "running": lines.append("  [running] \(step.name)")
                default: lines.append("  [pending] \(step.name)")
                }
            }
        }
        if !response.message.isEmpty, !(response.ok && (request.cmd == "status" || request.cmd == "sandbox")) || !response.ok {
            lines.append(response.ok ? response.message : "Error: \(response.message)")
        }
        if let groups = response.groups, request.cmd != "sandbox" {
            for group in groups {
                lines.append("\(group.name): \(group.state)")
                for line in group.lines { lines.append("  \(line.host)  \(line.ip)  \(line.state)") }
            }
        }
        return lines.joined(separator: "\n")
    }
}
