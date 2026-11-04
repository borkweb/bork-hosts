import Foundation
import Testing
@testable import HostsCore

final class FakeRunner: PrivilegedRunning, @unchecked Sendable {
    struct Call: Equatable { var executable: String; var arguments: [String] }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var result: Result<(status: Int32, output: String), Error>
    var onRun: (@Sendable (String, [String]) -> Void)?

    init(_ result: Result<(status: Int32, output: String), Error> = .success((0, ""))) { self.result = result }

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    func runAsRoot(_ executable: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        lock.lock(); _calls.append(Call(executable: executable, arguments: arguments)); lock.unlock()
        onRun?(executable, arguments)
        return try result.get()
    }
}

/// A bypass list the fake runner edits when it sees a `networksetup -setproxybypassdomains` call, like the real tool would.
final class BypassBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String]
    init(_ list: [String]) { self.list = list }
    var value: [String] { lock.lock(); defer { lock.unlock() }; return list }
    func set(_ new: [String]) { lock.lock(); list = new; lock.unlock() }
}

struct ProxyBypassTests {
    @Test func parsesDomainsAndTheEmptyMessage() {
        #expect(ProxyBypass.parse("*.local\n169.254/16\n") == ["*.local", "169.254/16"])
        #expect(ProxyBypass.parse("There aren't any bypass domains set on Wi-Fi.\n") == [])
        #expect(ProxyBypass.parse("\n  a.com  \n\n") == ["a.com"])
    }

    @Test func addingPutsTheHostLastWithoutDuplicates() {
        #expect(ProxyBypass.adding("h", to: ["a", "h", "b"]) == ["a", "b", "h"])
        #expect(ProxyBypass.adding("h", to: []) == ["h"])
    }

    @Test func removingDropsOnlyTheHost() {
        #expect(ProxyBypass.removing("h", from: ["a", "h", "b"]) == ["a", "b"])
        #expect(ProxyBypass.removing("h", from: ["a"]) == ["a"])
    }

    @Test func clearingUsesTheWordEmpty() {
        #expect(ProxyBypass.setArguments(service: "Wi-Fi", domains: []) == ["-setproxybypassdomains", "Wi-Fi", "Empty"])
        #expect(ProxyBypass.setArguments(service: "Wi-Fi", domains: ["a", "b"]) == ["-setproxybypassdomains", "Wi-Fi", "a", "b"])
    }
}

struct SandboxNetworkTests {
    func make(_ runner: FakeRunner, box: BypassBox, service: @escaping @Sendable () throws -> String = { "Wi-Fi" }) -> SandboxNetwork {
        SandboxNetwork(runner: runner, resolveService: service, readBypass: { _ in box.value })
    }

    func runner(editing box: BypassBox) -> FakeRunner {
        let r = FakeRunner()
        r.onRun = { _, arguments in
            // The launcher puts the real command after "-e <program>".
            guard let i = arguments.firstIndex(of: "-setproxybypassdomains") else { return }
            let domains = Array(arguments[(i + 2)...])
            box.set(domains == ["Empty"] ? [] : domains)
        }
        return r
    }

    func commands(_ r: FakeRunner) -> [[String]] { r.calls.map { Array($0.arguments.dropFirst(2)) } }

    @Test func onAddsTheHostThenFlushes() async {
        let box = BypassBox(["*.local"])
        let r = runner(editing: box)
        let outcome = await make(r, box: box).apply(.on)
        #expect(outcome == .done)
        #expect(box.value == ["*.local", "api.example.com"])
        let all = commands(r)
        #expect(all.first == ["/usr/sbin/networksetup", "-setproxybypassdomains", "Wi-Fi", "*.local", "api.example.com"])
        #expect(all.last?.first == "/bin/sh")
        #expect(r.calls.allSatisfy { $0.executable == "/usr/bin/perl" })
    }

    @Test func onWhenAlreadyBypassedStillFlushesButDoesNotRewrite() async {
        let box = BypassBox(["*.local", "api.example.com"])
        let r = runner(editing: box)
        #expect(await make(r, box: box).apply(.on) == .done)
        #expect(commands(r).count == 1)
        #expect(commands(r)[0].first == "/bin/sh")
    }

    @Test func offRemovesTheHost() async {
        let box = BypassBox(["*.local", "api.example.com"])
        let r = runner(editing: box)
        #expect(await make(r, box: box).apply(.off) == .done)
        #expect(box.value == ["*.local"])
    }

    @Test func offClearingTheLastEntryUsesEmpty() async {
        let box = BypassBox(["api.example.com"])
        let r = runner(editing: box)
        #expect(await make(r, box: box).apply(.off) == .done)
        #expect(commands(r)[0] == ["/usr/sbin/networksetup", "-setproxybypassdomains", "Wi-Fi", "Empty"])
        #expect(box.value.isEmpty)
    }

    @Test func aChangeThatDoesNotTakeEffectFails() async {
        let box = BypassBox(["*.local"])
        let outcome = await make(FakeRunner(), box: box).apply(.on)
        guard case let .failed(message) = outcome else { Issue.record("expected a failure"); return }
        #expect(message.contains("did not change"))
    }

    @Test func aFailedNetworksetupFailsWithItsOutput() async {
        let box = BypassBox([])
        let r = FakeRunner(.success((1, "boom\n")))
        #expect(await make(r, box: box).apply(.on) == .failed("boom"))
    }

    @Test func aCancelledDialogFails() async {
        let box = BypassBox([])
        #expect(await make(FakeRunner(.failure(HostsWriteError.cancelled)), box: box).apply(.on) == .failed("Authentication was cancelled."))
    }

    @Test func aBlankBypassHostSkipsTheStepWithoutAskingForRoot() async {
        let runner = FakeRunner()
        let network = SandboxNetwork(runner: runner, resolveService: { "Wi-Fi" }, host: { "  " }, readBypass: { _ in [] })
        let outcome = await network.apply(.on)
        guard case .skipped = outcome else { Issue.record("expected skipped, got \(outcome)"); return }
        #expect(runner.calls.isEmpty)
    }

    @Test func aMissingServiceFailsWithoutAskingForRoot() async {
        struct Boom: LocalizedError { var errorDescription: String? { "no service" } }
        let r = FakeRunner()
        let outcome = await make(r, box: BypassBox([]), service: { throw Boom() }).apply(.on)
        #expect(outcome == .failed("no service"))
        #expect(r.calls.isEmpty)
    }

    /// Runs the real launcher program as the current user: the uid change is a no-op, so this proves the Perl parses,
    /// untaints and execs, and that the child gets its arguments intact (including spaces and quotes).
    @Test func theRootLauncherProgramRunsItsCommand() async throws {
        let launch = RootCommand.launch(["/bin/echo", "a b", "it's"])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch.executable)
        p.arguments = launch.arguments
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(text.hasPrefix("uid before="))
        #expect(text.hasSuffix("a b it's\n"))
    }
}

struct DiaBrowserTests {
    func browser(running: Bool = true, result: (status: Int32, output: String), seen: ScriptBox? = nil) -> DiaBrowser {
        DiaBrowser(isRunning: { running }, runScript: { source in
            seen?.set(source)
            return result
        })
    }

    final class ScriptBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ s: String) { lock.lock(); value = s; lock.unlock() }
        var script: String? { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func notRunningSkipsBothSteps() async {
        let b = browser(running: false, result: (0, "clicked"))
        #expect(await b.clearHostCache() == .skipped("Dia is not running"))
        #expect(await b.flushSocketPools() == .skipped("Dia is not running"))
    }

    @Test func clickedIsDone() async {
        #expect(await browser(result: (0, "clicked\n")).clearHostCache() == .done)
        #expect(await browser(result: (0, "clicked\n")).flushSocketPools() == .done)
    }

    @Test func diaReturnsResultsQuotedAndThatStillCountsAsClicked() async {
        #expect(await browser(result: (0, "\"clicked\"\n")).clearHostCache() == .done)
        guard case .failed = await browser(result: (0, "\"notfound\"\n")).clearHostCache() else { Issue.record("expected a failure"); return }
    }

    /// Opt-in: drives the real Dia, which must be running with --enable-applescript-javascript. It opens and closes
    /// a tab for each step. Run with BORK_LIVE_DIA=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BORK_LIVE_DIA"] == "1"))
    func liveDiaClicksBothButtons() async {
        let dia = DiaBrowser()
        #expect(await dia.clearHostCache() == .done)
        #expect(await dia.flushSocketPools() == .done)
    }

    @Test func aMissingButtonFails() async {
        guard case let .failed(message) = await browser(result: (0, "notfound\n")).clearHostCache() else { Issue.record("expected a failure"); return }
        #expect(message.contains("Clear host cache"))
    }

    @Test func theMissingLaunchFlagSkipsWithAHint() async {
        let stderr = "execution error: Dia got an error: JavaScript execution via AppleScript requires the --enable-applescript-javascript launch flag. (-10006)"
        guard case let .skipped(message) = await browser(result: (1, stderr)).flushSocketPools() else { Issue.record("expected a skip"); return }
        #expect(message.contains("--enable-applescript-javascript"))
    }

    @Test func anyOtherScriptErrorFails() async {
        guard case let .failed(message) = await browser(result: (1, "execution error: nope")).clearHostCache() else { Issue.record("expected a failure"); return }
        #expect(message.contains("nope"))
    }

    @Test func eachStepOpensItsOwnPageAndLooksForItsOwnButton() async {
        let dns = ScriptBox(), sockets = ScriptBox()
        _ = await browser(result: (0, "clicked"), seen: dns).clearHostCache()
        _ = await browser(result: (0, "clicked"), seen: sockets).flushSocketPools()
        #expect(dns.script?.contains("chrome://net-internals/#dns") == true)
        #expect(dns.script?.contains("clear host cache") == true)
        #expect(sockets.script?.contains("dia://net-internals/#sockets") == true)
        #expect(sockets.script?.contains("flush socket pools") == true)
    }

    /// Compile only, never run: a syntax error in the generated AppleScript would otherwise surface only at toggle time.
    @Test func generatedAppleScriptCompiles() throws {
        try #require(FileManager.default.fileExists(atPath: "/Applications/Dia.app"), "Dia is needed to resolve its terminology")
        let dir = try makeTempDir("osa")
        for source in [DiaBrowser.appleScript(url: "chrome://net-internals/#dns", buttonText: "clear host cache"),
                       DiaBrowser.appleScript(url: "dia://net-internals/#sockets", buttonText: "flush socket pools")] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            p.arguments = ["-e", source, "-o", dir.appendingPathComponent("out.scpt").path]
            let err = Pipe()
            p.standardError = err
            try p.run()
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "\(text)")
        }
    }
}

@MainActor
struct SetGroupResultTests {
    @Test func setGroupReportsSuccessAndFailure() async throws {
        let line = HostLine(ip: "10.0.0.1", hostname: "x.com")
        let group = HostGroup(name: "G", lines: [line])
        let ok = try makeEnv(groups: [group])
        let m = AppModel(service: ok.service, store: ok.store)
        await m.reload()
        #expect(await m.setGroup(m.groups[0], enabled: true))

        let bad = try makeEnv(writer: { _, _ in FakeWriter(results: [.failure(.cancelled)]) }, groups: [group])
        let m2 = AppModel(service: bad.service, store: bad.store)
        await m2.reload()
        #expect(await m2.setGroup(m2.groups[0], enabled: true) == false)
    }
}
