import Foundation
import Testing
@testable import HostsCore

struct SandboxPreferencesTests {
    func freshDefaults() -> UserDefaults {
        let suite = "bork-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func aFreshInstallHasTheSandboxOffWithGenericGroupNamesAndEverythingElseBlank() {
        let p = SandboxPreferences.load(from: freshDefaults())
        #expect(p.enabled == false)
        #expect(p.mainGroup == "sandbox")
        #expect(p.apiGroup == "sandbox api")
        #expect(p.bypassHost == "", "no host, so no bypass step")
        #expect(p.networkService == "")
        #expect(p.proxyURL == "socks5://127.0.0.1:8080")
        #expect(p.mcpServers == "", "no servers, so no MCP step")
        #expect(p.sshHost == "", "ssh stays off until a host is chosen")
        #expect(p.remoteCommand == "")
        #expect(p.verifyURL == "")
        #expect(p.verifyExpected == "")
    }

    @Test func savedValuesComeBack() {
        let defaults = freshDefaults()
        var p = SandboxPreferences()
        p.enabled = true
        p.mainGroup = "staging"
        p.apiGroup = "staging api"
        p.bypassHost = "api.example.com"
        p.networkService = "Ethernet"
        p.proxyURL = "socks5://127.0.0.1:9999"
        p.mcpServers = "one, two=SOCKS_PROXY"
        p.sshHost = "me@box.example"
        p.remoteCommand = "run-it"
        p.verifyURL = "https://api.example.com/check"
        p.verifyExpected = "ok"
        p.save(to: defaults)
        #expect(SandboxPreferences.load(from: defaults) == p)
    }

    @Test func aBlankStoredValueFallsBackToTheDefault() {
        let defaults = freshDefaults()
        defaults.set("   ", forKey: "sandbox.mainGroup")
        defaults.set("", forKey: "sandbox.bypassHost")
        let p = SandboxPreferences.load(from: defaults)
        #expect(p.mainGroup == SandboxPreferences.defaultMainGroup)
        #expect(p.bypassHost == "")
    }

    @Test func aBlankMcpListOrCheckPageStaysBlankBecauseThatTurnsTheStepOff() {
        let defaults = freshDefaults()
        defaults.set("", forKey: "sandbox.mcpServers")
        defaults.set("  ", forKey: "sandbox.verifyURL")
        let p = SandboxPreferences.load(from: defaults)
        #expect(p.mcpServers == "")
        #expect(p.verifyURL == "")
    }

    @Test func theNetworkServiceComesFromSettingsAndBlankIsAnError() throws {
        var p = SandboxPreferences()
        p.networkService = " Ethernet "
        #expect(try p.resolvedNetworkService() == "Ethernet")
        p.networkService = ""
        #expect(throws: (any Error).self) { try p.resolvedNetworkService() }
    }
}

struct SandboxValidationTests {
    @Test func acceptsOrdinaryNames() throws {
        #expect(try SandboxValidation.networkService("Wi-Fi") == "Wi-Fi")
        #expect(try SandboxValidation.networkService("USB 10/100 LAN") == "USB 10/100 LAN")
        #expect(try SandboxValidation.bypassHost("*.example.com") == "*.example.com")
        #expect(try SandboxValidation.bypassHost("api.example.com") == "api.example.com")
    }

    @Test func refusesBlanksLeadingDashesAndControlCharacters() {
        #expect(throws: SandboxValidation.Invalid.self) { try SandboxValidation.networkService("") }
        #expect(throws: SandboxValidation.Invalid.self) { try SandboxValidation.networkService("   ") }
        #expect(throws: SandboxValidation.Invalid.self) { try SandboxValidation.networkService("-listallnetworkservices") }
        #expect(throws: SandboxValidation.Invalid.self) { try SandboxValidation.networkService("Wi-Fi\nEvil") }
        #expect(throws: SandboxValidation.Invalid.self) { try SandboxValidation.bypassHost("-x") }
        #expect(throws: SandboxValidation.Invalid.self) { try SandboxValidation.bypassHost("a.example.com b.example.com") }
    }
}

struct SandboxNetworkValidationTests {
    @Test func aDashedServiceNeverReachesRoot() async {
        let r = FakeRunner()
        let network = SandboxNetwork(runner: r, resolveService: { "-setproxybypassdomains" }, readBypass: { _ in [] })
        guard case let .failed(message) = await network.apply(.on) else { Issue.record("expected a failure"); return }
        #expect(message.contains("cannot start with a dash"))
        #expect(r.calls.isEmpty)
    }

    @Test func aDashedHostNeverReachesRoot() async {
        let r = FakeRunner()
        let network = SandboxNetwork(runner: r, resolveService: { "Wi-Fi" }, host: { "-x" }, readBypass: { _ in [] })
        guard case .failed = await network.apply(.on) else { Issue.record("expected a failure"); return }
        #expect(r.calls.isEmpty)
    }

    @Test func theHostFromSettingsIsWhatGetsBypassed() async {
        let box = BypassBox([])
        let r = FakeRunner()
        r.onRun = { _, arguments in
            guard let i = arguments.firstIndex(of: "-setproxybypassdomains") else { return }
            box.set(Array(arguments[(i + 2)...]))
        }
        let network = SandboxNetwork(runner: r, resolveService: { "Wi-Fi" }, host: { "api.example.com" }, readBypass: { _ in box.value })
        #expect(await network.apply(.on) == .done)
        #expect(box.value == ["api.example.com"])
    }
}

@MainActor
struct SandboxCustomGroupTests {
    @Test func theSwitchActsOnTheGroupsNamedInSettings() async throws {
        let main = HostGroup(name: "staging", lines: [HostLine(ip: "10.0.0.1", hostname: "a.example.com")])
        let api = HostGroup(name: "staging api", lines: [HostLine(ip: "10.0.0.1", hostname: "api.example.com")])
        let env = try makeEnv(groups: [main, api])
        let model = AppModel(service: env.service, store: env.store)
        await model.reload()
        let log = EventLog()
        let suite = "bork-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let controller = SandboxController(model: model, network: FakeNetwork(log: log), browser: FakeBrowser(log: log), defaults: defaults)
        controller.preferences.mainGroup = "Staging"
        controller.preferences.apiGroup = "staging api"
        #expect(controller.title(of: .mainGroup) == "Staging group")
        await controller.setEnabled(true)
        #expect(controller.status(of: .mainGroup) == .done)
        #expect(controller.status(of: .apiGroup) == .done)
        #expect(controller.isOn)
        // The change is remembered for the next launch.
        #expect(SandboxPreferences.load(from: defaults).mainGroup == "Staging")
    }
}
