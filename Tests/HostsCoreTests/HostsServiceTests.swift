import Foundation
import Testing
@testable import HostsCore

struct HostsServiceTests {
    let x = HostLine(ip: "10.0.0.1", hostname: "x.com")

    @Test func noChangeMeansNoWriteAndNoBackup() async throws {
        let dir = try makeTempDir("svc")
        let w = FakeWriter()
        let (svc, _, backups) = try makeService(dir, writer: w)
        try await svc.apply { $0.setEnabled(x, false) }
        #expect(w.calls.isEmpty)
        #expect(backupNames(backups).isEmpty)
    }

    @Test func writesMutatedTextWithHashOfFreshRead() async throws {
        let dir = try makeTempDir("svc")
        let w = FakeWriter()
        let (svc, hostsURL, _) = try makeService(dir, writer: w)
        let edited = sampleHosts + "# edited elsewhere\n"
        try Data(edited.utf8).write(to: hostsURL)
        try await svc.apply { $0.setEnabled(x, true) }
        #expect(w.calls.count == 1)
        #expect(w.calls[0].hash == sha256Hex(edited))
        #expect(w.calls[0].content == edited + "\n" + blk("10.0.0.1 x.com\n"), "an outside comment is not adopted; a block is created after the fresh text")
    }

    @Test func staleRetriesOnceFromFreshRead() async throws {
        let dir = try makeTempDir("svc")
        var hostsURLCopy: URL!
        let w = FakeWriter(results: [.failure(.stale), .success(())]) { index, _ in
            if index == 0 { try? Data((sampleHosts + "# other editor\n").utf8).write(to: hostsURLCopy) }
        }
        let (svc, hostsURL, backups) = try makeService(dir, writer: w)
        hostsURLCopy = hostsURL
        var reads: [String] = []
        try await svc.apply { doc in reads.append(doc.text); doc.setEnabled(x, true) }
        #expect(reads.count == 2 && reads[0] != reads[1])
        #expect(w.calls.count == 2)
        #expect(w.calls[1].content.contains("# other editor"))
        #expect(backupNames(backups).count == 1, "the first attempt's backup is discarded")
    }

    @Test func secondStaleThrows() async throws {
        let dir = try makeTempDir("svc")
        let w = FakeWriter(results: [.failure(.stale), .failure(.stale), .success(())])
        let (svc, _, backups) = try makeService(dir, writer: w)
        await #expect(throws: HostsWriteError.stale) { try await svc.apply { $0.setEnabled(x, true) } }
        #expect(w.calls.count == 2)
        #expect(backupNames(backups).isEmpty)
    }

    @Test func cancelledDiscardsBackupAndRethrows() async throws {
        let dir = try makeTempDir("svc")
        let w = FakeWriter(results: [.failure(.cancelled)])
        let (svc, _, backups) = try makeService(dir, writer: w)
        await #expect(throws: HostsWriteError.cancelled) { try await svc.apply { $0.setEnabled(x, true) } }
        #expect(backupNames(backups).isEmpty)
    }

    @Test func otherFailureDiscardsBackupAndRethrows() async throws {
        let dir = try makeTempDir("svc")
        let w = FakeWriter(results: [.failure(.failed("boom"))])
        let (svc, _, backups) = try makeService(dir, writer: w)
        await #expect(throws: HostsWriteError.failed("boom")) { try await svc.apply { $0.setEnabled(x, true) } }
        #expect(backupNames(backups).isEmpty)
    }

    @Test(arguments: [
        "# 127.0.0.1 localhost\n", "# this mentions localhost in prose\n", "1.1.1.1 notlocalhost\n", "",
    ])
    func refusesFileWithoutLocalhost(_ content: String) async throws {
        let dir = try makeTempDir("svc")
        let w = FakeWriter()
        let (svc, hostsURL, backups) = try makeService(dir, hosts: content, writer: w)
        await #expect(throws: HostsServiceError.missingLocalhost) { try await svc.apply { $0.setEnabled(x, true) } }
        #expect(w.calls.isEmpty && backupNames(backups).isEmpty)
        #expect(try readText(hostsURL) == content)
    }

    @Test func multiNameLocalhostLinePasses() async throws {
        let dir = try makeTempDir("svc")
        let w = FakeWriter()
        let (svc, _, _) = try makeService(dir, hosts: "127.0.0.1 localhost foo\n", writer: w)
        try await svc.apply { $0.setEnabled(x, true) }
        #expect(w.calls.count == 1)
    }

    @Test func refusesMissingFile() async throws {
        let dir = try makeTempDir("svc")
        let w = FakeWriter()
        let (svc, _, _) = try makeService(dir, hosts: nil, writer: w)
        await #expect(throws: HostsServiceError.unreadable) { try await svc.apply { $0.setEnabled(x, true) } }
        #expect(throws: HostsServiceError.unreadable) { try svc.read() }
        #expect(w.calls.isEmpty)
    }

    @Test(arguments: [[0x31, 0x20, 0xFF, 0x0A], [0x31, 0x20, 0x00, 0x0A], [0xEF, 0xBB, 0xBF, 0x31]] as [[UInt8]])
    func readRejectsInvalidUTF8NulAndBOM(_ bytes: [UInt8]) async throws {
        let dir = try makeTempDir("svc")
        let w = FakeWriter()
        let (svc, hostsURL, backups) = try makeService(dir, hosts: nil, writer: w)
        try Data(bytes).write(to: hostsURL)
        await #expect(throws: HostsServiceError.unreadable) { try await svc.apply { $0.setEnabled(x, true) } }
        #expect(w.calls.isEmpty && backupNames(backups).isEmpty)
        #expect(try Data(contentsOf: hostsURL) == Data(bytes))
    }

    @Test func enableDoubleHashLineEnables() async throws {
        let dir = try makeTempDir("svc")
        let w = FakeWriter()
        let (svc, _, _) = try makeService(dir, hosts: "127.0.0.1 localhost\n" + blk("## 10.0.0.1 x.com\n"), writer: w)
        try await svc.apply(expect: { $0.state(of: x) == .on }) { $0.setEnabled(x, true) }
        #expect(w.calls[0].content == "127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n"))
    }

    @Test func failedPostconditionRefusesWithoutWriting() async throws {
        let dir = try makeTempDir("svc")
        let w = FakeWriter()
        let (svc, _, backups) = try makeService(dir, writer: w)
        await #expect(throws: HostsServiceError.postconditionFailed) {
            try await svc.apply(expect: { _ in false }) { $0.setEnabled(x, true) }
        }
        #expect(w.calls.isEmpty && backupNames(backups).isEmpty)
    }

    @Test func backupFailureRefusesWrite() async throws {
        let dir = try makeTempDir("svc")
        let w = FakeWriter()
        let (svc, hostsURL, backups) = try makeService(dir, writer: w)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: backups.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backups.path) }
        await #expect(throws: HostsServiceError.self) { try await svc.apply { $0.setEnabled(x, true) } }
        #expect(w.calls.isEmpty)
        #expect(try readText(hostsURL) == sampleHosts)
    }

    @Test func pruneFailureAfterSuccessfulWriteStillSucceeds() async throws {
        let dir = try makeTempDir("svc")
        var backupsDir: URL!
        let w = FakeWriter { _, _ in
            // Make the backup directory unreadable so prune() throws after the write succeeds.
            try? FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: backupsDir.path)
        }
        let (svc, _, backups) = try makeService(dir, writer: w)
        backupsDir = backups
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backups.path) }
        try await svc.apply { $0.setEnabled(x, true) }
        #expect(w.calls.count == 1)
    }

    @Test func endToEndWithLocalScriptWriter() async throws {
        let dir = try makeTempDir("svc")
        let hostsURL = dir.appendingPathComponent("hosts")
        let original = "127.0.0.1\tlocalhost\r\n" + blk("# 10.0.0.1 x.com # note\r\n9.9.9.9 keep.me\r\n", nl: "\r\n")
        _ = try makeHostsFile(in: dir, original, mode: 0o644)
        let backups = dir.appendingPathComponent("backups")
        let svc = HostsService(hostsURL: hostsURL, writer: LocalScriptWriter(target: hostsURL), backups: BackupManager(directory: backups))
        try await svc.apply { $0.setEnabled(x, true) }
        #expect(try readText(hostsURL) == "127.0.0.1\tlocalhost\r\n" + blk("10.0.0.1 x.com # note\r\n9.9.9.9 keep.me\r\n", nl: "\r\n"))
        let names = backupNames(backups)
        #expect(names.count == 1)
        #expect(try readText(backups.appendingPathComponent(names[0])) == original)
        #expect(try fileMode(hostsURL) == 0o644)
    }

    @Test func oversizedFileRoundTrips() async throws {
        let dir = try makeTempDir("svc")
        let big = "127.0.0.1 localhost\n" + String(repeating: "# a comment line that is fairly long\n", count: 140_000)
        let (svc, hostsURL, _) = try makeService(dir, hosts: big, writer: LocalScriptWriter(target: dir.appendingPathComponent("hosts")))
        #expect(big.utf8.count > 5_000_000)
        try await svc.apply { $0.setEnabled(x, true) }
        #expect(try readText(hostsURL) == big + "\n" + blk("10.0.0.1 x.com\n"))
    }
}
