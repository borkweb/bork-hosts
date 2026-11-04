import Foundation
import Testing
@testable import HostsCore

struct OsascriptWriterTests {
    @Test func quoteHandlesSingleQuotes() {
        #expect(ShellQuote.quote("a'b") == "'a'\\''b'")
    }

    @Test(arguments: ["plain", "with space", "it's", "$HOME `id` $(id)", "multi\nline", "back\\slash \"dq\"", "", "''", "a;b|c&d>e"])
    func quoteRoundTripsThroughShell(_ s: String) async throws {
        let r = try await runCapturingStdout("/bin/sh", ["-c", "printf %s \(ShellQuote.quote(s))"])
        #expect(r == s)
    }

    @Test func appleScriptEscapesBackslashAndQuote() {
        #expect(AppleScriptString.escape(#"a\b"c"#) == #"a\\b\"c"#)
        #expect(AppleScriptString.escape(#"\""#) == #"\\\""#)
    }

    @Test func buildCommandEmbedsScriptAndFiveArguments() {
        let cmd = OsascriptWriter.buildCommand(newContentFile: "/tmp/n x", expectedCurrentSHA256: "aaa", expectedNewSHA256: "bbb", target: "/etc/h'osts", flushDNS: true)
        #expect(cmd.hasPrefix("/bin/sh -c "))
        #expect(cmd.contains(ShellQuote.quote(ApplyScript.source)))
        #expect(cmd.hasSuffix(" sh '/etc/h'\\''osts' '/tmp/n x' 'aaa' 'bbb' '1'"))
        #expect(cmd.contains("'aaa'") && cmd.contains("'bbb'"))
    }

    @Test func builtCommandRunsLocallyAgainstTempTarget() async throws {
        let dir = try makeTempDir("osa")
        let old = "127.0.0.1 localhost\n"
        let new = "127.0.0.1 localhost\n10.0.0.1 it's.test\n"
        let hosts = try makeHostsFile(in: dir, old)
        let content = dir.appendingPathComponent("it's content")
        try Data(new.utf8).write(to: content)
        let cmd = OsascriptWriter.buildCommand(newContentFile: content.path, expectedCurrentSHA256: sha256Hex(old), expectedNewSHA256: sha256Hex(new), target: hosts.path, flushDNS: false)
        _ = try await WriterSupport.run("/bin/sh", ["-c", cmd])
        #expect(try readText(hosts) == new)
    }

    // MARK: Failure mapping, with fixtures captured from real osascript runs (see gate evidence)

    @Test func mapFailureOnRealOsascriptOutput() async throws {
        func real(_ script: String) async throws -> HostsWriteError {
            let r = try await WriterSupport.run("/usr/bin/osascript", ["-e", script])
            #expect(r.status != 0)
            return OsascriptWriter.mapFailure(status: r.status, stderr: r.stderr)
        }
        #expect(try await real(#"do shell script "exit 3""#) == .stale)
        #expect(try await real("error number -128") == .cancelled)
        for code in [4, 1] {
            guard case .failed = try await real("do shell script \"exit \(code)\"") else { Issue.record("exit \(code) must be .failed"); continue }
        }
    }

    @Test func mapFailureOnlyTrustsTheTrailingStatus() {
        let map = OsascriptWriter.mapFailure
        #expect(map(1, "0:24: execution error: User canceled. (-128)\n") == .cancelled)
        #expect(map(1, "0:24: execution error: The command exited with a non-zero status. (3)\n") == .stale)
        // -128 or 3 mid-text (a path, a message) must not be mistaken for cancel or stale.
        if case .failed = map(1, "0:9: execution error: cannot open /Users/x-128/hosts (1)\n") {} else { Issue.record("mid-text -128") }
        if case .failed = map(1, "0:9: execution error: file (3) is odd (1)\n") {} else { Issue.record("mid-text (3)") }
        if case .failed = map(1, "0:9: execution error: oops (4)\n") {} else { Issue.record("exit 4 is not stale") }
        if case .failed = map(1, "something unknown") {} else { Issue.record("unknown") }
        if case .failed = map(1, "") {} else { Issue.record("empty") }
    }

    @Test func failureMessageNeverContainsScriptOrCommandLine() {
        let leaky = "0:9: execution error: /bin/sh: line 1: \(ApplyScript.source) failed (1)"
        guard case let .failed(message) = OsascriptWriter.mapFailure(status: 1, stderr: leaky) else { Issue.record("expected failed"); return }
        #expect(!message.contains("set -eu") && !message.contains(ApplyScript.source) && !message.contains("/bin/sh -c"))
        #expect(message.count <= 200)
    }

    // MARK: Real osascript, no elevation (criterion 20 check A)

    @Test func productionAppleScriptRunsThroughRealOsascriptWithoutElevation() async throws {
        let dir = try makeTempDir("osa")
        let old = "127.0.0.1 localhost\n"
        let new = "127.0.0.1 localhost\n# caf\u{E9} \"q\" \\ it's\n10.0.0.1 x.test\r\n"
        let hosts = try makeHostsFile(in: dir, old)
        let writer = OsascriptWriter(target: hosts, flushDNS: false, elevated: false, tempDirectory: dir)
        try await writer.write(newContent: new, expectedCurrentSHA256: sha256Hex(old))
        #expect(try readText(hosts) == new)
        #expect(try fileMode(hosts) == 0o640)
        #expect(try contentFiles(in: dir).isEmpty)
    }

    @Test func productionAppleScriptIsTheElevatedOneMinusTheSuffix() {
        let cmd = "echo hi"
        let elevated = OsascriptWriter.appleScript(for: cmd, elevated: true)
        let plain = OsascriptWriter.appleScript(for: cmd, elevated: false)
        #expect(elevated == plain + " with administrator privileges")
    }

    // MARK: Content file and cleanup (criteria 19, 23)

    @Test func contentFileIsUnpredictableMode0600AndCreatedExclusively() throws {
        let dir = try makeTempDir("osa")
        let a = try WriterSupport.createContentFile("x", in: dir)
        let b = try WriterSupport.createContentFile("x", in: dir)
        #expect(a != b)
        #expect(a.lastPathComponent.hasPrefix(WriterSupport.contentFilePrefix))
        let suffix = a.lastPathComponent.dropFirst(WriterSupport.contentFilePrefix.count)
        #expect(UUID(uuidString: String(suffix)) != nil)
        #expect(try fileMode(a) == 0o600)
        // A planted symlink or file at the chosen name cannot be followed.
        let fd = open(a.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        #expect(fd < 0)
    }

    @Test(arguments: [
        ("0:1: execution error: User canceled. (-128)", 1, "cancelled"),
        ("0:1: execution error: x (3)", 1, "stale"),
        ("0:1: execution error: x (1)", 1, "failed"),
    ])
    func contentFileRemovedAfterEveryOutcome(_ stderr: String, _ status: Int, _ kind: String) async throws {
        let dir = try makeTempDir("osa")
        let hosts = try makeHostsFile(in: dir, "127.0.0.1 localhost\n")
        let fake = try makeFakeOsascript(in: dir, stderr: stderr, status: Int32(status))
        let writer = OsascriptWriter(target: hosts, flushDNS: false, elevated: true, tempDirectory: dir, osascriptPath: fake.path)
        await #expect(throws: HostsWriteError.self) { try await writer.write(newContent: "x\n", expectedCurrentSHA256: "h") }
        #expect(try contentFiles(in: dir).isEmpty)
    }

    @Test func successfulFakeRunAlsoRemovesContentFile() async throws {
        let dir = try makeTempDir("osa")
        let hosts = try makeHostsFile(in: dir, "127.0.0.1 localhost\n")
        let fake = try makeFakeOsascript(in: dir, stderr: "", status: 0)
        try await OsascriptWriter(target: hosts, flushDNS: false, elevated: true, tempDirectory: dir, osascriptPath: fake.path)
            .write(newContent: "x\n", expectedCurrentSHA256: "h")
        #expect(try contentFiles(in: dir).isEmpty)
    }

    @Test func missingOsascriptExecutableReportsFailedAndCleansUp() async throws {
        let dir = try makeTempDir("osa")
        let hosts = try makeHostsFile(in: dir, "127.0.0.1 localhost\n")
        let writer = OsascriptWriter(target: hosts, flushDNS: false, elevated: true, tempDirectory: dir, osascriptPath: dir.appendingPathComponent("no-such-osascript").path)
        await #expect(throws: HostsWriteError.self) { try await writer.write(newContent: "x\n", expectedCurrentSHA256: "h") }
        #expect(try contentFiles(in: dir).isEmpty)
        #expect(try readText(hosts) == "127.0.0.1 localhost\n")
    }

    @Test func missingOsascriptReportsFailedKind() async throws {
        let dir = try makeTempDir("osa")
        let hosts = try makeHostsFile(in: dir, "127.0.0.1 localhost\n")
        let writer = OsascriptWriter(target: hosts, flushDNS: false, elevated: true, tempDirectory: dir, osascriptPath: "/nonexistent/osascript")
        do { try await writer.write(newContent: "x\n", expectedCurrentSHA256: "h"); Issue.record("expected failure") }
        catch let HostsWriteError.failed(message) { #expect(!message.isEmpty) }
    }

    @Test func localWriterAlsoRemovesContentFileOnEveryOutcome() async throws {
        let dir = try makeTempDir("osa")
        let hosts = try makeHostsFile(in: dir, "a\n")
        let w = LocalScriptWriter(target: hosts, tempDirectory: dir)
        await #expect(throws: HostsWriteError.stale) { try await w.write(newContent: "b\n", expectedCurrentSHA256: "nope") }
        try await w.write(newContent: "b\n", expectedCurrentSHA256: sha256Hex("a\n"))
        #expect(try contentFiles(in: dir).isEmpty)
    }

    // MARK: Credentials (criterion 9)

    @Test func sourcesNeverHandleCredentials() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        for f in files {
            let text = try readText(f)
            for banned in ["SecItem", "readLine(", "standardInput", "LAContext"] { #expect(!text.contains(banned), "\(f.lastPathComponent) mentions \(banned)") }
            #expect(text.range(of: "password", options: .caseInsensitive) == nil || f.lastPathComponent == "OsascriptWriter.swift", "\(f.lastPathComponent) mentions password")
        }
    }
}

func contentFiles(in dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(WriterSupport.contentFilePrefix) }
}

func runCapturingStdout(_ exe: String, _ args: [String]) async throws -> String {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            } catch { cont.resume(throwing: error) }
        }
    }
}

func makeFakeOsascript(in dir: URL, stderr: String, status: Int32) throws -> URL {
    let url = dir.appendingPathComponent("fake-osascript")
    let script = "#!/bin/sh\nprintf '%s\\n' \(ShellQuote.quote(stderr)) >&2\nexit \(status)\n"
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}
