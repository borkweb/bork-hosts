import Foundation
import Testing
@testable import HostsCore

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

struct ApplyScriptTests {
    let old = "127.0.0.1 localhost\n# caf\u{E9} \u{2603}\r\n1.1.1.1 a\n"
    let new = "127.0.0.1 localhost\n# caf\u{E9} \u{2603}\r\n# 1.1.1.1 a\n"

    @Test func writesNewContentAndPreservesMode() async throws {
        let dir = try makeTempDir("script")
        let hosts = try makeHostsFile(in: dir, old, mode: 0o640)
        let inodeBefore = try fileInode(hosts)
        try await LocalScriptWriter(target: hosts).write(newContent: new, expectedCurrentSHA256: sha256Hex(old))
        #expect(try readText(hosts) == new)
        #expect(try fileMode(hosts) == 0o640)
        #expect(try fileInode(hosts) != inodeBefore, "the target must be replaced by rename, not rewritten in place")
        #expect(leftoverTempNames(in: dir).isEmpty)
    }

    @Test func staleHashLeavesFileUntouchedAndThrowsStale() async throws {
        let dir = try makeTempDir("script")
        let hosts = try makeHostsFile(in: dir, old)
        await #expect(throws: HostsWriteError.stale) {
            try await LocalScriptWriter(target: hosts).write(newContent: new, expectedCurrentSHA256: sha256Hex("something else\n"))
        }
        #expect(try readText(hosts) == old)
        #expect(leftoverTempNames(in: dir).isEmpty)
    }

    @Test func tamperedContentFileExits4() throws {
        let dir = try makeTempDir("script")
        let hosts = try makeHostsFile(in: dir, old)
        let content = dir.appendingPathComponent("content")
        try Data(new.utf8).write(to: content)
        let r = try runApplyScript(target: hosts, contentFile: content, expectedCurrent: sha256Hex(old), expectedNew: sha256Hex("not the file\n"))
        #expect(r.status == ApplyScript.exitContentTampered)
        #expect(try readText(hosts) == old)
        #expect(leftoverTempNames(in: dir).isEmpty, "the temp copy exists before this check, so the cleanup trap must remove it")
    }

    @Test func staleExitCodeIs3AndCleansUpTheCopy() throws {
        let dir = try makeTempDir("script")
        let hosts = try makeHostsFile(in: dir, old)
        let content = dir.appendingPathComponent("content")
        try Data(new.utf8).write(to: content)
        let r = try runApplyScript(target: hosts, contentFile: content, expectedCurrent: sha256Hex("x"), expectedNew: sha256Hex(new))
        #expect(r.status == ApplyScript.exitStale)
        #expect(try readText(hosts) == old)
        #expect(leftoverTempNames(in: dir).isEmpty)
    }

    @Test func missingContentFileFailsWithoutTouchingTarget() throws {
        let dir = try makeTempDir("script")
        let hosts = try makeHostsFile(in: dir, old)
        let r = try runApplyScript(target: hosts, contentFile: dir.appendingPathComponent("nope"), expectedCurrent: sha256Hex(old), expectedNew: sha256Hex(new))
        #expect(r.status != 0 && r.status != ApplyScript.exitStale && r.status != ApplyScript.exitContentTampered)
        #expect(try readText(hosts) == old)
        #expect(leftoverTempNames(in: dir).isEmpty)
    }

    @Test func unwritableDirectoryReportsFailedAndLeavesTarget() async throws {
        let dir = try makeTempDir("script")
        let hosts = try makeHostsFile(in: dir, old)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        do {
            try await LocalScriptWriter(target: hosts).write(newContent: new, expectedCurrentSHA256: sha256Hex(old))
            Issue.record("expected a failure")
        } catch let HostsWriteError.failed(message) {
            #expect(!message.isEmpty)
        }
        #expect(try readText(hosts) == old)
    }

    @Test(arguments: [("a\r\nb\r\n", false), ("caf\u{E9} \u{2603}\n", false), ("", false), ("x", true)])
    func scriptAcceptsSwiftComputedHash(_ content: String, _ unused: Bool) async throws {
        let dir = try makeTempDir("script")
        let hosts = try makeHostsFile(in: dir, old)
        try await LocalScriptWriter(target: hosts).write(newContent: content, expectedCurrentSHA256: sha256Hex(old))
        #expect(try readText(hosts) == content)
    }

    @Test func targetOnlyEverHoldsOldOrNewContent() async throws {
        let dir = try makeTempDir("script")
        let big = String(repeating: "# filler line to make the file large enough to expose partial writes\n", count: 4000)
        let oldBig = "127.0.0.1 localhost\n" + big
        let newBig = "127.0.0.1 localhost\n# 9.9.9.9 z\n" + big
        let hosts = try makeHostsFile(in: dir, oldBig)
        let stop = StopFlag()
        let bad = Collector()
        let group = DispatchGroup()
        for _ in 0..<20 {
            DispatchQueue.global().async(group: group) {
                while !stop.isSet {
                    usleep(200)
                    guard let data = try? Data(contentsOf: hosts) else { bad.add("unreadable"); continue }
                    let text = String(decoding: data, as: UTF8.self)
                    if text != oldBig && text != newBig { bad.add("partial: \(data.count) bytes") }
                }
            }
        }
        try await LocalScriptWriter(target: hosts).write(newContent: newBig, expectedCurrentSHA256: sha256Hex(oldBig))
        try await Task.sleep(nanoseconds: 20_000_000)
        stop.set()
        group.wait()
        #expect(bad.all.isEmpty, "\(bad.all.prefix(3))")
        #expect(try readText(hosts) == newBig)
    }

    // MARK: DNS flush flag (criterion 14), observed through xtrace

    @Test func flushFlagZeroNeverRunsFlushCommands() throws {
        let r = try traceRun(flush: false)
        #expect(r.status == 0)
        #expect(!r.stderr.contains("dscacheutil") && !r.stderr.contains("killall"))
    }

    @Test func flushFlagOneUsesAbsolutePathsAndToleratesFailure() throws {
        let r = try traceRun(flush: true)
        #expect(r.status == 0)
        #expect(r.stderr.contains("/usr/bin/dscacheutil -flushcache"))
        #expect(r.stderr.contains("/usr/bin/killall -HUP mDNSResponder"))
    }

    @Test func flushNeverRunsOnStaleOrTamperedPaths() throws {
        let dir = try makeTempDir("script")
        let hosts = try makeHostsFile(in: dir, old)
        let content = dir.appendingPathComponent("content")
        try Data(new.utf8).write(to: content)
        let stale = try runApplyScript(target: hosts, contentFile: content, expectedCurrent: "bad", expectedNew: sha256Hex(new), flush: true, xtrace: true)
        let tampered = try runApplyScript(target: hosts, contentFile: content, expectedCurrent: sha256Hex(old), expectedNew: "bad", flush: true, xtrace: true)
        for r in [stale, tampered] {
            #expect(r.status != 0)
            #expect(!r.stderr.contains("dscacheutil") && !r.stderr.contains("killall"))
        }
    }

    @Test func dataIsSyncedBeforeTheRenameAndNeverOnRefusals() throws {
        let ok = try traceRun(flush: false)
        let lines = ok.stderr.split(separator: "\n").map(String.init)
        let sync = try #require(lines.firstIndex { $0.contains("/bin/sync") }, "no /bin/sync in the trace")
        let mv = try #require(lines.firstIndex { $0.contains("/bin/mv ") })
        #expect(sync < mv, "the new data must be flushed to disk before the rename")

        let dir = try makeTempDir("script")
        let hosts = try makeHostsFile(in: dir, old)
        let content = dir.appendingPathComponent("content")
        try Data(new.utf8).write(to: content)
        let stale = try runApplyScript(target: hosts, contentFile: content, expectedCurrent: "bad", expectedNew: sha256Hex(new), xtrace: true)
        let tampered = try runApplyScript(target: hosts, contentFile: content, expectedCurrent: sha256Hex(old), expectedNew: "bad", xtrace: true)
        for r in [stale, tampered] {
            #expect(r.status != 0)
            #expect(!r.stderr.contains("/bin/sync") && !r.stderr.contains("/bin/mv"))
        }
    }

    func traceRun(flush: Bool) throws -> ScriptResult {
        let dir = try makeTempDir("script")
        let hosts = try makeHostsFile(in: dir, old)
        let content = dir.appendingPathComponent("content")
        try Data(new.utf8).write(to: content)
        let r = try runApplyScript(target: hosts, contentFile: content, expectedCurrent: sha256Hex(old), expectedNew: sha256Hex(new), flush: flush, xtrace: true)
        #expect(try readText(hosts) == new)
        return r
    }

    // MARK: Structural guarantees (criteria 23 and 34)

    @Test func newContentHashIsCheckedOnTheRootOwnedCopyAfterTheCopy() throws {
        let lines = ApplyScript.source.split(separator: "\n").map(String.init)
        let cp = try #require(lines.firstIndex { $0.contains("/bin/cp ") })
        let hash = try #require(lines.firstIndex { $0.contains("shasum") && $0.contains("\"$tmp\"") })
        let mv = try #require(lines.firstIndex { $0.contains("/bin/mv ") })
        #expect(cp < hash && hash < mv)
        #expect(!ApplyScript.source.contains("shasum -a 256 \"$newfile\""), "never hash the user-writable source")
    }

    @Test func tempCopyIsRemovedOnExitAndOnSignals() {
        let s = ApplyScript.source
        #expect(s.contains("trap '/bin/rm -f \"$tmp\"' EXIT"))
        for sig in ["HUP", "INT", "TERM"] { #expect(s.contains("' \(sig)") || s.contains(" \(sig)\n")) }
    }
}
