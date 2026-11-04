import Foundation
import Testing
@testable import HostsCore

struct AgentCommandLineTests {
    func parse(_ args: String...) throws -> AgentInvocation { try AgentCommandLine.parse(args) }

    @Test func sandboxOnAndOff() throws {
        #expect(try parse("sandbox", "on").request == AgentRequest(cmd: "sandbox", enable: true))
        #expect(try parse("sandbox", "off").request == AgentRequest(cmd: "sandbox", enable: false))
        #expect(try parse("sandbox", "ON").request == AgentRequest(cmd: "sandbox", enable: true))
    }

    @Test func noApiOnlyForSandbox() throws {
        #expect(try parse("sandbox", "on", "--no-api").request == AgentRequest(cmd: "sandbox", enable: true, includeAPI: false))
        #expect(try parse("--no-api", "sandbox", "on").request?.includeAPI == false)
        #expect(throws: AgentUsageError.self) { try parse("group", "on", "x", "--no-api") }
    }

    @Test func sandboxStatusIsStatus() throws {
        #expect(try parse("sandbox", "status").request == AgentRequest(cmd: "status"))
        #expect(try parse("status").request == AgentRequest(cmd: "status"))
        #expect(try parse("groups").request == AgentRequest(cmd: "groups"))
    }

    @Test func groupNamesCanHaveSpacesWithOrWithoutQuotes() throws {
        #expect(try parse("group", "on", "sandbox api").request == AgentRequest(cmd: "group", enable: true, name: "sandbox api"))
        #expect(try parse("group", "off", "my", "sandbox").request == AgentRequest(cmd: "group", enable: false, name: "my sandbox"))
        #expect(try parse("group", "enable", "x").request?.enable == true)
        #expect(try parse("group", "disable", "x").request?.enable == false)
    }

    @Test func lineWithAnOptionalGroup() throws {
        #expect(try parse("line", "on", "a.example.com").request == AgentRequest(cmd: "line", enable: true, host: "a.example.com"))
        #expect(try parse("line", "off", "a.example.com", "--group", "other").request
                == AgentRequest(cmd: "line", enable: false, host: "a.example.com", group: "other"))
        #expect(throws: AgentUsageError.self) { try parse("group", "on", "x", "--group", "y") }
    }

    @Test func options() throws {
        let i = try parse("status", "--json", "--timeout", "30", "--no-launch")
        #expect(i.json && !i.launchApp && i.timeout == 30)
        #expect(throws: AgentUsageError.self) { try parse("status", "--timeout") }
        #expect(throws: AgentUsageError.self) { try parse("status", "--timeout", "abc") }
        #expect(throws: AgentUsageError.self) { try parse("status", "--timeout", "0") }
    }

    @Test func helpWhenAskedOrWhenEmpty() throws {
        #expect(try parse().wantsHelp)
        #expect(try parse("--help").wantsHelp)
        #expect(try parse("sandbox", "-h").wantsHelp)
    }

    @Test(arguments: [["frobnicate"], ["sandbox"], ["sandbox", "maybe"], ["group", "on"], ["group"], ["line", "on"], ["status", "extra"], ["--bogus"]])
    func badUsageIsRefused(_ args: [String]) {
        #expect(throws: AgentUsageError.self) { try AgentCommandLine.parse(args) }
    }

    @Test(arguments: ["add", "edit", "delete", "rename", "remove", "new"])
    func thereIsNoWayToAddEditOrDeleteFromTheCommandLine(_ word: String) {
        #expect(throws: AgentUsageError.self) { try AgentCommandLine.parse([word, "x"]) }
        #expect(throws: AgentUsageError.self) { try AgentCommandLine.parse(["group", word, "x"]) }
    }

    @Test func usageMentionsWhatIsNotAvailable() {
        #expect(AgentCommandLine.usage.contains("not available here"))
    }

    // MARK: Rendering

    @Test func rendersAnOnSandboxWithItsSteps() {
        let response = AgentResponse(ok: true, message: "Sandbox turned on.", sandbox: AgentSandboxInfo(on: true, running: false, includeAPI: true),
                                     groups: [], steps: [AgentStepInfo(name: "sandbox group", status: "done", detail: nil),
                                                         AgentStepInfo(name: "Dia: host cache", status: "skipped", detail: "Dia is not running")])
        let text = AgentCommandLine.render(response, for: AgentRequest(cmd: "sandbox", enable: true))
        #expect(text == "Sandbox: on\n  [ok]      sandbox group\n  [skipped] Dia: host cache (Dia is not running)")
    }

    @Test func rendersAFailureWithItsReason() {
        let response = AgentResponse(ok: false, message: "boom", sandbox: AgentSandboxInfo(on: true, running: false, includeAPI: true),
                                     steps: [AgentStepInfo(name: "Proxy bypass & DNS", status: "failed", detail: "boom")])
        let text = AgentCommandLine.render(response, for: AgentRequest(cmd: "sandbox", enable: true))
        #expect(text.contains("[FAILED]  Proxy bypass & DNS: boom"))
        #expect(text.hasSuffix("Error: boom"))
    }

    @Test func rendersGroupsAndLines() {
        let response = AgentResponse(ok: true, message: "", groups: [AgentGroupInfo(name: "G", state: "mixed", lines: [
            AgentLineInfo(host: "a.com", ip: "1.2.3.4", state: "on"), AgentLineInfo(host: "b.com", ip: "1.2.3.4", state: "missing")])])
        #expect(AgentCommandLine.render(response, for: AgentRequest(cmd: "groups")) == "G: mixed\n  a.com  1.2.3.4  on\n  b.com  1.2.3.4  missing")
    }

    @Test func rendersAGroupToggleWithTheMessageThenTheGroups() {
        let response = AgentResponse(ok: true, message: "Group \u{201C}G\u{201D} turned on.", groups: [AgentGroupInfo(name: "G", state: "on", lines: [])])
        #expect(AgentCommandLine.render(response, for: AgentRequest(cmd: "group", enable: true, name: "G")) == "Group \u{201C}G\u{201D} turned on.\nG: on")
    }
}
