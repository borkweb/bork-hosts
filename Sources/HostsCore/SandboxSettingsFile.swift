import Foundation

/// The sandbox settings as a file you can save, move to another Mac and load again.
///
/// Importing is the one place settings come from outside the app, and some of them cause commands to run later (an
/// ssh host and command, MCP servers to change), so a file is checked field by field with the same rules the Settings
/// window's values get before they reach a command, and nothing is applied until the caller has shown the changes.
/// The panel's on/off choice (`enabled`) is never exported or imported: turning the feature on stays your decision on
/// this Mac. Fields missing from a file keep their current value; unknown fields are ignored.
public enum SandboxSettingsFile {
    public static let version = 1
    /// A settings file is a few hundred bytes; anything much bigger is not one.
    public static let maxBytes = 64 * 1024
    static let maxFieldLength = 1000

    public struct Invalid: LocalizedError, Equatable {
        public var message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// One setting that an import would change.
    public struct Change: Equatable, Sendable {
        public var label: String
        public var old: String
        public var new: String
        /// True for settings that make the app run something or change another file when the sandbox is switched on.
        public var actsOnSwitchOn: Bool
    }

    public struct Imported: Equatable, Sendable {
        public var preferences: SandboxPreferences
        public var includeAPI: Bool
        public var changes: [Change]
    }

    private struct Document: Codable {
        var version: Int
        var sandbox: Fields
    }

    private struct Fields: Codable {
        var mainGroup: String?
        var apiGroup: String?
        var bypassHost: String?
        var networkService: String?
        var includeAPI: Bool?
        var mcpClaude: Bool?
        var mcpCodex: Bool?
        var mcpGrok: Bool?
        var mcpServers: String?
        var proxyURL: String?
        var sshHost: String?
        var remoteCommand: String?
        var verifyURL: String?
        var verifyExpected: String?
    }

    // MARK: Export

    public static func export(_ preferences: SandboxPreferences, includeAPI: Bool) throws -> Data {
        let fields = Fields(mainGroup: preferences.mainGroup, apiGroup: preferences.apiGroup, bypassHost: preferences.bypassHost,
                            networkService: preferences.networkService, includeAPI: includeAPI, mcpClaude: preferences.mcpClaude,
                            mcpCodex: preferences.mcpCodex, mcpGrok: preferences.mcpGrok, mcpServers: preferences.mcpServers,
                            proxyURL: preferences.proxyURL, sshHost: preferences.sshHost, remoteCommand: preferences.remoteCommand,
                            verifyURL: preferences.verifyURL, verifyExpected: preferences.verifyExpected)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Document(version: version, sandbox: fields))
    }

    // MARK: Import

    /// Checks `data` and returns what the settings would become and what would change. Throws `Invalid` for a file
    /// that is not a settings file or has a value the app would not accept. Nothing is applied.
    public static func read(_ data: Data, current: SandboxPreferences, currentIncludeAPI: Bool) throws -> Imported {
        guard data.count <= maxBytes else { throw Invalid(message: "This file is too large to be a bork-hosts settings file.") }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) } catch {
            throw Invalid(message: "This is not a bork-hosts settings file.")
        }
        guard document.version == version else {
            throw Invalid(message: document.version > version
                ? "This settings file was made by a newer version of bork-hosts (file version \(document.version))."
                : "This settings file has an unsupported version (\(document.version)).")
        }
        let f = document.sandbox
        var p = current
        var includeAPI = currentIncludeAPI

        if let v = try text(f.mainGroup, "Main group") { p.mainGroup = v.isEmpty ? SandboxPreferences.defaultMainGroup : v }
        if let v = try text(f.apiGroup, "API group") { p.apiGroup = v.isEmpty ? SandboxPreferences.defaultAPIGroup : v }
        if let v = try text(f.bypassHost, "Proxy bypass host") {
            p.bypassHost = try v.isEmpty ? "" : check("Proxy bypass host") { try SandboxValidation.bypassHost(v) }
        }
        if let v = try text(f.networkService, "Network service") {
            p.networkService = try v.isEmpty ? "" : check("Network service") { try SandboxValidation.networkService(v) }
        }
        if let v = f.includeAPI { includeAPI = v }
        if let v = f.mcpClaude { p.mcpClaude = v }
        if let v = f.mcpCodex { p.mcpCodex = v }
        if let v = f.mcpGrok { p.mcpGrok = v }
        if let v = try text(f.mcpServers, "Servers to proxy") {
            if !v.isEmpty { _ = try check("Servers to proxy") { try MCPRoute.parse(v) } }
            p.mcpServers = v
        }
        if let v = try text(f.proxyURL, "SOCKS proxy") {
            p.proxyURL = try v.isEmpty ? SandboxPreferences.defaultProxyURL : check("SOCKS proxy") { try SandboxValidation.proxyURL(v).url }
        }
        if let v = try text(f.sshHost, "ssh host") {
            p.sshHost = try v.isEmpty ? "" : check("ssh host") { try SandboxValidation.sshHost(v) }
        }
        if let v = try text(f.remoteCommand, "Command to run") {
            p.remoteCommand = try v.isEmpty ? "" : check("Command to run") { try SandboxValidation.remoteCommand(v) }
        }
        if let v = try text(f.verifyURL, "Check page") {
            if !v.isEmpty { try check("Check page") { try checkPage(v) } }
            p.verifyURL = v
        }
        if let v = try text(f.verifyExpected, "Reply must contain") {
            if v.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                throw Invalid(message: "Reply must contain: has characters that are not allowed.")
            }
            p.verifyExpected = v
        }
        return Imported(preferences: p, includeAPI: includeAPI, changes: changes(from: current, currentIncludeAPI, to: p, includeAPI))
    }

    // MARK: Pieces

    /// A present value, trimmed and length-checked; nil when the file leaves the field out.
    private static func text(_ raw: String?, _ label: String) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= maxFieldLength else { throw Invalid(message: "\(label): is longer than \(maxFieldLength) characters.") }
        return value
    }

    /// Runs a validator and puts the field's name in front of its message.
    private static func check<T>(_ label: String, _ body: () throws -> T) throws -> T {
        do { return try body() } catch {
            throw Invalid(message: "\(label): \(error.localizedDescription)")
        }
    }

    private static func checkPage(_ value: String) throws {
        guard value.lowercased().hasPrefix("https://") || value.lowercased().hasPrefix("http://") else {
            throw Invalid(message: "must start with https:// or http://.")
        }
        if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0) }) {
            throw Invalid(message: "has characters that are not allowed.")
        }
    }

    private static func changes(from old: SandboxPreferences, _ oldAPI: Bool, to new: SandboxPreferences, _ newAPI: Bool) -> [Change] {
        func onOff(_ b: Bool) -> String { b ? "on" : "off" }
        func shown(_ s: String) -> String { s.isEmpty ? "(blank)" : s }
        let rows: [(String, String, String, Bool)] = [
            ("Main group", old.mainGroup, new.mainGroup, false),
            ("API group", old.apiGroup, new.apiGroup, false),
            ("Proxy bypass host", old.bypassHost, new.bypassHost, true),
            ("Network service", old.networkService, new.networkService, true),
            ("Include API group", onOff(oldAPI), onOff(newAPI), false),
            ("Claude Code MCP config", onOff(old.mcpClaude), onOff(new.mcpClaude), true),
            ("Codex MCP config", onOff(old.mcpCodex), onOff(new.mcpCodex), true),
            ("Grok MCP config", onOff(old.mcpGrok), onOff(new.mcpGrok), true),
            ("Servers to proxy", old.mcpServers, new.mcpServers, true),
            ("SOCKS proxy", old.proxyURL, new.proxyURL, true),
            ("ssh host", old.sshHost, new.sshHost, true),
            ("Command to run", old.remoteCommand, new.remoteCommand, true),
            ("Check page", old.verifyURL, new.verifyURL, true),
            ("Reply must contain", old.verifyExpected, new.verifyExpected, false),
        ]
        return rows.filter { $0.1 != $0.2 }.map { Change(label: $0.0, old: shown($0.1), new: shown($0.2), actsOnSwitchOn: $0.3) }
    }
}
