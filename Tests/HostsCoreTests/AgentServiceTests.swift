import Foundation
import Testing
@testable import HostsCore

@MainActor
struct AgentServiceTests {
    let main = HostGroup(name: "sandbox", lines: [HostLine(ip: "10.0.0.1", hostname: "a.example.com")])
    let api = HostGroup(name: "sandbox api", lines: [HostLine(ip: "10.0.0.1", hostname: "api.example.com")])

    struct Rig {
        var service: AgentService
        var model: AppModel
        var controller: SandboxController
        var log: EventLog
        var env: ModelEnv
    }

    func rig(hosts: String = sampleHosts, groups: [HostGroup]? = nil, network: ((EventLog) -> FakeNetwork)? = nil,
             writer: ((URL, URL) -> HostsWriter)? = nil) async throws -> Rig {
        let env = try makeEnv(hosts: hosts, writer: writer, groups: groups ?? [main, api])
        let model = AppModel(service: env.service, store: env.store)
        await model.reload()
        let log = EventLog()
        let suite = "bork-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let controller = SandboxController(model: model, network: network?(log) ?? FakeNetwork(log: log), browser: FakeBrowser(log: log), defaults: defaults)
        controller.preferences.enabled = true
        return Rig(service: AgentService(model: model, sandbox: controller), model: model, controller: controller, log: log, env: env)
    }

    // MARK: Reading

    @Test func statusReportsTheSwitchAndGroups() async throws {
        let r = try await rig()
        let response = await r.service.handle(AgentRequest(cmd: "status"))
        #expect(response.ok)
        #expect(response.sandbox == AgentSandboxInfo(on: false, running: false, includeAPI: true))
        #expect(response.groups?.map(\.name) == ["sandbox", "sandbox api"])
        #expect(response.groups?.first?.state == "off")
        #expect(response.steps?.count == SandboxStep.allCases.count)
    }

    @Test func groupsListsLinesWithTheirState() async throws {
        let on = "127.0.0.1 localhost\n" + blk("10.0.0.1 a.example.com\n")
        let r = try await rig(hosts: on)
        let response = await r.service.handle(AgentRequest(cmd: "groups"))
        #expect(response.groups?[0].lines == [AgentLineInfo(host: "a.example.com", ip: "10.0.0.1", state: "on")])
        #expect(response.groups?[1].lines.first?.state == "missing")
    }

    @Test func statusSeesAnEditMadeOutsideTheApp() async throws {
        let r = try await rig()
        #expect(await r.service.handle(AgentRequest(cmd: "status")).sandbox?.on == false)
        let both = "127.0.0.1 localhost\n" + blk("10.0.0.1 a.example.com\n10.0.0.1 api.example.com\n")
        try Data(both.utf8).write(to: r.env.hostsURL)
        #expect(await r.service.handle(AgentRequest(cmd: "status")).sandbox?.on == true)
    }

    // MARK: Refusals

    @Test(arguments: ["add", "edit", "delete", "addGroup", "deleteGroup", "rename", ""])
    func commandsThatChangeWhatExistsAreRefused(_ cmd: String) async throws {
        let r = try await rig()
        let response = await r.service.handle(AgentRequest(cmd: cmd, name: "x", host: "evil.example.com"))
        #expect(!response.ok)
        #expect(response.message.contains("cannot add, edit or delete"))
        #expect(r.model.groups.count == 2, "nothing may have changed")
    }

    @Test func theSandboxCommandIsRefusedWhileTheSwitchIsTurnedOffInSettings() async throws {
        let r = try await rig()
        r.controller.preferences.enabled = false
        let response = await r.service.handle(AgentRequest(cmd: "sandbox", enable: true))
        #expect(!response.ok)
        #expect(response.message.contains("turned off"))
        #expect(r.log.events.isEmpty, "no step may have run")
        #expect(r.model.groups.count == 2)
    }

    @Test func theCommandListHasNoWayToAddEditOrDelete() {
        let names = Set(AgentCommand.allCases.map(\.rawValue))
        #expect(names == ["status", "groups", "sandbox", "group", "line"])
    }

    // MARK: Groups and lines

    @Test func groupEnableAndDisableChangeTheHostsFile() async throws {
        let r = try await rig()
        let on = await r.service.handle(AgentRequest(cmd: "group", enable: true, name: "SANDBOX"))
        #expect(on.ok)
        #expect(on.groups?[0].state == "on")
        let off = await r.service.handle(AgentRequest(cmd: "group", enable: false, name: "sandbox"))
        #expect(off.ok)
        #expect(off.groups?[0].state == "off")
    }

    @Test func anUnknownGroupFails() async throws {
        let r = try await rig()
        let response = await r.service.handle(AgentRequest(cmd: "group", enable: true, name: "nope"))
        #expect(!response.ok)
        #expect(response.message.contains("nope"))
    }

    @Test func lineEnableByHostname() async throws {
        let r = try await rig()
        let response = await r.service.handle(AgentRequest(cmd: "line", enable: true, host: "api.example.com"))
        #expect(response.ok)
        #expect(response.groups?[1].lines.first?.state == "on")
        #expect(response.groups?[0].lines.first?.state == "missing", "other lines are untouched")
    }

    @Test func aHostnameInTwoGroupsNeedsAGroup() async throws {
        let dup = HostGroup(name: "other", lines: [HostLine(ip: "10.0.0.2", hostname: "a.example.com")])
        let r = try await rig(groups: [main, dup])
        let ambiguous = await r.service.handle(AgentRequest(cmd: "line", enable: true, host: "a.example.com"))
        #expect(!ambiguous.ok)
        #expect(ambiguous.message.contains("more than one"))
        let chosen = await r.service.handle(AgentRequest(cmd: "line", enable: true, host: "a.example.com", group: "other"))
        #expect(chosen.ok)
    }

    @Test func anUnknownLineFails() async throws {
        let r = try await rig()
        #expect(await r.service.handle(AgentRequest(cmd: "line", enable: true, host: "nope.example.com")).ok == false)
    }

    @Test func missingArgumentsFail() async throws {
        let r = try await rig()
        #expect(await r.service.handle(AgentRequest(cmd: "group", name: "sandbox")).ok == false)
        #expect(await r.service.handle(AgentRequest(cmd: "group", enable: true)).ok == false)
        #expect(await r.service.handle(AgentRequest(cmd: "line", enable: true)).ok == false)
        #expect(await r.service.handle(AgentRequest(cmd: "sandbox")).ok == false)
    }

    @Test func aCancelledDialogIsAFailureWithAMessage() async throws {
        let r = try await rig(writer: { _, _ in FakeWriter(results: [.failure(.cancelled)]) })
        let response = await r.service.handle(AgentRequest(cmd: "group", enable: true, name: "sandbox"))
        #expect(!response.ok)
        #expect(response.message.contains("cancelled"))
    }

    // MARK: Sandbox

    @Test func sandboxOnRunsEverythingAndReportsSteps() async throws {
        let r = try await rig()
        let response = await r.service.handle(AgentRequest(cmd: "sandbox", enable: true))
        #expect(response.ok)
        #expect(response.sandbox?.on == true)
        let steps = try #require(response.steps)
        #expect(steps.prefix(5).allSatisfy { $0.status == "done" })
        #expect(steps.suffix(3).allSatisfy { $0.status == "skipped" }, "the MCP, ssh and check steps skip themselves when nothing is set up")
        #expect(r.log.events == ["network:on", "dns", "sockets"])
    }

    @Test func includeApiFalseSkipsItForThisRunOnlyAndDoesNotChangeTheRememberedCheckbox() async throws {
        let r = try await rig()
        #expect(r.controller.includeAPI)
        let response = await r.service.handle(AgentRequest(cmd: "sandbox", enable: true, includeAPI: false))
        #expect(response.ok)
        #expect(response.steps?.first { $0.name == "sandbox api group" }?.status == "skipped")
        #expect(r.controller.includeAPI, "the remembered checkbox is unchanged")
        #expect(r.log.events == ["dns", "sockets"])
    }

    @Test func aFailedStepMakesTheResponseNotOk() async throws {
        let r = try await rig(network: { FakeNetwork(log: $0, outcome: .failed("boom")) })
        let response = await r.service.handle(AgentRequest(cmd: "sandbox", enable: true))
        #expect(!response.ok)
        #expect(response.message == "boom")
        #expect(response.steps?.first { $0.status == "failed" }?.detail == "boom")
    }

    @Test func aSecondSandboxRunIsRefusedWhileOneRuns() async throws {
        let gate = Gate()
        let r = try await rig(writer: { url, dir in GatedWriter(inner: LocalScriptWriter(target: url, tempDirectory: dir), gate: gate) })
        let first = Task { await r.service.handle(AgentRequest(cmd: "sandbox", enable: true)) }
        while await gate.waitingCount == 0 { await Task.yield() }
        let second = await r.service.handle(AgentRequest(cmd: "sandbox", enable: false))
        #expect(!second.ok)
        #expect(second.message.contains("already in progress"))
        await gate.release()
        #expect(await first.value.ok)
    }
}
