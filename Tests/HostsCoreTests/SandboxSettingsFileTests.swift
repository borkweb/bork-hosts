import Foundation
import Testing
@testable import HostsCore

struct SandboxSettingsFileTests {
    func configured() -> SandboxPreferences {
        var p = SandboxPreferences()
        p.enabled = true
        p.mainGroup = "staging"
        p.apiGroup = "staging api"
        p.bypassHost = "api.example.com"
        p.networkService = "Wi-Fi"
        p.mcpClaude = true
        p.mcpCodex = false
        p.mcpGrok = true
        p.mcpServers = "my-server, other=SOCKS_PROXY"
        p.proxyURL = "socks5://127.0.0.1:9090"
        p.sshHost = "me@box.example"
        p.remoteCommand = "cd /srv && bin/enable '1 hour'"
        p.verifyURL = "https://check.example.com/status"
        p.verifyExpected = "sandbox: yes"
        return p
    }

    func file(_ sandbox: [String: Any], version: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "sandbox": sandbox])
    }

    func read(_ data: Data, current: SandboxPreferences = SandboxPreferences(), includeAPI: Bool = true) throws -> SandboxSettingsFile.Imported {
        try SandboxSettingsFile.read(data, current: current, currentIncludeAPI: includeAPI)
    }

    func message(for data: Data) -> String? {
        do { _ = try read(data); return nil } catch { return error.localizedDescription }
    }

    // MARK: Round trip

    @Test func anExportReadsBackAsTheSameSettingsOnAFreshInstall() throws {
        let original = configured()
        let data = try SandboxSettingsFile.export(original, includeAPI: false)
        let imported = try read(data)
        var expected = original
        expected.enabled = false   // never carried by the file; the importing side keeps its own
        #expect(imported.preferences == expected)
        #expect(imported.includeAPI == false)
    }

    @Test func theFileIsReadableJsonWithAVersionAndNoEnabledFlag() throws {
        let data = try SandboxSettingsFile.export(configured(), includeAPI: true)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"version\" : 1"))
        #expect(!text.contains("enabled"))
        #expect(text.contains("https://check.example.com/status"), "slashes are not escaped")
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((root["sandbox"] as? [String: Any])?["sshHost"] as? String == "me@box.example")
    }

    @Test func importingNeverChangesTheEnabledChoice() throws {
        var current = SandboxPreferences()
        current.enabled = true
        let imported = try read(try SandboxSettingsFile.export(configured(), includeAPI: true), current: current)
        #expect(imported.preferences.enabled == true)
        var off = SandboxPreferences()
        off.enabled = false
        #expect(try read(try SandboxSettingsFile.export(configured(), includeAPI: true), current: off).preferences.enabled == false)
    }

    // MARK: Partial and tolerant

    @Test func fieldsLeftOutKeepTheirCurrentValueAndUnknownFieldsAreIgnored() throws {
        var current = SandboxPreferences()
        current.mainGroup = "mine"
        current.sshHost = "keep@host"
        let imported = try read(try file(["apiGroup": "theirs api", "somethingNew": 7]), current: current)
        #expect(imported.preferences.mainGroup == "mine")
        #expect(imported.preferences.sshHost == "keep@host")
        #expect(imported.preferences.apiGroup == "theirs api")
        #expect(imported.changes.map(\.label) == ["API group"])
    }

    @Test func blankGroupNamesAndProxyFallBackToTheirDefaults() throws {
        let imported = try read(try file(["mainGroup": "  ", "apiGroup": "", "proxyURL": ""]))
        #expect(imported.preferences.mainGroup == SandboxPreferences.defaultMainGroup)
        #expect(imported.preferences.apiGroup == SandboxPreferences.defaultAPIGroup)
        #expect(imported.preferences.proxyURL == SandboxPreferences.defaultProxyURL)
    }

    @Test func blankHostCommandAndServersAreAllowedBecauseTheyTurnStepsOff() throws {
        var current = configured()
        current.enabled = false
        let imported = try read(try file(["bypassHost": "", "sshHost": "", "remoteCommand": "", "mcpServers": "", "verifyURL": ""]), current: current)
        #expect(imported.preferences.sshHost == "")
        #expect(imported.preferences.remoteCommand == "")
        #expect(imported.preferences.mcpServers == "")
        #expect(imported.preferences.verifyURL == "")
        #expect(imported.preferences.bypassHost == "")
    }

    // MARK: Changes

    @Test func changesListOnlyWhatDiffersAndMarkWhatActsOnSwitchOn() throws {
        var current = configured()
        current.sshHost = "old@box"
        let data = try SandboxSettingsFile.export(configured(), includeAPI: true)
        let imported = try read(data, current: current)
        #expect(imported.changes == [SandboxSettingsFile.Change(label: "ssh host", old: "old@box", new: "me@box.example", actsOnSwitchOn: true)])
    }

    @Test func aBlankValueIsShownAsBlankInTheChanges() throws {
        var current = configured()
        current.verifyExpected = "x"
        let imported = try read(try file(["verifyExpected": ""]), current: current)
        #expect(imported.changes == [SandboxSettingsFile.Change(label: "Reply must contain", old: "x", new: "(blank)", actsOnSwitchOn: false)])
    }

    @Test func identicalSettingsHaveNoChanges() throws {
        var current = configured()
        current.enabled = false
        #expect(try read(try SandboxSettingsFile.export(current, includeAPI: true), current: current).changes.isEmpty)
    }

    // MARK: Refused files

    @Test func somethingThatIsNotASettingsFileIsRefused() {
        #expect(message(for: Data("nope".utf8)) == "This is not a bork-hosts settings file.")
        #expect(message(for: Data("[1,2]".utf8)) == "This is not a bork-hosts settings file.")
        #expect(message(for: Data(#"{"hello":"world"}"#.utf8)) == "This is not a bork-hosts settings file.")
    }

    @Test func aNewerOrUnknownVersionIsRefused() throws {
        #expect(message(for: try file([:], version: 2))?.contains("newer version") == true)
        #expect(message(for: try file([:], version: 0))?.contains("unsupported") == true)
    }

    @Test func aHugeFileIsRefusedBeforeItIsParsed() {
        #expect(message(for: Data(repeating: 0x20, count: SandboxSettingsFile.maxBytes + 1))?.contains("too large") == true)
    }

    @Test func aValueTheAppWouldNotAcceptIsRefusedAndNamesTheField() throws {
        let cases: [(String, Any, String)] = [
            ("proxyURL", "socks5h://127.0.0.1:8080", "SOCKS proxy"),
            ("proxyURL", "http://127.0.0.1:8080", "SOCKS proxy"),
            ("sshHost", "-oProxyCommand=evil", "ssh host"),
            ("sshHost", "a b", "ssh host"),
            ("remoteCommand", "line1\nline2", "Command to run"),
            ("bypassHost", "-x", "Proxy bypass host"),
            ("networkService", "-setproxy", "Network service"),
            ("mcpServers", "a=1BAD", "Servers to proxy"),
            ("verifyURL", "file:///etc/hosts", "Check page"),
            ("verifyURL", "--output /tmp/x", "Check page"),
            ("verifyURL", "https://a b.example", "Check page"),
            ("verifyExpected", "a\u{0007}b", "Reply must contain"),
            ("mainGroup", String(repeating: "x", count: 1001), "Main group"),
        ]
        for (field, value, label) in cases {
            let text = message(for: try file([field: value]))
            #expect(text?.hasPrefix(label) == true, "\(field)=\(value): \(text ?? "accepted")")
        }
    }

    @Test func oneBadValueRefusesTheWholeFileSoNothingIsHalfApplied() throws {
        let data = try file(["mainGroup": "fine", "sshHost": "-bad"])
        #expect(throws: SandboxSettingsFile.Invalid.self) { try read(data) }
    }
}

@MainActor
struct SandboxControllerImportTests {
    func controller() async throws -> (SandboxController, UserDefaults) {
        let env = try makeEnv(groups: [])
        let model = AppModel(service: env.service, store: env.store)
        await model.reload()
        let suite = "bork-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let log = EventLog()
        return (SandboxController(model: model, network: FakeNetwork(log: log), browser: FakeBrowser(log: log), defaults: defaults), defaults)
    }

    @Test func exportThenImportOnAnotherInstanceCopiesTheSettingsButNotTheEnabledChoice() async throws {
        let (a, _) = try await controller()
        a.preferences.enabled = true
        a.preferences.mainGroup = "staging"
        a.preferences.sshHost = "me@box.example"
        a.preferences.remoteCommand = "run-it"
        a.includeAPI = false
        let data = try a.exportSettings()

        let (b, defaultsB) = try await controller()
        let imported = try b.previewImport(data)
        #expect(!imported.changes.isEmpty)
        b.applyImport(imported)
        #expect(b.preferences.mainGroup == "staging")
        #expect(b.preferences.sshHost == "me@box.example")
        #expect(b.preferences.remoteCommand == "run-it")
        #expect(b.includeAPI == false)
        #expect(b.preferences.enabled == false, "the second instance never turned the panel on")
        #expect(SandboxPreferences.load(from: defaultsB).sshHost == "me@box.example", "an import is saved like any other change")
    }

    @Test func aPreviewChangesNothingUntilItIsApplied() async throws {
        let (a, _) = try await controller()
        var other = SandboxPreferences()
        other.sshHost = "x@y"
        let data = try SandboxSettingsFile.export(other, includeAPI: true)
        _ = try a.previewImport(data)
        #expect(a.preferences.sshHost == "")
    }
}
