import Foundation
import Testing
@testable import HostsCore

/// None of these tests asks macOS for authorization or touches the real hosts file.
struct AuthorizationWriterTests {
    private func run(_ invocation: AuthorizationWriter.Invocation) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: invocation.tool)
        p.arguments = invocation.arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func invocation(dir: URL, target: URL, newText: String, currentText: String, expectedCurrent: String? = nil, expectedNew: String? = nil) throws -> AuthorizationWriter.Invocation {
        let file = try WriterSupport.createContentFile(newText, in: dir)
        return AuthorizationWriter.invocation(newContentFile: file.path,
                                              expectedCurrentSHA256: expectedCurrent ?? sha256Hex(currentText),
                                              expectedNewSHA256: expectedNew ?? sha256Hex(newText),
                                              target: target.path, flushDNS: false)
    }

    @Test func invocationRunsTheScriptInlineWithFiveArguments() {
        let i = AuthorizationWriter.invocation(newContentFile: "/tmp/f", expectedCurrentSHA256: "aa", expectedNewSHA256: "bb",
                                               target: "/etc/hosts", flushDNS: true)
        #expect(i.tool == "/bin/sh")
        #expect(i.arguments == ["-p", "-c", AuthorizationWriter.wrapper, "sh", ApplyScript.source, "/etc/hosts", "/tmp/f", "aa", "bb", "1"])
    }

    /// Without `-p`, sh drops root when only the effective user ID is root. Both shells must keep it.
    @Test func bothShellsKeepPrivilegesWithDashP() {
        let i = AuthorizationWriter.invocation(newContentFile: "f", expectedCurrentSHA256: "a", expectedNewSHA256: "b", target: "t", flushDNS: false)
        #expect(i.arguments.prefix(2) == ["-p", "-c"])
        #expect(AuthorizationWriter.wrapper.hasPrefix("/bin/sh -p -c "))
    }

    @Test func wrapperReportsSuccessAndWritesTheFile() throws {
        let dir = try makeTempDir("authw")
        let old = "127.0.0.1 localhost\n"
        let new = "127.0.0.1 localhost\n192.0.2.10 example.test\n"
        let target = try makeHostsFile(in: dir, old)
        let output = try run(try invocation(dir: dir, target: target, newText: new, currentText: old))
        let outcome = try #require(AuthorizationWriter.parseOutcome(output))
        #expect(outcome.status == 0)
        #expect(try readText(target) == new)
    }

    @Test func wrapperReportsStaleAsExit3AndLeavesFileAlone() throws {
        let dir = try makeTempDir("authw")
        let old = "127.0.0.1 localhost\n"
        let target = try makeHostsFile(in: dir, old)
        let output = try run(try invocation(dir: dir, target: target, newText: "x\n", currentText: old, expectedCurrent: sha256Hex("something else\n")))
        #expect(AuthorizationWriter.parseOutcome(output)?.status == ApplyScript.exitStale)
        #expect(try readText(target) == old)
    }

    @Test func wrapperReportsTamperedContentAsExit4() throws {
        let dir = try makeTempDir("authw")
        let old = "127.0.0.1 localhost\n"
        let target = try makeHostsFile(in: dir, old)
        let output = try run(try invocation(dir: dir, target: target, newText: "x\n", currentText: old, expectedNew: sha256Hex("not x\n")))
        #expect(AuthorizationWriter.parseOutcome(output)?.status == ApplyScript.exitContentTampered)
        #expect(try readText(target) == old)
    }

    @Test func parseOutcomeUsesTheLastMarkerLineAndKeepsEarlierOutput() {
        let parsed = AuthorizationWriter.parseOutcome("some message\nbork-exit:2\n")
        #expect(parsed?.status == 2)
        #expect(parsed?.detail == "some message")
        #expect(AuthorizationWriter.parseOutcome("bork-exit:1\nbork-exit:0\n")?.status == 0)
    }

    @Test func parseOutcomeRejectsMissingOrGarbledMarker() {
        #expect(AuthorizationWriter.parseOutcome("") == nil)
        #expect(AuthorizationWriter.parseOutcome("no marker here\n") == nil)
        #expect(AuthorizationWriter.parseOutcome("bork-exit:abc\n") == nil)
    }

    @Test func mapOutcomeCoversSuccessStaleTamperedAndOther() {
        #expect(AuthorizationWriter.mapOutcome(status: 0, detail: "") == nil)
        #expect(AuthorizationWriter.mapOutcome(status: 3, detail: "") == .stale)
        #expect(AuthorizationWriter.mapOutcome(status: 4, detail: "") == .failed("The new content was changed before it could be written."))
        #expect(AuthorizationWriter.mapOutcome(status: 1, detail: "") == .failed("The hosts file could not be written (exit 1)."))
        #expect(AuthorizationWriter.mapOutcome(status: 1, detail: "mv: Permission denied") == .failed("mv: Permission denied"))
    }

    @Test func mapOutcomeNeverShowsTheScriptSource() {
        let leaked = "sh: line 1: " + ApplyScript.source
        #expect(AuthorizationWriter.mapOutcome(status: 1, detail: leaked) == .failed("The hosts file could not be written (exit 1)."))
    }

    @Test func authorizationStatusMapping() {
        #expect(AuthorizationWriter.mapAuthorizationStatus(errAuthorizationCanceled) == .cancelled)
        if case .failed = AuthorizationWriter.mapAuthorizationStatus(errAuthorizationDenied) {} else { Issue.record("denied must map to .failed") }
        if case .failed = AuthorizationWriter.mapAuthorizationStatus(-1) {} else { Issue.record("unknown must map to .failed") }
        #expect(AuthorizationWriter.mapAuthorizationStatus(errAuthorizationDenied) != .cancelled)
    }

    /// If a future macOS drops the legacy call, this fails loudly instead of the app failing at the first write.
    @Test func privilegedExecuteFunctionIsAvailableOnThisMac() {
        #expect(AuthorizationWriter.executeFunction() != nil)
    }
}
