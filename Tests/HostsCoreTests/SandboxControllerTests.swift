import Foundation
import Testing
@testable import HostsCore

/// Shared across the fakes so a test can assert the order steps ran in.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

struct FakeNetwork: SandboxNetworking {
    let log: EventLog
    var outcome: StepOutcome = .done
    func apply(_ mode: SandboxMode) async -> StepOutcome {
        log.add("network:\(mode.rawValue)")
        return outcome
    }
}

struct FakeBrowser: BrowserCacheClearing {
    let log: EventLog
    var dns: StepOutcome = .done
    var sockets: StepOutcome = .done
    func clearHostCache() async -> StepOutcome { log.add("dns"); return dns }
    func flushSocketPools() async -> StepOutcome { log.add("sockets"); return sockets }
}

struct FakeExtras: SandboxMCPRouting, SandboxRemoteRunning, SandboxVerifying {
    let log: EventLog
    var mcp: StepOutcome = .done
    var writes: StepOutcome = .done
    var check: StepOutcome = .done
    func apply(_ mode: SandboxMode) async -> StepOutcome { log.add("mcp:\(mode.rawValue)"); return mcp }
    func runRemote() async -> StepOutcome { log.add("writes"); return writes }
    func verify() async -> StepOutcome { log.add("verify"); return check }
}

@MainActor
struct SandboxControllerTests {
    let main = HostGroup(name: "sandbox", lines: [HostLine(ip: "10.0.0.1", hostname: "a.example.com")])
    let api = HostGroup(name: "sandbox api", lines: [HostLine(ip: "10.0.0.1", hostname: "api.example.com")])

    func defaults() -> UserDefaults {
        let suite = "bork-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    struct Rig {
        var model: AppModel
        var controller: SandboxController
        var log: EventLog
        var env: ModelEnv
    }

    func rig(hosts: String = sampleHosts, groups: [HostGroup]? = nil, network: ((EventLog) -> FakeNetwork)? = nil,
             browser: ((EventLog) -> FakeBrowser)? = nil, extras: ((EventLog) -> FakeExtras)? = nil,
             writer: ((URL, URL) -> HostsWriter)? = nil, defaults: UserDefaults? = nil) async throws -> Rig {
        let env = try makeEnv(hosts: hosts, writer: writer, groups: groups ?? [main, api])
        let model = AppModel(service: env.service, store: env.store)
        await model.reload()
        let log = EventLog()
        let extra = extras?(log) ?? FakeExtras(log: log)
        let controller = SandboxController(model: model, network: network?(log) ?? FakeNetwork(log: log),
                                           browser: browser?(log) ?? FakeBrowser(log: log), mcp: extra, remote: extra, verifier: extra,
                                           defaults: defaults ?? self.defaults())
        return Rig(model: model, controller: controller, log: log, env: env)
    }

    // MARK: Logging

    @Test func aRunLogsItsStartEachStepAndItsEnd() async throws {
        let env = try makeEnv(groups: [main, api])
        let model = AppModel(service: env.service, store: env.store)
        await model.reload()
        let lines = EventLog()
        let c = SandboxController(model: model, network: FakeNetwork(log: EventLog(), outcome: .failed("boom")),
                                  browser: FakeBrowser(log: EventLog()), defaults: defaults(), log: { lines.add($0) })
        await c.setEnabled(true)
        #expect(lines.events == ["run start mode=on includeAPI=true", "mainGroup running", "mainGroup done", "apiGroup running", "apiGroup done",
                                 "network running", "network failed(\"boom\")", "run end"])
    }

    // MARK: Switching on

    @Test func onRunsTheStepsInOrder() async throws {
        let r = try await rig()
        await r.controller.setEnabled(true)
        #expect(r.log.events == ["network:on", "dns", "sockets", "mcp:on", "writes", "verify"])
        #expect(r.model.groupState(r.model.groups[0]) == .on)
        #expect(r.model.groupState(r.model.groups[1]) == .on)
        for step in SandboxStep.allCases { #expect(r.controller.status(of: step) == .done, "\(step)") }
        #expect(r.controller.isOn)
        #expect(!r.controller.isRunning)
    }

    @Test func onWithTheBoxUncheckedSkipsTheApiGroupAndTheScript() async throws {
        let r = try await rig()
        r.controller.includeAPI = false
        await r.controller.setEnabled(true)
        #expect(r.log.events == ["dns", "sockets"], "the Dia steps still run; the network and MCP steps do not")
        #expect(r.model.groupState(r.model.groups[0]) == .on)
        #expect(r.model.groupState(r.model.groups[1]) == .off)
        guard case .skipped = r.controller.status(of: .apiGroup) else { Issue.record("api group should be skipped"); return }
        guard case .skipped = r.controller.status(of: .network) else { Issue.record("network should be skipped"); return }
        for step in [SandboxStep.mcp, .remote, .verify] {
            guard case .skipped = r.controller.status(of: step) else { Issue.record("\(step) should be skipped"); return }
        }
        #expect(r.controller.status(of: .mainGroup) == .done)
        #expect(r.controller.isOn, "on means the groups this run was asked for are on")
    }

    // MARK: Switching off

    @Test func offTurnsBothGroupsOffAndRunsTheScriptWhateverTheBoxSays() async throws {
        let on = "127.0.0.1 localhost\n" + blk("10.0.0.1 a.example.com\n10.0.0.1 api.example.com\n")
        let r = try await rig(hosts: on)
        r.controller.includeAPI = false
        #expect(r.model.groupState(r.model.groups[1]) == .on)
        await r.controller.setEnabled(false)
        #expect(r.log.events == ["network:off", "dns", "sockets", "mcp:off"], "off removes the MCP proxy and has nothing to undo over ssh")
        #expect(r.model.groupState(r.model.groups[0]) == .off)
        #expect(r.model.groupState(r.model.groups[1]) == .off)
        #expect(!r.controller.isOn)
        for step in SandboxStep.allCases where step != .remote && step != .verify {
            #expect(r.controller.status(of: step) == .done, "\(step)")
        }
        guard case .skipped = r.controller.status(of: .remote) else { Issue.record("writes should be skipped"); return }
        guard case .skipped = r.controller.status(of: .verify) else { Issue.record("verify should be skipped"); return }
    }

    // MARK: Failures

    @Test func aFailedStepStopsTheRunAndLeavesTheRestPending() async throws {
        let r = try await rig(network: { FakeNetwork(log: $0, outcome: .failed("boom")) })
        await r.controller.setEnabled(true)
        #expect(r.log.events == ["network:on"])
        #expect(r.controller.status(of: .network) == .failed("boom"))
        #expect(r.controller.status(of: .dnsCache) == .pending)
        #expect(r.controller.status(of: .socketPools) == .pending)
        #expect(r.controller.status(of: .mainGroup) == .done, "nothing is rolled back")
    }

    @Test func aSkippedDiaStepDoesNotStopTheRun() async throws {
        let r = try await rig(browser: { FakeBrowser(log: $0, dns: .skipped("Dia is not running"), sockets: .skipped("Dia is not running")) })
        await r.controller.setEnabled(true)
        #expect(r.log.events == ["network:on", "dns", "sockets", "mcp:on", "writes", "verify"])
        #expect(r.controller.status(of: .dnsCache) == .skipped("Dia is not running"))
        #expect(r.controller.status(of: .socketPools) == .skipped("Dia is not running"))
        #expect(r.controller.failureMessage == nil)
    }

    @Test func aMissingGroupFailsTheFirstStepAndRunsNothing() async throws {
        let r = try await rig(groups: [api])
        await r.controller.setEnabled(true)
        guard case let .failed(message) = r.controller.status(of: .mainGroup) else { Issue.record("expected a failure"); return }
        #expect(message.contains("sandbox"))
        #expect(r.log.events.isEmpty)
    }

    @Test func aFailedHostsWriteStopsTheRun() async throws {
        let r = try await rig(writer: { _, _ in FakeWriter(results: [.failure(.cancelled)]) })
        await r.controller.setEnabled(true)
        guard case let .failed(message) = r.controller.status(of: .mainGroup) else { Issue.record("expected a failure"); return }
        #expect(message.contains("cancelled"))
        #expect(r.log.events.isEmpty)
        #expect(!r.controller.isOn)
    }

    // MARK: State and settings

    @Test func switchIsOnOnlyWhenTheRequiredGroupsAreOn() async throws {
        let mainOnly = "127.0.0.1 localhost\n" + blk("10.0.0.1 a.example.com\n")
        let r = try await rig(hosts: mainOnly)
        #expect(!r.controller.isOn, "the box is checked, so the api group must be on too")
        r.controller.includeAPI = false
        #expect(r.controller.isOn)
    }

    @Test func theBoxIsRememberedAndDefaultsToChecked() async throws {
        let d = defaults()
        let first = try await rig(defaults: d)
        #expect(first.controller.includeAPI)
        first.controller.includeAPI = false
        let second = try await rig(defaults: d)
        #expect(!second.controller.includeAPI)
    }

    @Test func aSecondRunIsIgnoredWhileOneIsRunning() async throws {
        let gate = Gate()
        let r = try await rig(writer: { url, dir in GatedWriter(inner: LocalScriptWriter(target: url, tempDirectory: dir), gate: gate) })
        let first = Task { await r.controller.setEnabled(true) }
        while await gate.waitingCount == 0 { await Task.yield() }
        #expect(r.controller.isRunning)
        await r.controller.setEnabled(false)
        #expect(r.log.events.isEmpty, "the ignored call must not have run any step")
        await gate.release()
        await first.value
        #expect(r.log.events == ["network:on", "dns", "sockets", "mcp:on", "writes", "verify"])
    }

    @Test func eachRunStartsFromFreshStatuses() async throws {
        let r = try await rig(network: { FakeNetwork(log: $0, outcome: .failed("boom")) })
        await r.controller.setEnabled(true)
        #expect(r.controller.failureMessage == "boom")
        r.controller.includeAPI = false
        await r.controller.setEnabled(true)
        #expect(r.controller.failureMessage == nil)
    }

    // MARK: MCP, ssh and check steps

    @Test func aFailedSshStepIsReportedAndTheCheckDoesNotRun() async throws {
        let r = try await rig(extras: { FakeExtras(log: $0, writes: .failed("Permission denied")) })
        await r.controller.setEnabled(true)
        #expect(r.log.events == ["network:on", "dns", "sockets", "mcp:on", "writes"])
        #expect(r.controller.status(of: .mcp) == .done, "the MCP step comes first, so a bad ssh does not undo it")
        #expect(r.controller.status(of: .remote) == .failed("Permission denied"))
        #expect(r.controller.status(of: .verify) == .pending)
        #expect(r.controller.failureMessage == "Permission denied")
    }

    @Test func aFailedMcpStepStopsBeforeSsh() async throws {
        let r = try await rig(extras: { FakeExtras(log: $0, mcp: .failed("not JSON")) })
        await r.controller.setEnabled(true)
        #expect(r.log.events == ["network:on", "dns", "sockets", "mcp:on"])
        #expect(r.controller.status(of: .remote) == .pending)
    }

    @Test func switchingOnLeavesAReconnectNoteOnTheMcpRow() async throws {
        let r = try await rig()
        await r.controller.setEnabled(true)
        #expect(r.controller.notes[.mcp]?.contains("/mcp") == true)
        await r.controller.setEnabled(false)
        #expect(r.controller.notes[.mcp] == nil, "the note belongs to the run that set it")
    }

    @Test func withoutTheExtrasTheNewStepsSkipThemselves() async throws {
        let env = try makeEnv(groups: [main, api])
        let model = AppModel(service: env.service, store: env.store)
        await model.reload()
        let log = EventLog()
        let c = SandboxController(model: model, network: FakeNetwork(log: log), browser: FakeBrowser(log: log), defaults: defaults())
        await c.setEnabled(true)
        #expect(c.status(of: .mcp) == .skipped("Not set up"))
        #expect(c.failureMessage == nil)
        #expect(c.isOn)
    }
}
