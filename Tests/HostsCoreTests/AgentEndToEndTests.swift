import Foundation
import Testing
@testable import HostsCore

/// The same path the command-line tool takes: client, socket, service, model, hosts file.
@MainActor
struct AgentEndToEndTests {
    @Test func aGroupToggleSentOverTheSocketChangesTheHostsFile() async throws {
        let group = HostGroup(name: "sandbox", lines: [HostLine(ip: "10.0.0.1", hostname: "a.example.com")])
        let api = HostGroup(name: "sandbox api", lines: [HostLine(ip: "10.0.0.1", hostname: "api.example.com")])
        let env = try makeEnv(groups: [group, api])
        let model = AppModel(service: env.service, store: env.store)
        await model.reload()
        let log = EventLog()
        let suite = "bork-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let controller = SandboxController(model: model, network: FakeNetwork(log: log), browser: FakeBrowser(log: log), defaults: defaults)
        controller.preferences.enabled = true
        let agent = AgentService(model: model, sandbox: controller)

        let path = try shortSocketPath()
        let server = AgentSocketServer(path: path) { request in await agent.handle(request) }
        try server.start()
        defer { server.stop() }

        let response = try await Task.detached {
            try AgentClient.send(AgentRequest(cmd: "group", enable: true, name: "sandbox"), path: path, timeout: 10)
        }.value
        #expect(response.ok)
        #expect(try readText(env.hostsURL).contains("10.0.0.1 a.example.com"))

        let sandbox = try await Task.detached {
            try AgentClient.send(AgentRequest(cmd: "sandbox", enable: false), path: path, timeout: 10)
        }.value
        #expect(sandbox.ok)
        #expect(sandbox.sandbox?.on == false)
        #expect(log.events == ["network:off", "dns", "sockets"])
    }

    @Test func anAddRequestSentOverTheSocketIsRefusedAndChangesNothing() async throws {
        let group = HostGroup(name: "g", lines: [HostLine(ip: "10.0.0.1", hostname: "a.example.com")])
        let env = try makeEnv(groups: [group])
        let model = AppModel(service: env.service, store: env.store)
        await model.reload()
        let log = EventLog()
        let suite = "bork-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let controller = SandboxController(model: model, network: FakeNetwork(log: log), browser: FakeBrowser(log: log), defaults: defaults)
        controller.preferences.enabled = true
        let agent = AgentService(model: model, sandbox: controller)
        let path = try shortSocketPath()
        let server = AgentSocketServer(path: path) { request in await agent.handle(request) }
        try server.start()
        defer { server.stop() }

        let before = try readText(env.hostsURL)
        let response = try await Task.detached {
            try AgentClient.send(AgentRequest(cmd: "addLine", name: "g", host: "evil.example.com"), path: path, timeout: 10)
        }.value
        #expect(!response.ok)
        #expect(try readText(env.hostsURL) == before)
        #expect(model.groups[0].lines.count == 1)
    }
}
