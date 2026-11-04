import Foundation
import HostsCore

// bork-hosts: the command-line face of the running bork-hosts app, for people and for agents.
// It only sends requests; the app does the work (and shows the macOS authentication dialog when it needs to).

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// The app bundle this tool sits in (`BorkHosts.app/Contents/MacOS/bork-hosts`), if any.
func containingApp() -> String? {
    let path = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    guard let range = path.range(of: ".app/Contents/MacOS/") else { return nil }
    return String(path[..<range.lowerBound]) + ".app"
}

func launchApp() {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = containingApp().map { [$0] } ?? ["-b", "com.borkweb.bork-hosts"]
    open.standardOutput = FileHandle.nullDevice
    open.standardError = FileHandle.nullDevice
    try? open.run()
    open.waitUntilExit()
}

let invocation: AgentInvocation
do {
    invocation = try AgentCommandLine.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("bork-hosts: \(error.localizedDescription)\nRun bork-hosts --help for usage.", code: 2)
}
if invocation.wantsHelp {
    print(AgentCommandLine.usage)
    exit(0)
}
guard let request = invocation.request else { fail("bork-hosts: nothing to do. Run bork-hosts --help.", code: 2) }

if !AgentClient.isReachable() {
    guard invocation.launchApp else { fail("bork-hosts: the app is not running.", code: 3) }
    launchApp()
    let deadline = Date().addingTimeInterval(min(invocation.timeout, 30))
    while !AgentClient.isReachable() {
        if Date() > deadline { fail("bork-hosts: started the app but it did not start accepting requests.", code: 3) }
        Thread.sleep(forTimeInterval: 0.25)
    }
}

do {
    let response = try AgentClient.send(request, timeout: invocation.timeout)
    if invocation.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(response), as: UTF8.self))
    } else {
        let text = AgentCommandLine.render(response, for: request)
        if !text.isEmpty { print(text) }
    }
    exit(response.ok ? 0 : 1)
} catch let error as AgentSocketError {
    fail("bork-hosts: \(error.localizedDescription)", code: error == .timedOut ? 4 : 3)
} catch {
    fail("bork-hosts: \(error.localizedDescription)", code: 3)
}
