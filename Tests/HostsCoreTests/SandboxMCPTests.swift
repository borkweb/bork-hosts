import Foundation
import Testing
@testable import HostsCore

private let proxy = "socks5://127.0.0.1:8080"

private func json(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func env(_ root: [String: Any], _ server: String) -> [String: Any]? {
    ((root["mcpServers"] as? [String: Any])?[server] as? [String: Any])?["env"] as? [String: Any]
}

struct MCPRouteTests {
    @Test func aNameAloneGetsTheTwoHttpVariables() throws {
        #expect(try MCPRoute.parse("my-server") == [MCPRoute(name: "my-server", envKeys: ["HTTPS_PROXY", "HTTP_PROXY"])])
    }

    @Test func anEqualsSignNamesTheVariables() throws {
        #expect(try MCPRoute.parse("other-server=SOCKS_PROXY") == [MCPRoute(name: "other-server", envKeys: ["SOCKS_PROXY"])])
        #expect(try MCPRoute.parse("a=X_ONE+X_TWO")[0].envKeys == ["X_ONE", "X_TWO"])
    }

    @Test func aTypicalSettingParses() throws {
        let routes = try MCPRoute.parse("my-server, other-server=SOCKS_PROXY")
        #expect(routes.map(\.name) == ["my-server", "other-server"])
        #expect(routes[1].envKeys == ["SOCKS_PROXY"])
    }

    @Test func blankEntriesAreIgnoredAndAnEmptyListIsEmpty() throws {
        #expect(try MCPRoute.parse(" , ,").isEmpty)
        #expect(try MCPRoute.parse("").isEmpty)
    }

    @Test func badVariableNamesAreRefused() {
        #expect(throws: (any Error).self) { try MCPRoute.parse("a=1BAD") }
        #expect(throws: (any Error).self) { try MCPRoute.parse("a=") }
        #expect(throws: (any Error).self) { try MCPRoute.parse("a=HAS SPACE") }
        #expect(throws: (any Error).self) { try MCPRoute.parse("=SOCKS_PROXY") }
    }
}

struct ClaudeConfigTests {
    let routes = [MCPRoute(name: "my-server", envKeys: ["HTTPS_PROXY", "HTTP_PROXY"]), MCPRoute(name: "other-server", envKeys: ["SOCKS_PROXY"])]

    func sample() throws -> Data {
        try json(["numStartups": 12, "theme": "dark", "mcpServers": [
            "my-server": ["command": "npx", "args": ["-y", "example-mcp-server"]],
            "other-server": ["command": "npx", "env": ["WP_API_URL": "https://example.com/mcp"]],
            "other": ["command": "x"],
        ], "projects": ["/p": ["mcpServers": ["my-server": ["command": "z"]]]]])
    }

    @Test func onAddsTheProxyToTheNamedServersAndKeepsTheRest() throws {
        let result = try ClaudeConfig.apply(.on, routes: routes, proxyURL: proxy, to: sample())
        let root = try object(#require(result.data))
        #expect(env(root, "my-server")?["HTTPS_PROXY"] as? String == proxy)
        #expect(env(root, "my-server")?["HTTP_PROXY"] as? String == proxy)
        #expect(env(root, "other-server")?["SOCKS_PROXY"] as? String == proxy)
        #expect(env(root, "other-server")?["WP_API_URL"] as? String == "https://example.com/mcp", "other variables stay")
        #expect(env(root, "other") == nil, "servers not named are untouched")
        #expect(root["numStartups"] as? Int == 12)
        #expect(root["theme"] as? String == "dark")
        #expect(((root["projects"] as? [String: Any])?["/p"] as? [String: Any])?["mcpServers"] != nil, "project entries are not touched")
        #expect(result.routed == ["my-server", "other-server"])
        #expect(result.missing.isEmpty)
    }

    @Test func onTwiceChangesNothingTheSecondTime() throws {
        let once = try #require(ClaudeConfig.apply(.on, routes: routes, proxyURL: proxy, to: sample()).data)
        let twice = try ClaudeConfig.apply(.on, routes: routes, proxyURL: proxy, to: once)
        #expect(twice.data == nil)
        #expect(twice.routed == ["my-server", "other-server"])
    }

    @Test func offRestoresTheFileToWhatItWasInContent() throws {
        let original = try sample()
        let on = try #require(ClaudeConfig.apply(.on, routes: routes, proxyURL: proxy, to: original).data)
        let off = try #require(ClaudeConfig.apply(.off, routes: routes, proxyURL: proxy, to: on).data)
        #expect(try object(off) as NSDictionary == object(original) as NSDictionary, "an env that was never there is not left empty")
    }

    @Test func offKeepsAValueYouSetYourself() throws {
        let data = try json(["mcpServers": ["other-server": ["env": ["SOCKS_PROXY": "socks5://10.9.9.9:1", "KEEP": "1"]]]])
        let result = try ClaudeConfig.apply(.off, routes: [routes[1]], proxyURL: proxy, to: data)
        #expect(result.data == nil)
    }

    @Test func offOnlyDropsOurVariablesFromAMixedEnv() throws {
        let data = try json(["mcpServers": ["other-server": ["env": ["SOCKS_PROXY": proxy, "KEEP": "1"]]]])
        let root = try object(#require(ClaudeConfig.apply(.off, routes: [routes[1]], proxyURL: proxy, to: data).data))
        #expect(env(root, "other-server")?["KEEP"] as? String == "1")
        #expect(env(root, "other-server")?["SOCKS_PROXY"] == nil)
    }

    @Test func serversNotInTheFileAreReportedMissing() throws {
        let data = try json(["mcpServers": ["other-server": [:]]])
        let result = try ClaudeConfig.apply(.on, routes: routes, proxyURL: proxy, to: data)
        #expect(result.missing == ["my-server"])
        #expect(result.routed == ["other-server"])
    }

    @Test func aServerThatUsesAUrlIsReportedNotChanged() throws {
        let data = try json(["mcpServers": ["other-server": ["type": "http", "url": "https://example.com/mcp"]]])
        let result = try ClaudeConfig.apply(.on, routes: routes, proxyURL: proxy, to: data)
        #expect(result.data == nil)
        #expect(result.unsupported == ["other-server"])
    }

    @Test func aFileWithNoServersIsNotChanged() throws {
        let result = try ClaudeConfig.apply(.on, routes: routes, proxyURL: proxy, to: json(["theme": "dark"]))
        #expect(result.data == nil)
        #expect(result.routed.isEmpty)
        #expect(result.missing == ["my-server", "other-server"])
    }

    @Test func aFileThatIsNotAnObjectOrNotJsonThrows() {
        #expect(throws: (any Error).self) { try ClaudeConfig.apply(.on, routes: routes, proxyURL: proxy, to: Data("[1]".utf8)) }
        #expect(throws: (any Error).self) { try ClaudeConfig.apply(.on, routes: routes, proxyURL: proxy, to: Data("nope".utf8)) }
    }

    @Test func slashesAndNonAsciiSurviveTheRoundTrip() throws {
        let data = Data(#"{"mcpServers":{"other-server":{"command":"a/b"}},"note":"caf\u00e9 https://x.example/y"}"#.utf8)
        let out = try #require(ClaudeConfig.apply(.on, routes: [routes[1]], proxyURL: proxy, to: data).data)
        let text = String(decoding: out, as: UTF8.self)
        #expect(text.contains("https://x.example/y"))
        #expect(text.contains("café"))
        #expect(!text.contains("\\/"))
    }
}

struct SandboxMCPStepTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bork-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func step(files: [MCPClient: URL], backups: URL? = nil, servers: String = "my-server, other-server=SOCKS_PROXY", proxyURL: String = proxy,
              clients: Set<MCPClient> = Set(MCPClient.allCases)) -> SandboxMCP {
        var prefs = SandboxPreferences()
        prefs.mcpServers = servers
        prefs.proxyURL = proxyURL
        prefs.mcpClaude = clients.contains(.claude)
        prefs.mcpCodex = clients.contains(.codex)
        prefs.mcpGrok = clients.contains(.grok)
        return SandboxMCP(preferences: { prefs }, files: files, backupDirectory: backups)
    }

    let toml = """
    model = "gpt"

    # a comment
    [mcp_servers.my-server]
    command = "npx"
    args = ["-y", "example-mcp-server"]

    [mcp_servers.other-server]
    url = "https://mcp.example.com/mcp"

    [tui]
    theme = "x"

    """

    @Test func onThenOffEditsAClaudeFileOnDiskAndKeepsABackupAndItsPermissions() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".claude.json")
        let original = try json(["mcpServers": ["my-server": ["command": "npx"]]])
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let mcp = step(files: [.claude: file], backups: dir.appendingPathComponent("backups"))

        #expect(await mcp.apply(.on) == .done)
        let on = try object(Data(contentsOf: file))
        #expect(env(on, "my-server")?["HTTPS_PROXY"] as? String == proxy)
        #expect(try Data(contentsOf: dir.appendingPathComponent("backups/claude-config.before-sandbox")) == original)
        #expect(try (FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        #expect(await mcp.apply(.off) == .done)
        #expect(try env(object(Data(contentsOf: file)), "my-server") == nil)
    }

    @Test func allThreeToolsAreEditedAndPutBack() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = dir.appendingPathComponent("claude.json"), codex = dir.appendingPathComponent("codex.toml"), grok = dir.appendingPathComponent("grok.toml")
        let claudeData = try json(["mcpServers": ["my-server": ["command": "npx"]]])
        try claudeData.write(to: claude)
        try Data(toml.utf8).write(to: codex)
        try Data("[mcp_servers.my-server]\ncommand = \"npx\"\n".utf8).write(to: grok)
        let mcp = step(files: [.claude: claude, .codex: codex, .grok: grok])

        let outcome = await mcp.apply(.on)
        guard case let .doneWith(note) = outcome else { Issue.record("expected doneWith, got \(outcome)"); return }
        #expect(note.contains("other-server in Codex uses a URL"))
        #expect(try String(contentsOf: codex, encoding: .utf8).contains("env = { HTTPS_PROXY = \"\(proxy)\", HTTP_PROXY = \"\(proxy)\" }"))
        #expect(try String(contentsOf: grok, encoding: .utf8).contains("HTTPS_PROXY"))
        #expect(try env(object(Data(contentsOf: claude)), "my-server")?["HTTP_PROXY"] as? String == proxy)

        _ = await mcp.apply(.off)
        #expect(try String(contentsOf: codex, encoding: .utf8) == toml, "the Codex file is exactly as it was")
        #expect(try String(contentsOf: grok, encoding: .utf8) == "[mcp_servers.my-server]\ncommand = \"npx\"\n")
        #expect(try object(Data(contentsOf: claude)) as NSDictionary == object(claudeData) as NSDictionary)
    }

    @Test func aToolTurnedOffInSettingsIsLeftAlone() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let codex = dir.appendingPathComponent("codex.toml")
        try Data(toml.utf8).write(to: codex)
        let outcome = await step(files: [.codex: codex], clients: [.claude]).apply(.on)
        guard case .skipped = outcome else { Issue.record("expected skipped, got \(outcome)"); return }
        #expect(try String(contentsOf: codex, encoding: .utf8) == toml)
    }

    @Test func aBrokenFileFailsItsToolButTheOthersStillRun() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = dir.appendingPathComponent("claude.json"), codex = dir.appendingPathComponent("codex.toml")
        try Data("not json".utf8).write(to: claude)
        try Data(toml.utf8).write(to: codex)
        let outcome = await step(files: [.claude: claude, .codex: codex]).apply(.on)
        guard case let .failed(message) = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(message.contains("Claude Code"))
        #expect(try String(contentsOf: claude, encoding: .utf8) == "not json")
        #expect(try String(contentsOf: codex, encoding: .utf8).contains("HTTPS_PROXY"), "Codex was still done")
    }

    @Test func missingFilesAreSkippedNotFailed() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = await step(files: [.claude: dir.appendingPathComponent("nope.json")]).apply(.on)
        guard case .skipped = outcome else { Issue.record("expected skipped, got \(outcome)"); return }
    }

    @Test func noMatchingServerIsSkippedAndTheFileIsLeftAlone() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".claude.json")
        let original = try json(["mcpServers": ["unrelated": [:]]])
        try original.write(to: file)
        let outcome = await step(files: [.claude: file]).apply(.on)
        guard case let .skipped(reason) = outcome else { Issue.record("expected skipped, got \(outcome)"); return }
        #expect(reason.contains("my-server"))
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func aBlankServerListSkipsTheStep() async throws {
        let outcome = await step(files: [:], servers: "").apply(.on)
        guard case .skipped = outcome else { Issue.record("expected skipped, got \(outcome)"); return }
    }

    @Test func aRemoteDnsProxyIsRefusedBeforeAnythingIsWritten() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".claude.json")
        let original = try json(["mcpServers": ["my-server": [:]]])
        try original.write(to: file)
        let outcome = await step(files: [.claude: file], proxyURL: "socks5h://127.0.0.1:8080").apply(.on)
        guard case let .failed(message) = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(message.contains("socks5h"))
        #expect(try Data(contentsOf: file) == original)
    }
}

struct TOMLConfigTests {
    let keys = MCPRoute(name: "srv", envKeys: ["HTTPS_PROXY", "HTTP_PROXY"])
    let socks = MCPRoute(name: "srv", envKeys: ["SOCKS_PROXY"])

    func run(_ mode: SandboxMode, _ route: MCPRoute, _ text: String) throws -> (text: String?, result: MCPEditResult) {
        let result = try TOMLConfig.apply(mode, routes: [route], proxyURL: proxy, to: Data(text.utf8))
        return (result.data.map { String(decoding: $0, as: UTF8.self) }, result)
    }

    @Test func addsAnInlineEnvWhenThereIsNone() throws {
        let src = "[mcp_servers.srv]\ncommand = \"npx\"\nargs = [\"-y\", \"x\"]\n\n[other]\na = 1\n"
        let out = try #require(run(.on, socks, src).text)
        #expect(out == "[mcp_servers.srv]\ncommand = \"npx\"\nargs = [\"-y\", \"x\"]\nenv = { SOCKS_PROXY = \"\(proxy)\" }\n\n[other]\na = 1\n")
        #expect(try run(.off, socks, out).text == src, "off restores the file exactly")
    }

    @Test func addsToAnExistingEnvTableAndRemovesOnlyItsOwnLines() throws {
        let src = "[mcp_servers.srv]\ncommand = \"x\"\n\n[mcp_servers.srv.env]\nKEEP = \"1\"\n\n[next]\n"
        let on = try #require(run(.on, keys, src).text)
        #expect(on == "[mcp_servers.srv]\ncommand = \"x\"\n\n[mcp_servers.srv.env]\nKEEP = \"1\"\nHTTPS_PROXY = \"\(proxy)\"\nHTTP_PROXY = \"\(proxy)\"\n\n[next]\n")
        #expect(try run(.off, keys, on).text == src)
    }

    @Test func anEnvTableThatOnlyHeldTheProxyIsRemovedOnOff() throws {
        let src = "[mcp_servers.srv]\ncommand = \"x\"\n\n[mcp_servers.srv.env]\nSOCKS_PROXY = \"\(proxy)\"\n\n[next]\n"
        #expect(try run(.off, socks, src).text == "[mcp_servers.srv]\ncommand = \"x\"\n\n[next]\n")
    }

    @Test func editsAnInlineEnvAndKeepsItsOtherEntriesAndComment() throws {
        let src = "[mcp_servers.srv]\ncommand = \"x\"\nenv = { A = \"1, 2\", B = 'b' }  # keep\n"
        let on = try #require(run(.on, socks, src).text)
        #expect(on == "[mcp_servers.srv]\ncommand = \"x\"\nenv = { A = \"1, 2\", B = 'b', SOCKS_PROXY = \"\(proxy)\" }  # keep\n")
        #expect(try run(.off, socks, on).text == "[mcp_servers.srv]\ncommand = \"x\"\nenv = { A = \"1, 2\", B = 'b' }  # keep\n")
    }

    @Test func aDifferentValueIsReplacedOnOnAndKeptOnOff() throws {
        let src = "[mcp_servers.srv]\ncommand = \"x\"\nenv = { SOCKS_PROXY = \"socks5://10.0.0.9:1\" }\n"
        #expect(try run(.off, socks, src).text == nil)
        #expect(try run(.on, socks, src).text == "[mcp_servers.srv]\ncommand = \"x\"\nenv = { SOCKS_PROXY = \"\(proxy)\" }\n")
    }

    @Test func onTwiceChangesNothingTheSecondTime() throws {
        let on = try #require(run(.on, keys, "[mcp_servers.srv]\ncommand = \"x\"\n").text)
        let again = try run(.on, keys, on)
        #expect(again.text == nil)
        #expect(again.result.routed == ["srv"])
    }

    @Test func aUrlServerIsReportedAndNotChanged() throws {
        let r = try run(.on, socks, "[mcp_servers.srv]\nurl = \"https://example.com/mcp\"\n")
        #expect(r.text == nil)
        #expect(r.result.unsupported == ["srv"])
        #expect(r.result.routed.isEmpty)
    }

    @Test func aMissingServerIsReported() throws {
        let r = try run(.on, socks, "[mcp_servers.other]\ncommand = \"x\"\n")
        #expect(r.text == nil)
        #expect(r.result.missing == ["srv"])
    }

    @Test func aHeaderInsideAMultiLineStringOrArrayIsNotATable() throws {
        let src = "[mcp_servers.srv]\ncommand = \"x\"\nargs = [\n  \"a\",\n  \"b\",\n]\nnote = \"\"\"\n[mcp_servers.srv.env]\n\"\"\"\n\n[next]\n"
        let out = try #require(run(.on, socks, src).text)
        #expect(out.contains("\"\"\"\n[mcp_servers.srv.env]\n\"\"\"\nenv = { SOCKS_PROXY"), "the env goes after the last value of the table, not inside the string")
        #expect(try run(.off, socks, out).text == src)
    }

    @Test func quotedNamesAndHeadersWithCommentsAreRecognized() throws {
        let src = "[ mcp_servers . \"srv\" ]  # mine\ncommand = \"x\"\n"
        #expect(try run(.on, socks, src).result.routed == ["srv"])
    }

    @Test func aServerThatIsLastInTheFileWithNoTrailingNewlineWorks() throws {
        let src = "[mcp_servers.srv]\ncommand = \"x\""
        let on = try #require(run(.on, socks, src).text)
        #expect(on == "[mcp_servers.srv]\ncommand = \"x\"\nenv = { SOCKS_PROXY = \"\(proxy)\" }")
        #expect(try run(.off, socks, on).text == src)
    }

    @Test func dottedEnvKeysAndMultiLineValuesAreRefusedNotGuessed() {
        #expect(throws: (any Error).self) { try run(.on, socks, "[mcp_servers.srv]\ncommand = \"x\"\nenv.A = \"1\"\n") }
        #expect(throws: (any Error).self) { try run(.on, socks, "[mcp_servers.srv]\ncommand = \"x\"\nenv = someday\n") }
    }

    @Test func otherServersAndTheRestOfTheFileAreUntouched() throws {
        let src = "a = 1\n[mcp_servers.node_repl]\ncommand = \"n\"\n[mcp_servers.node_repl.env]\nX = \"1\"\n\n[mcp_servers.srv]\ncommand = \"x\"\n\n[[skills.config]]\npath = \"p\"\n"
        let out = try #require(run(.on, socks, src).text)
        #expect(out.hasPrefix("a = 1\n[mcp_servers.node_repl]\ncommand = \"n\"\n[mcp_servers.node_repl.env]\nX = \"1\"\n\n[mcp_servers.srv]"))
        #expect(out.hasSuffix("\n\n[[skills.config]]\npath = \"p\"\n"))
    }
}

struct SandboxValidationExtraTests {
    @Test func theProxyMustBeSocks5WithAHostAndPort() throws {
        #expect(try SandboxValidation.proxyURL("socks5://127.0.0.1:8080").hostPort == "127.0.0.1:8080")
        for bad in ["socks5h://127.0.0.1:8080", "socks5://a\"b:1", "socks5://a\\b:1", "http://127.0.0.1:8080", "socks5://127.0.0.1", "socks5://:8080", "socks5://h:0", "socks5://h:99999", "", "socks5://a b:1"] {
            #expect(throws: (any Error).self, "\(bad)") { try SandboxValidation.proxyURL(bad) }
        }
    }

    @Test func theSshHostCannotBeReadAsAnOption() throws {
        #expect(try SandboxValidation.sshHost(" me@box.example ") == "me@box.example")
        for bad in ["-oProxyCommand=x", "", "a b", "a\nb"] {
            #expect(throws: (any Error).self, "\(bad)") { try SandboxValidation.sshHost(bad) }
        }
    }

    @Test func theRemoteCommandMayHaveSpacesButNotNewlines() throws {
        #expect(try SandboxValidation.remoteCommand("cd /srv/app && bin/enable") == "cd /srv/app && bin/enable")
        #expect(throws: (any Error).self) { try SandboxValidation.remoteCommand("a\nb") }
        #expect(throws: (any Error).self) { try SandboxValidation.remoteCommand("  ") }
    }
}

final class CommandBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, [String], TimeInterval)] = []
    func add(_ e: String, _ a: [String], _ t: TimeInterval) { lock.lock(); items.append((e, a, t)); lock.unlock() }
    var calls: [(executable: String, arguments: [String], timeout: TimeInterval)] { lock.lock(); defer { lock.unlock() }; return items.map { ($0.0, $0.1, $0.2) } }
}

/// A scripted ssh: answers each call by what it is (check, quiet sign-in, or the command) and remembers them.
final class FakeSSH: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[String]] = []
    private var opened: [String] = []
    private var paused = 0
    /// Answers to `-O check`, in order; the last one repeats.
    let checks: [Int32]
    var quiet: (status: Int32, output: String) = (0, "")
    var command: (status: Int32, output: String, timedOut: Bool) = (0, "", false)

    init(checks: [Int32]) { self.checks = checks }

    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return items }
    var signInOpened: [String] { lock.lock(); defer { lock.unlock() }; return opened }
    var pauses: Int { lock.lock(); defer { lock.unlock() }; return paused }

    func kinds() -> [String] {
        calls.map { args in
            if args.starts(with: ["-O", "check"]) { return "check" }
            if args.contains("-fN") { return "quiet" }
            return "command"
        }
    }

    private func handle(_ arguments: [String]) -> (status: Int32, output: String, timedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        items.append(arguments)
        if arguments.starts(with: ["-O", "check"]) {
            let n = items.filter { $0.starts(with: ["-O", "check"]) }.count
            return (checks[min(n - 1, checks.count - 1)], "", false)
        }
        if arguments.contains("-fN") { return (quiet.status, quiet.output, false) }
        return command
    }

    private func recordSignIn(_ script: String) { lock.lock(); opened.append(script); lock.unlock() }
    private func recordPause() { lock.lock(); paused += 1; lock.unlock() }

    func ssh(host: String = "sandbox", command: String = "bin/enable") -> SandboxSSH {
        var p = SandboxPreferences()
        p.sshHost = host
        p.remoteCommand = command
        let prefs = p
        return SandboxSSH(preferences: { prefs }, run: { [self] _, arguments, _ in handle(arguments) },
                          openSignIn: { [self] script in recordSignIn(script) },
                          pause: { [self] _ in recordPause() },
                          controlPath: { "/cp/%C" })
    }
}

struct SandboxSSHTests {
    @Test func anOpenConnectionRunsTheCommandOverItWithNoSignIn() async {
        let fake = FakeSSH(checks: [0])
        let outcome = await fake.ssh(command: "cd /srv && bin/enable").runRemote()
        #expect(outcome == .done)
        #expect(fake.kinds() == ["check", "command"])
        #expect(fake.calls[1] == ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ControlMaster=no", "-o", "ControlPath=/cp/%C", "--", "sandbox", "cd /srv && bin/enable"])
        #expect(fake.signInOpened.isEmpty)
    }

    @Test func withNoConnectionItTriesToOpenOneQuietlyAndThenRuns() async {
        let fake = FakeSSH(checks: [255])
        let outcome = await fake.ssh().runRemote()
        #expect(outcome == .done)
        #expect(fake.kinds() == ["check", "quiet", "command"])
        #expect(fake.calls[1] == ["-fN", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ControlMaster=yes", "-o", "ControlPersist=4h", "-o", "ControlPath=/cp/%C", "--", "sandbox"])
        #expect(fake.signInOpened.isEmpty, "no second factor was asked for, so no window")
    }

    @Test func aSecondFactorOpensTheSignInWindowAndWaitsForIt() async {
        let fake = FakeSSH(checks: [255, 255, 255, 0])
        fake.quiet = (255, "user@box: Permission denied (keyboard-interactive).")
        let outcome = await fake.ssh().runRemote()
        #expect(outcome == .done)
        #expect(fake.signInOpened.count == 1)
        #expect(fake.signInOpened[0].contains("-o ControlMaster=yes -o ControlPersist=4h -o ControlPath='/cp/%C' -- 'sandbox'"))
        #expect(fake.pauses == 3, "after the first check failed it polled once per pause until the connection opened")
        #expect(fake.kinds().last == "command")
    }

    @Test func aSignInThatNeverFinishesFailsWithWhatToDo() async {
        let fake = FakeSSH(checks: [255])
        fake.quiet = (255, "Permission denied (keyboard-interactive).")
        let outcome = await fake.ssh().runRemote()
        guard case let .failed(message) = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(message.contains("Terminal window"))
        #expect(fake.pauses == 120)
        #expect(!fake.kinds().contains("command"))
    }

    @Test func anUnreachableHostFailsAtOnceWithoutAWindow() async {
        let fake = FakeSSH(checks: [255])
        fake.quiet = (255, "ssh: Could not resolve hostname nope: nodename nor servname provided")
        let outcome = await fake.ssh().runRemote()
        guard case let .failed(message) = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(message.contains("Could not resolve hostname"))
        #expect(fake.signInOpened.isEmpty)
        #expect(fake.pauses == 0)
    }

    @Test func theSignInScriptQuotesItsValuesForTheShell() {
        let script = SandboxSSH.signInScript(host: "me@box'; touch x; '", controlPath: "/cp/it's/%C")
        #expect(script.contains("-- 'me@box'\\''; touch x; '\\'''"))
        #expect(script.contains("ControlPath='/cp/it'\\''s/%C'"))
        #expect(script.hasPrefix("#!/bin/sh\n"))
    }

    @Test func aBlankHostSkipsWithoutRunningAnything() async {
        let fake = FakeSSH(checks: [0])
        let outcome = await fake.ssh(host: "  ").runRemote()
        guard case .skipped = outcome else { Issue.record("expected skipped, got \(outcome)"); return }
        #expect(fake.calls.isEmpty)
    }

    @Test func aHostThatLooksLikeAnOptionFailsWithoutRunningAnything() async {
        let fake = FakeSSH(checks: [0])
        let outcome = await fake.ssh(host: "-oProxyCommand=x").runRemote()
        guard case .failed = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(fake.calls.isEmpty)
    }

    @Test func aNonZeroExitFromTheCommandFailsWithSshsOwnMessage() async {
        let fake = FakeSSH(checks: [0])
        fake.command = (1, "enable: not allowed on this sandbox", false)
        #expect(await fake.ssh().runRemote() == .failed("enable: not allowed on this sandbox"))
    }

    @Test func aMissingScriptSuggestsGivingTheFullPath() async {
        let fake = FakeSSH(checks: [0])
        fake.command = (127, "bash: line 1: bin/enable: No such file or directory", false)
        let outcome = await fake.ssh().runRemote()
        guard case let .failed(message) = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(message.contains("No such file or directory"))
        #expect(message.contains("full path"))
    }

    @Test func aCommandThatRunsTooLongFails() async {
        let fake = FakeSSH(checks: [0])
        fake.command = (15, "", true)
        let outcome = await fake.ssh().runRemote()
        guard case let .failed(message) = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(message.contains("60 seconds"))
    }
}

struct SandboxProbeTests {
    static let page = "https://check.example.com/status"

    func probe(_ box: CommandBox, status: Int32 = 0, output: String, verifyURL: String = page, expected: String = "sandbox: yes",
               proxyURL: String = proxy) -> SandboxProbe {
        var p = SandboxPreferences()
        p.verifyURL = verifyURL
        p.verifyExpected = expected
        p.proxyURL = proxyURL
        return SandboxProbe(preferences: { p }, run: { e, a, t in box.add(e, a, t); return (status, output, false) })
    }

    @Test func fetchesThePageThroughTheLocalDnsSocksProxy() async {
        let box = CommandBox()
        let outcome = await probe(box, output: "result: sandbox: yes").verify()
        #expect(outcome == .done)
        #expect(box.calls[0].executable == "/usr/bin/curl")
        #expect(box.calls[0].arguments == ["-sS", "--max-time", "10", "--socks5", "127.0.0.1:8080", "--", Self.page])
        #expect(!box.calls[0].arguments.contains("--socks5-hostname"))
    }

    @Test func aReplyWithoutTheExpectedTextFails() async {
        let outcome = await probe(CommandBox(), output: "sandbox: no").verify()
        guard case let .failed(message) = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(message.contains("sandbox: yes"))
    }

    @Test func withNoExpectedTextAnySuccessfulReplyPasses() async {
        #expect(await probe(CommandBox(), output: "anything", expected: "").verify() == .done)
    }

    @Test func aCurlFailureMentionsTheProxy() async {
        let outcome = await probe(CommandBox(), status: 7, output: "curl: (7) Failed to connect").verify()
        guard case let .failed(message) = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(message.contains("127.0.0.1:8080"))
    }

    @Test func aBlankPageSkips() async {
        let box = CommandBox()
        let outcome = await probe(box, output: "", verifyURL: "").verify()
        guard case .skipped = outcome else { Issue.record("expected skipped, got \(outcome)"); return }
        #expect(box.calls.isEmpty)
    }
}

struct UserCommandTimeoutTests {
    @Test func aCommandThatRunsTooLongIsStopped() async throws {
        let started = Date()
        let result = try await UserCommand.run("/bin/sleep", ["30"], timeout: 0.3)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aQuickCommandIsNotMarkedTimedOut() async throws {
        let result = try await UserCommand.run("/bin/echo", ["hi"], timeout: 5)
        #expect(!result.timedOut)
        #expect(result.stdout == "hi\n")
    }
}
