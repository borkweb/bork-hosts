import Foundation

/// What the sandbox switch acts on. Everything here is a setting, so the app carries no one's workflow: the defaults
/// are generic names or blank, and a blank value turns its step off.
public struct SandboxPreferences: Equatable, Sendable {
    public static let defaultMainGroup = "sandbox"
    public static let defaultAPIGroup = "sandbox api"
    /// The local SOCKS proxy MCP servers are pointed at. It must be `socks5://`, not `socks5h://`: the second resolves
    /// names on the proxy, which skips `/etc/hosts` and sends the host to the real server.
    public static let defaultProxyURL = "socks5://127.0.0.1:8080"

    /// Whether the sandbox panel (and the agent `sandbox` command) is available at all.
    public var enabled = false
    /// The group the switch always turns on and off.
    public var mainGroup = SandboxPreferences.defaultMainGroup
    /// The group the "Include API group" checkbox adds.
    public var apiGroup = SandboxPreferences.defaultAPIGroup
    /// The host added to the proxy bypass list while the sandbox is on. Blank skips the bypass step.
    public var bypassHost = ""
    /// The network service whose bypass list is edited, such as "Wi-Fi".
    public var networkService = ""
    /// Which tools' config files get the proxy: Claude Code (`~/.claude.json`), Codex (`~/.codex/config.toml`) and
    /// Grok (`~/.grok/config.toml`). A tool whose file does not exist is skipped.
    public var mcpClaude = true
    public var mcpCodex = true
    public var mcpGrok = true
    /// The SOCKS proxy URL set in the MCP servers' environment.
    public var proxyURL = SandboxPreferences.defaultProxyURL
    /// Servers in those files that get the proxy: a name alone sets HTTPS_PROXY and HTTP_PROXY; `name=KEY+KEY` sets
    /// just those variables. Blank turns the MCP step off.
    public var mcpServers = ""
    /// The sandbox to ssh to, as `user@host` or a name from `~/.ssh/config`. Blank turns the ssh step off.
    public var sshHost = ""
    /// The command to run on the sandbox over ssh, for example one that enables writes. Blank turns the ssh step off.
    public var remoteCommand = ""
    /// A page fetched through the proxy once the sandbox is on, to confirm the host reached the sandbox. Blank turns
    /// the check off.
    public var verifyURL = ""
    /// Text the check page's reply must contain. Blank accepts any successful reply.
    public var verifyExpected = ""

    public init() {}

    enum Key {
        static let enabled = "sandbox.enabled"
        static let mainGroup = "sandbox.mainGroup"
        static let apiGroup = "sandbox.apiGroup"
        static let bypassHost = "sandbox.bypassHost"
        static let networkService = "sandbox.networkService"
        static let mcpClaude = "sandbox.mcpClaude"
        static let mcpCodex = "sandbox.mcpCodex"
        static let mcpGrok = "sandbox.mcpGrok"
        static let proxyURL = "sandbox.proxyURL"
        static let mcpServers = "sandbox.mcpServers"
        static let sshHost = "sandbox.sshHost"
        static let remoteCommand = "sandbox.remoteCommand"
        static let verifyURL = "sandbox.verifyURL"
        static let verifyExpected = "sandbox.verifyExpected"
    }

    public static func load(from defaults: UserDefaults = .standard) -> SandboxPreferences {
        var result = SandboxPreferences()
        result.enabled = defaults.object(forKey: Key.enabled) as? Bool ?? false
        result.mainGroup = text(defaults, Key.mainGroup) ?? defaultMainGroup
        result.apiGroup = text(defaults, Key.apiGroup) ?? defaultAPIGroup
        result.bypassHost = text(defaults, Key.bypassHost) ?? ""
        result.networkService = text(defaults, Key.networkService) ?? ""
        result.mcpClaude = defaults.object(forKey: Key.mcpClaude) as? Bool ?? true
        result.mcpCodex = defaults.object(forKey: Key.mcpCodex) as? Bool ?? true
        result.mcpGrok = defaults.object(forKey: Key.mcpGrok) as? Bool ?? true
        result.proxyURL = text(defaults, Key.proxyURL) ?? defaultProxyURL
        result.mcpServers = text(defaults, Key.mcpServers) ?? ""
        result.sshHost = text(defaults, Key.sshHost) ?? ""
        result.remoteCommand = text(defaults, Key.remoteCommand) ?? ""
        result.verifyURL = text(defaults, Key.verifyURL) ?? ""
        result.verifyExpected = text(defaults, Key.verifyExpected) ?? ""
        return result
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Key.enabled)
        defaults.set(mainGroup, forKey: Key.mainGroup)
        defaults.set(apiGroup, forKey: Key.apiGroup)
        defaults.set(bypassHost, forKey: Key.bypassHost)
        defaults.set(networkService, forKey: Key.networkService)
        defaults.set(mcpClaude, forKey: Key.mcpClaude)
        defaults.set(mcpCodex, forKey: Key.mcpCodex)
        defaults.set(mcpGrok, forKey: Key.mcpGrok)
        defaults.set(proxyURL, forKey: Key.proxyURL)
        defaults.set(mcpServers, forKey: Key.mcpServers)
        defaults.set(sshHost, forKey: Key.sshHost)
        defaults.set(remoteCommand, forKey: Key.remoteCommand)
        defaults.set(verifyURL, forKey: Key.verifyURL)
        defaults.set(verifyExpected, forKey: Key.verifyExpected)
    }

    /// A stored value, or nil when it is missing or blank so the default applies.
    private static func text(_ defaults: UserDefaults, _ key: String) -> String? {
        guard let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// The two settings that reach `networksetup` as root. A value is passed as one argument (never through a shell), but
/// a leading dash would still be read as an option, so it is refused, as are blanks and control characters.
public enum SandboxValidation {
    public struct Invalid: LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }
    }

    public static func networkService(_ raw: String) throws -> String {
        try clean(raw, what: "network service name", allowSpaces: true)
    }

    public static func bypassHost(_ raw: String) throws -> String {
        try clean(raw, what: "proxy bypass host", allowSpaces: false)
    }

    /// The sandbox to ssh to. It becomes one argument to `ssh`, after `--`, and is never run as root.
    public static func sshHost(_ raw: String) throws -> String {
        try clean(raw, what: "ssh host", allowSpaces: false)
    }

    /// The remote command. The remote shell reads it, as a person's own ssh command would be; only blanks and control
    /// characters are refused.
    public static func remoteCommand(_ raw: String) throws -> String {
        try clean(raw, what: "remote command", allowSpaces: true)
    }

    /// A `socks5://host:port` URL. `socks5h` is refused on purpose: it resolves names on the proxy, so the hosts-file
    /// entry for the sandbox would be ignored and the request would reach the real server.
    public static func proxyURL(_ raw: String) throws -> (url: String, hostPort: String) {
        let value = try clean(raw, what: "proxy URL", allowSpaces: false)
        if value.lowercased().hasPrefix("socks5h://") {
            throw Invalid(message: "The proxy URL must start with socks5://, not socks5h://. socks5h resolves names on the proxy, which ignores /etc/hosts and sends the request to the real server.")
        }
        guard value.lowercased().hasPrefix("socks5://") else {
            throw Invalid(message: "The proxy URL \u{201C}\(value)\u{201D} must start with socks5://.")
        }
        let hostPort = String(value.dropFirst("socks5://".count))
        let parts = hostPort.split(separator: ":", omittingEmptySubsequences: false)
        // Letters, digits, dots and dashes only: the host is written into JSON and TOML files and must not need escaping.
        let hostOK = parts.first.map { !$0.isEmpty && $0.unicodeScalars.allSatisfy { $0 == "." || $0 == "-" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) } } ?? false
        guard parts.count == 2, hostOK, let port = Int(parts[1]), (1...65535).contains(port) else {
            throw Invalid(message: "The proxy URL \u{201C}\(value)\u{201D} must look like socks5://127.0.0.1:8080.")
        }
        return (value, hostPort)
    }

    private static func clean(_ raw: String, what: String, allowSpaces: Bool) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { throw Invalid(message: "The \(what) is empty.") }
        guard !value.hasPrefix("-") else { throw Invalid(message: "The \(what) \u{201C}\(value)\u{201D} cannot start with a dash.") }
        let bad = value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                || (!allowSpaces && CharacterSet.whitespaces.contains(scalar))
        }
        guard !bad else { throw Invalid(message: "The \(what) \u{201C}\(value)\u{201D} has characters that are not allowed.") }
        return value
    }
}
