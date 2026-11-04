import Foundation

/// The MCP half of the sandbox: points chosen MCP servers at the local SOCKS proxy while the sandbox is on.
public protocol SandboxMCPRouting: Sendable {
    func apply(_ mode: SandboxMode) async -> StepOutcome
}

/// One MCP server to route and the environment variables that carry the proxy to it.
public struct MCPRoute: Equatable, Sendable {
    public var name: String
    public var envKeys: [String]

    public init(name: String, envKeys: [String]) {
        self.name = name
        self.envKeys = envKeys
    }

    /// What a server gets when its entry names no variables.
    public static let defaultKeys = ["HTTPS_PROXY", "HTTP_PROXY"]

    struct Invalid: LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    /// Reads `my-server, other=SOCKS_PROXY`: entries split by commas, each a server name with optional `=KEY+KEY`.
    public static func parse(_ text: String) throws -> [MCPRoute] {
        var routes: [MCPRoute] = []
        for raw in text.split(separator: ",") {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            if entry.isEmpty { continue }
            let halves = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = halves[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw Invalid(message: "An MCP server name is empty or has characters that are not allowed.")
            }
            var keys = defaultKeys
            if halves.count == 2 {
                keys = halves[1].split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
                guard !keys.isEmpty else { throw Invalid(message: "\u{201C}\(name)\u{201D} names no environment variable after the equals sign.") }
                for key in keys where !isEnvName(key) {
                    throw Invalid(message: "\u{201C}\(key)\u{201D} is not a valid environment variable name.")
                }
            }
            if let at = routes.firstIndex(where: { $0.name == name }) {
                routes[at].envKeys = Array(Set(routes[at].envKeys + keys)).sorted()
            } else {
                routes.append(MCPRoute(name: name, envKeys: keys))
            }
        }
        return routes
    }

    private static func isEnvName(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return key.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
    }
}

/// What an edit of one tool's config found and, when something must change, the new file.
public struct MCPEditResult: Equatable {
    /// The new file, or nil when nothing needs to change.
    public var data: Data?
    /// Servers that are in the file and now have (on) or no longer have (off) the proxy.
    public var routed: [String]
    /// Servers named in Settings that are not in the file.
    public var missing: [String]
    /// Servers in the file that use a URL, which an environment variable cannot reach.
    public var unsupported: [String]
}

/// `~/.claude.json`, changed one way only: the `env` of chosen entries under the top-level `mcpServers`.
/// Pure data in and out, so it is unit tested.
public enum ClaudeConfig {
    public typealias Result = MCPEditResult

    struct Invalid: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// Switching on sets each route's variables to `proxyURL`. Switching off removes a variable only when it still holds
    /// `proxyURL`, so a value you set yourself stays, and drops an `env` left empty. Everything else in the file is kept.
    public static func apply(_ mode: SandboxMode, routes: [MCPRoute], proxyURL: String, to data: Data) throws -> MCPEditResult {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Invalid(message: "The file is not a JSON object.")
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        var changed = false
        var out = MCPEditResult(data: nil, routed: [], missing: [], unsupported: [])
        for route in routes {
            guard var server = servers[route.name] as? [String: Any] else { out.missing.append(route.name); continue }
            if server["url"] is String, server["command"] == nil { out.unsupported.append(route.name); continue }
            out.routed.append(route.name)
            var env = server["env"] as? [String: Any] ?? [:]
            let before = NSDictionary(dictionary: env)
            for key in route.envKeys {
                switch mode {
                case .on: env[key] = proxyURL
                case .off: if env[key] as? String == proxyURL { env[key] = nil }
                }
            }
            guard !before.isEqual(to: env) else { continue }
            server["env"] = env.isEmpty ? nil : env
            servers[route.name] = server
            changed = true
        }
        guard changed else { return out }
        root["mcpServers"] = servers
        out.data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return out
    }
}

/// The tools whose MCP configuration the sandbox switch edits. Each reads a server's `env` only when it starts the
/// server, so a running session has to restart or reconnect it.
public enum MCPClient: String, CaseIterable, Sendable {
    case claude, codex, grok

    public var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .grok: return "Grok"
        }
    }

    /// Where the tool keeps its servers. Codex honors `CODEX_HOME`.
    public var fileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return ClaudeConfig.fileURL
        case .codex:
            let base = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".codex")
            return base.appendingPathComponent("config.toml")
        case .grok: return home.appendingPathComponent(".grok/config.toml")
        }
    }

    func apply(_ mode: SandboxMode, routes: [MCPRoute], proxyURL: String, to data: Data) throws -> MCPEditResult {
        switch self {
        case .claude: return try ClaudeConfig.apply(mode, routes: routes, proxyURL: proxyURL, to: data)
        case .codex, .grok: return try TOMLConfig.apply(mode, routes: routes, proxyURL: proxyURL, to: data)
        }
    }
}

extension SandboxPreferences {
    func isOn(_ client: MCPClient) -> Bool {
        switch client {
        case .claude: return mcpClaude
        case .codex: return mcpCodex
        case .grok: return mcpGrok
        }
    }
}

/// Points the MCP servers chosen in Settings at the SOCKS proxy by editing each tool's config file as you (no elevation).
///
/// An MCP server does not use macOS's proxy settings, so its own `env` must carry the proxy. Each file is copied
/// aside before it changes, written in one step, and read back to confirm. The tools also rewrite their files now and
/// then; if a write is lost to one of them, the read-back fails the step and running it again is safe. A tool whose
/// file does not exist is skipped, and a failure in one tool does not stop the others.
public struct SandboxMCP: SandboxMCPRouting {
    private let preferences: @Sendable () -> SandboxPreferences
    private let files: [MCPClient: URL]
    private let backupDirectory: URL?
    private let log: @Sendable (String) -> Void

    public init(preferences: @escaping @Sendable () -> SandboxPreferences = { .load() },
                files: [MCPClient: URL] = Dictionary(uniqueKeysWithValues: MCPClient.allCases.map { ($0, $0.fileURL) }),
                backupDirectory: URL? = BackupManager.defaultDirectory.deletingLastPathComponent(),
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.preferences = preferences
        self.files = files
        self.backupDirectory = backupDirectory
        self.log = log
    }

    public func apply(_ mode: SandboxMode) async -> StepOutcome {
        let prefs = preferences()
        do {
            let routes = try MCPRoute.parse(prefs.mcpServers)
            guard !routes.isEmpty else { return .skipped("No MCP servers are set in Settings") }
            let proxy = try SandboxValidation.proxyURL(prefs.proxyURL).url
            let clients = MCPClient.allCases.filter { prefs.isOn($0) }
            guard !clients.isEmpty else { return .skipped("No MCP tool is turned on in Settings") }

            var routedIn: [String] = []
            var failures: [String] = []
            var notes: [String] = []
            var missingIn: [String] = []
            var absent: [String] = []
            for client in clients {
                guard let url = files[client], let original = FileManager.default.contents(atPath: url.path) else {
                    absent.append(client.title)
                    continue
                }
                do {
                    let result = try client.apply(mode, routes: routes, proxyURL: proxy, to: original)
                    log("mcp \(mode.rawValue) \(client.rawValue): routed=\(result.routed) missing=\(result.missing) url=\(result.unsupported) change=\(result.data != nil)")
                    if let updated = result.data { try write(updated, replacing: original, client: client, at: url, mode: mode, routes: routes, proxy: proxy) }
                    if !result.routed.isEmpty { routedIn.append(client.title) }
                    if result.routed.isEmpty, !result.missing.isEmpty { missingIn.append(client.title) }
                    if !result.unsupported.isEmpty, mode == .on {
                        notes.append("\(result.unsupported.joined(separator: ", ")) in \(client.title) uses a URL, so it cannot take a proxy variable; use a stdio entry (see docs/sandbox.md).")
                    }
                } catch {
                    log("mcp \(client.rawValue) failed: \(error.localizedDescription)")
                    failures.append("\(client.title): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { return .failed(failures.joined(separator: " ")) }
            if routedIn.isEmpty {
                var reasons: [String] = []
                if !absent.isEmpty { reasons.append("no config file for \(absent.joined(separator: ", "))") }
                if !missingIn.isEmpty { reasons.append("none of \(routes.map(\.name).joined(separator: ", ")) in \(missingIn.joined(separator: ", "))") }
                return .skipped((reasons + notes).joined(separator: "; ").capitalizedFirst)
            }
            return notes.isEmpty ? .done : .doneWith(note: notes.joined(separator: " "))
        } catch {
            log("mcp failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    private func write(_ updated: Data, replacing original: Data, client: MCPClient, at url: URL, mode: SandboxMode,
                       routes: [MCPRoute], proxy: String) throws {
        let fm = FileManager.default
        let permissions = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        if let backupDirectory {
            try? fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            try? original.write(to: backupDirectory.appendingPathComponent("\(client.rawValue)-config.before-sandbox"), options: .atomic)
        }
        try updated.write(to: url, options: .atomic)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        // The tool may write this file too; applying the same switch again must find nothing left to do.
        guard let back = fm.contents(atPath: url.path),
              let again = try? client.apply(mode, routes: routes, proxyURL: proxy, to: back), again.data == nil else {
            throw Invalid(message: "\(url.lastPathComponent) was changed by another program while it was being updated. Run the switch again.")
        }
    }

    struct Invalid: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
