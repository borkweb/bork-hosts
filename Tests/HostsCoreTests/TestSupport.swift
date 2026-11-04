import Foundation
@testable import HostsCore

func makeTempDir(_ label: String = "t") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bork-test-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Creates a fake hosts file with the given mode and returns its URL.
func makeHostsFile(in dir: URL, _ content: String, mode: Int = 0o640) throws -> URL {
    let url = dir.appendingPathComponent("hosts")
    try Data(content.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    return url
}

func fileMode(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
}

func fileInode(_ url: URL) throws -> UInt64 {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64) ?? 0
}

func readText(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

struct ScriptResult { var status: Int32; var stderr: String }

/// Runs `ApplyScript.source` directly with no elevation, optionally with xtrace.
func runApplyScript(target: URL, contentFile: URL, expectedCurrent: String, expectedNew: String,
                    flush: Bool = false, xtrace: Bool = false, source: String = ApplyScript.source) throws -> ScriptResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = (xtrace ? ["-x"] : []) + ["-c", source, "sh", target.path, contentFile.path,
                                            expectedCurrent, expectedNew, flush ? "1" : "0"]
    let err = Pipe()
    p.standardError = err
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    let data = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return ScriptResult(status: p.terminationStatus, stderr: String(decoding: data, as: UTF8.self))
}

func leftoverTempNames(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".hosts.bork.") }
}

/// Records writes and replays scripted results. `onWrite` runs before the result is returned.
final class FakeWriter: HostsWriter, @unchecked Sendable {
    struct Call { var content: String; var hash: String }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var results: [Result<Void, HostsWriteError>]
    var onWrite: ((Int, String) async -> Void)?

    init(results: [Result<Void, HostsWriteError>] = [], onWrite: ((Int, String) async -> Void)? = nil) {
        self.results = results
        self.onWrite = onWrite
    }

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    func write(newContent: String, expectedCurrentSHA256: String) async throws {
        lock.lock()
        _calls.append(Call(content: newContent, hash: expectedCurrentSHA256))
        let index = _calls.count - 1
        let result = index < results.count ? results[index] : .success(())
        lock.unlock()
        await onWrite?(index, newContent)
        try result.get()
    }
}

let sampleHosts = "127.0.0.1 localhost\n::1 localhost\n# 10.0.0.1 x.com\n"

func makeService(_ dir: URL, hosts: String? = sampleHosts, writer: HostsWriter, keep: Int = 20) throws -> (HostsService, URL, URL) {
    let hostsURL = dir.appendingPathComponent("hosts")
    if let hosts { try Data(hosts.utf8).write(to: hostsURL) }
    let backups = dir.appendingPathComponent("backups")
    return (HostsService(hostsURL: hostsURL, writer: writer, backups: BackupManager(directory: backups, keep: keep)), hostsURL, backups)
}

func backupNames(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waitingCount = 0
    func wait() async {
        waitingCount += 1
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Blocks each write on a gate, then delegates to a real local writer.
struct GatedWriter: HostsWriter {
    let inner: HostsWriter
    let gate: Gate
    func write(newContent: String, expectedCurrentSHA256: String) async throws {
        await gate.wait()
        try await inner.write(newContent: newContent, expectedCurrentSHA256: expectedCurrentSHA256)
    }
}

struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Writes the new content straight to a local file, with no hash check and no shell. For tests that
/// exercise many operations and only care about the resulting bytes.
struct DirectWriter: HostsWriter {
    let target: URL
    func write(newContent: String, expectedCurrentSHA256: String) async throws {
        try Data(newContent.utf8).write(to: target)
    }
}
