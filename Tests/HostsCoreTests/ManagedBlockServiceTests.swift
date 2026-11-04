import Foundation
import Testing
@testable import HostsCore

/// The service backstop: every byte before BEGIN and after END survives, or the old file is an exact prefix.
struct ManagedBlockServiceTests {
    let x = HostLine(ip: "10.0.0.1", hostname: "x.com")
    let y = HostLine(ip: "10.0.0.2", hostname: "y.com")
    static let lo = "127.0.0.1 localhost\n::1 localhost\n"
    static let old = lo + blk("10.0.0.1 x.com\n10.0.0.2 y.com\n") + "post1\npost2\n"
    static let oldAtEOF = lo + blk("10.0.0.1 x.com\n")

    struct Row: CustomTestStringConvertible, Sendable {
        var name: String, old: String, new: String
        var error: HostsServiceError = .confinementViolated
        var testDescription: String { name }
    }

    static let refusals: [Row] = [
        Row(name: "a: edit last byte before BEGIN", old: old, new: old.replacingOccurrences(of: "::1 localhost\n", with: "::1 localhosT\n")),
        Row(name: "a2: edit first byte of the file", old: old, new: "X" + old.dropFirst()),
        Row(name: "b: insert a line before BEGIN", old: old, new: old.replacingOccurrences(of: beginMarker, with: "9.9.9.9 evil\n" + beginMarker)),
        Row(name: "c1: append after END", old: old, new: old + "9.9.9.9 evil\n"),
        Row(name: "c2: edit first byte after END", old: old, new: old.replacingOccurrences(of: "post1", with: "Post1")),
        Row(name: "c3: remove final newline after END at EOF", old: oldAtEOF, new: String(oldAtEOF.dropLast())),
        Row(name: "d1: trailing space on BEGIN", old: old, new: old.replacingOccurrences(of: beginMarker + "\n", with: beginMarker + " \n")),
        Row(name: "d2: trailing space on END", old: old, new: old.replacingOccurrences(of: endMarker + "\n", with: endMarker + " \n")),
        Row(name: "d3: CRLF to LF on a marker", old: lo + beginMarker + "\r\n10.0.0.1 x.com\n" + endMarker + "\n",
            new: lo + beginMarker + "\n10.0.0.1 x.com\n" + endMarker + "\n"),
        Row(name: "d4: same-length change on BEGIN (space to tab)", old: lo + beginMarker + " \n10.0.0.1 x.com\n" + endMarker + "\n",
            new: lo + beginMarker + "\t\n10.0.0.1 x.com\n" + endMarker + "\n"),
        Row(name: "d5: same-length change on END (space to tab)", old: lo + beginMarker + "\n10.0.0.1 x.com\n" + endMarker + " \n",
            new: lo + beginMarker + "\n10.0.0.1 x.com\n" + endMarker + "\t\n"),
        Row(name: "e: move END one line up", old: old,
            new: lo + beginMarker + "\n10.0.0.1 x.com\n" + endMarker + "\n10.0.0.2 y.com\n" + "post1\npost2\n"),
        Row(name: "f: delete the whole block", old: old, new: lo + "post1\npost2\n"),
        Row(name: "g: second block after the old END", old: old, new: old + blk("10.0.0.3 z.com\n")),
        Row(name: "h: duplicate BEGIN inside the block", old: old, new: old.replacingOccurrences(of: "10.0.0.1 x.com\n", with: beginMarker + "\n10.0.0.1 x.com\n")),
        Row(name: "i: no block, edit a line elsewhere", old: lo + "# 10.0.0.1 x.com\n", new: lo + "10.0.0.1 x.com\n"),
        Row(name: "j: no block, create a block mid-file", old: lo + "post\n", new: lo + blk("10.0.0.1 x.com\n") + "post\n"),
        Row(name: "k: no block, append a plain line", old: lo, new: lo + "10.0.0.1 x.com\n"),
        Row(name: "l1: glue the block to an unterminated last line", old: "127.0.0.1 localhost\n::1 localhost",
            new: "127.0.0.1 localhost\n::1 localhost" + beginMarker + "\n10.0.0.1 x.com\n" + endMarker + "\n"),
        Row(name: "l2: prefix kept but no markers at all", old: "127.0.0.1 localhost\n::1 localhost",
            new: "127.0.0.1 localhost\n::1 localhost" + beginMarker + " 10.0.0.1 x.com " + endMarker + "\n"),
        Row(name: "m: old text damaged, closure repairs it", old: lo + beginMarker + "\n10.0.0.1 x.com\n",
            new: lo + blk("10.0.0.1 x.com\n"), error: .blockDamaged(.missingEnd)),
        Row(name: "o: canonically equal prefix, different bytes", old: lo + "cafe\u{301}\n" + blk("10.0.0.1 x.com\n"),
            new: lo + "caf\u{E9}\n" + blk("10.0.0.1 x.com\n")),
        Row(name: "p: prefix CRLF changed to LF", old: "127.0.0.1 localhost\r\n::1 localhost\r\n" + blk("10.0.0.1 x.com\r\n", nl: "\r\n"),
            new: "127.0.0.1 localhost\n::1 localhost\r\n" + blk("10.0.0.1 x.com\r\n", nl: "\r\n")),
        Row(name: "q: suffix CRLF changed to LF", old: lo + blk("10.0.0.1 x.com\n") + "post\r\n", new: lo + blk("10.0.0.1 x.com\n") + "post\n"),
        Row(name: "r1: last byte of the post-END text, same length", old: old, new: String(old.dropLast()) + "X"),
        Row(name: "r2: middle byte of the post-END text, same length", old: old, new: old.replacingOccurrences(of: "post2", with: "poXt2")),
        Row(name: "s1: create plus lines between old file and BEGIN", old: lo,
            new: lo + "6.6.6.6 evil\n" + blk("10.0.0.1 x.com\n")),
        Row(name: "s2: create plus text after END", old: lo, new: lo + "\n" + blk("10.0.0.1 x.com\n") + "9.9.9.9 evil\n"),
        Row(name: "s3: create plus extra blank lines before BEGIN", old: lo, new: lo + "\n\n\n" + blk("10.0.0.1 x.com\n")),
        Row(name: "s5: create plus a short junk line within the allowed gap length", old: lo, new: lo + "x\n" + blk("10.0.0.1 x.com\n")),
        Row(name: "s4: create where the old file is empty, junk before BEGIN", old: "", new: "\n" + blk("10.0.0.1 x.com\n")),
    ]

    func run(_ old: String, _ new: String) async throws -> (error: Error?, writer: FakeWriter, backups: URL, hosts: URL) {
        let dir = try makeTempDir("conf")
        let w = FakeWriter()
        let (svc, hostsURL, backups) = try makeService(dir, hosts: old, writer: w)
        do {
            try await svc.apply { $0 = HostsDocument(new) }
            return (nil, w, backups, hostsURL)
        } catch { return (error, w, backups, hostsURL) }
    }

    @Test(arguments: refusals)
    func confinementRefusals(_ row: Row) async throws {
        let r = try await run(row.old, row.new)
        #expect((r.error as? HostsServiceError) == row.error, "\(String(describing: r.error))")
        #expect(r.writer.calls.isEmpty)
        #expect(backupNames(r.backups).isEmpty, "a refusal leaves no backup")
        #expect(try readText(r.hosts) == row.old)
    }

    @Test func interiorOnlyChangeIsWritten() async throws {
        let new = Self.old.replacingOccurrences(of: "10.0.0.2 y.com\n", with: "# 10.0.0.2 y.com\n")
        let r = try await run(Self.old, new)
        #expect(r.error == nil)
        #expect(r.writer.calls.map(\.content) == [new])
        #expect(backupNames(r.backups).count == 1)
    }

    @Test(arguments: [Self.lo, Self.lo + "tail", "127.0.0.1 localhost\r\n", Self.lo + "\n"])
    func creatingABlockWithTheOldFileAsPrefixIsWritten(_ old: String) async throws {
        var d = HostsDocument(old)
        d.setEnabled(x, true)
        let r = try await run(old, d.text)
        #expect(r.error == nil)
        #expect(r.writer.calls.count == 1 && r.writer.calls[0].content == d.text)
        #expect(r.writer.calls[0].content.hasPrefix(old))
    }

    /// Every create row of the document table must still pass the backstop, shapes with and without a final newline included.
    @Test(arguments: ManagedBlockDocumentTests.createRows)
    func everyCreateTableRowPassesTheBackstop(_ input: String, _ expected: String) throws {
        try HostsService.confine(old: input, new: expected)
    }

    @Test func noOpWritesNothingAndKeepsNoBackup() async throws {
        let r = try await run(Self.old, Self.old)
        #expect(r.error == nil && r.writer.calls.isEmpty && backupNames(r.backups).isEmpty)
    }

    @Test func documentMutatorsAreRefusedWhenTheyWouldLeaveTheBlock() async throws {
        // The closure bypasses the mutators and edits segments directly.
        let dir = try makeTempDir("conf")
        let w = FakeWriter()
        let (svc, hostsURL, backups) = try makeService(dir, hosts: Self.old, writer: w)
        await #expect(throws: HostsServiceError.confinementViolated) {
            try await svc.apply { doc in doc.segments[0].setBody(Array("0.0.0.0 localhost".unicodeScalars)) }
        }
        #expect(w.calls.isEmpty && backupNames(backups).isEmpty)
        #expect(try readText(hostsURL) == Self.old)
    }

    // MARK: Damage

    @Test(arguments: ManagedBlockMarkerTests.damageRows)
    func damagedFileRefusesEvenANoOp(_ text: String, _ reason: BlockDamage) async throws {
        let dir = try makeTempDir("conf")
        let w = FakeWriter()
        let (svc, hostsURL, backups) = try makeService(dir, hosts: Self.lo + text, writer: w)
        await #expect(throws: HostsServiceError.blockDamaged(reason)) { try await svc.apply { $0.setEnabled(x, false) } }
        await #expect(throws: HostsServiceError.blockDamaged(reason)) { try await svc.apply { $0.setEnabled(x, true) } }
        #expect(w.calls.isEmpty && backupNames(backups).isEmpty)
        #expect(try readText(hostsURL) == Self.lo + text)
        #expect(try svc.read().blockDamage == reason, "reading still works")
    }

    // MARK: Localhost check with a block

    @Test func blockIsCreatedWhenLocalhostIsOnlyOutsideTheBlock() async throws {
        let dir = try makeTempDir("conf")
        let w = FakeWriter()
        let (svc, _, _) = try makeService(dir, hosts: HostsDocumentTests.stockMacHosts, writer: w)
        try await svc.apply { $0.setEnabled(x, true) }
        #expect(w.calls[0].content == HostsDocumentTests.stockMacHosts + "\n" + blk("10.0.0.1 x.com\n"))
    }

    @Test func blocklessFileWithoutLocalhostCreatesNoBlock() async throws {
        let dir = try makeTempDir("conf")
        let w = FakeWriter()
        let (svc, hostsURL, backups) = try makeService(dir, hosts: "# 127.0.0.1 localhost\n", writer: w)
        await #expect(throws: HostsServiceError.missingLocalhost) { try await svc.apply { $0.setEnabled(x, true) } }
        #expect(w.calls.isEmpty && backupNames(backups).isEmpty)
        #expect(try readText(hostsURL) == "# 127.0.0.1 localhost\n")
    }

    @Test func disablingTheOnlyLocalhostIsStillRefused() async throws {
        let dir = try makeTempDir("conf")
        let w = FakeWriter()
        let text = "127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n")
        let (svc, _, backups) = try makeService(dir, hosts: text, writer: w)
        await #expect(throws: HostsServiceError.self) {
            try await svc.apply { $0 = HostsDocument("# 127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n")) }
        }
        #expect(w.calls.isEmpty && backupNames(backups).isEmpty)
    }

    @Test func damageIsReportedBeforeMissingLocalhost() async throws {
        let dir = try makeTempDir("conf")
        let w = FakeWriter()
        let (svc, _, _) = try makeService(dir, hosts: beginMarker + "\n", writer: w)
        await #expect(throws: HostsServiceError.blockDamaged(.missingEnd)) { try await svc.apply { $0.setEnabled(x, true) } }
        #expect(w.calls.isEmpty)
    }

    // MARK: Stale retry re-reads and re-checks

    func staleRun(old: String, other: String, mutate: @escaping (inout HostsDocument) -> Void) async throws
        -> (error: Error?, writer: FakeWriter, backups: URL, hosts: URL, reads: [String]) {
        let dir = try makeTempDir("stale")
        var hostsURL: URL!
        let w = FakeWriter(results: [.failure(.stale), .success(())]) { index, _ in
            if index == 0 { try? Data(other.utf8).write(to: hostsURL) }
        }
        let (svc, url, backups) = try makeService(dir, hosts: old, writer: w)
        hostsURL = url
        var reads: [String] = []
        do {
            try await svc.apply { doc in reads.append(doc.text); mutate(&doc) }
            return (nil, w, backups, url, reads)
        } catch { return (error, w, backups, url, reads) }
    }

    @Test func staleRetryUsesTheSecondReadAsOld() async throws {
        let first = Self.lo + blk("10.0.0.1 x.com\n")
        let second = first + "appended by another tool\n"
        let r = try await staleRun(old: first, other: second) { $0.setEnabled(y, true) }
        #expect(r.error == nil && r.writer.calls.count == 2)
        #expect(r.writer.calls[1].content == Self.lo + blk("10.0.0.1 x.com\n10.0.0.2 y.com\n") + "appended by another tool\n")
        #expect(r.writer.calls[1].hash == sha256Hex(second), "hash of the second read, not the first")
        #expect(r.writer.calls[0].hash == sha256Hex(first))
        #expect(r.reads == [first, second])
    }

    @Test func staleRetryInsertsIntoABlockAnotherProcessCreated() async throws {
        let other = Self.lo + blk("9.9.9.9 other.com\n")
        let r = try await staleRun(old: Self.lo, other: other) { $0.setEnabled(x, true) }
        #expect(r.error == nil)
        #expect(r.writer.calls[0].content == Self.lo + "\n" + blk("10.0.0.1 x.com\n"))
        #expect(r.writer.calls[1].content == Self.lo + blk("9.9.9.9 other.com\n10.0.0.1 x.com\n"))
        #expect(r.writer.calls[1].content.components(separatedBy: beginMarker).count == 2, "exactly one BEGIN")
    }

    @Test func staleRetryRefusesWhenAnotherProcessRemovedEnd() async throws {
        let first = Self.lo + blk("9.9.9.9 other.com\n")
        let r = try await staleRun(old: first, other: Self.lo + beginMarker + "\n9.9.9.9 other.com\n") { $0.setEnabled(x, true) }
        #expect((r.error as? HostsServiceError) == .blockDamaged(.missingEnd))
        #expect(r.writer.calls.count == 1)
        #expect(backupNames(r.backups).isEmpty)
    }

    @Test func staleRetryRecreatesABlockAnotherProcessDeleted() async throws {
        let first = Self.lo + blk("10.0.0.1 x.com\n")
        let r = try await staleRun(old: first, other: Self.lo) { $0.setEnabled(y, true) }
        #expect(r.error == nil)
        #expect(r.writer.calls[1].content == Self.lo + "\n" + blk("10.0.0.2 y.com\n"))
    }

    // MARK: Real shapes through the shell path

    /// The text of a hosts file the real-shape rows can use, or nil when it is unreadable, empty, not plain
    /// UTF-8, holds a NUL byte, or has damaged markers. Matt's real file may change; this never fails a run.
    static func usableHostsText(_ data: Data?) -> String? {
        guard let data, !data.isEmpty, !data.contains(0), let text = String(data: data, encoding: .utf8),
              Data(text.utf8) == data, HostsDocument(text).blockDamage == nil else { return nil }
        return text
    }

    /// Read-only. `BORK_TEST_HOSTS_COPY_SOURCE` points the read at another file (used to check the skip).
    static let realHosts: String? = usableHostsText(
        try? Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["BORK_TEST_HOSTS_COPY_SOURCE"] ?? "/etc/hosts")))

    @Test func unusableHostsFilesAreSkippedNotFailed() {
        #expect(Self.usableHostsText(nil) == nil)
        #expect(Self.usableHostsText(Data()) == nil)
        #expect(Self.usableHostsText(Data([0x31, 0x20, 0xFF, 0x0A])) == nil)
        #expect(Self.usableHostsText(Data([0x31, 0x00, 0x0A])) == nil)
        #expect(Self.usableHostsText(Data((Self.lo + beginMarker + "\n").utf8)) == nil)
        #expect(Self.usableHostsText(Data(Self.old.utf8)) == Self.old)
    }

    @Test func stockMacFileKeepsEveryOriginalByteThroughTheShellScript() async throws {
        try await confinedThroughShellScript("stock", HostsDocumentTests.stockMacHosts)
    }

    @Test(.enabled(if: ManagedBlockServiceTests.realHosts != nil, "this machine's hosts file is unreadable, empty, not UTF-8, or has damaged markers"))
    func thisMachinesHostsCopyKeepsEveryOriginalByteThroughTheShellScript() async throws {
        try await confinedThroughShellScript("this machine's /etc/hosts (read-only copy)", try #require(Self.realHosts))
    }

    func confinedThroughShellScript(_ name: String, _ original: String) async throws {
        let dir = try makeTempDir("real")
        let hostsURL = try makeHostsFile(in: dir, original, mode: 0o644)
        let svc = HostsService(hostsURL: hostsURL, writer: LocalScriptWriter(target: hostsURL, tempDirectory: dir),
                               backups: BackupManager(directory: dir.appendingPathComponent("backups")))
        // Whatever the shape (no block yet, or a block already there), bytes outside the block never change.
        func confined(_ before: String, _ after: String, _ step: String) {
            let o = Array(before.utf8), n = Array(after.utf8)
            if let old = Self.blockOffsets(before), let new = Self.blockOffsets(after) {
                #expect(Array(n[..<new.beginLineEnd]) == Array(o[..<old.beginLineEnd]), "\(name) \(step): bytes before and including BEGIN")
                #expect(Array(n[new.endLineStart...]) == Array(o[old.endLineStart...]), "\(name) \(step): bytes from END on")
            } else {
                #expect(Self.blockOffsets(before) == nil && Self.blockOffsets(after) != nil, "\(name) \(step): block created")
                #expect(after.hasPrefix(before), "\(name) \(step): old file is an exact prefix")
            }
        }
        try await svc.apply { $0.setEnabled(x, true) }
        let one = try readText(hostsURL)
        confined(original, one, "enable x")
        #expect(HostsDocument(one).state(of: x) == .on)
        try await svc.apply { $0.setEnabled(y, true) }
        let two = try readText(hostsURL)
        confined(one, two, "enable y")
        try await svc.apply { $0.remove(x) }
        let three = try readText(hostsURL)
        confined(two, three, "remove x")
        #expect(HostsDocument(three).state(of: y) == .on && HostsDocument(three).state(of: x) == .missing)
        if Self.blockOffsets(original) == nil { #expect(three.hasPrefix(original) && three.hasSuffix(blk("10.0.0.2 y.com\n"))) }
        #expect(leftoverTempNames(in: dir).isEmpty)
    }

    // MARK: Seeded end-to-end invariant

    /// Byte offsets (UTF-8) just past the BEGIN line and at the start of the END line, or nil unless
    /// the text has exactly one of each in order. Written independently of `HostsDocument`.
    static func blockOffsets(_ text: String) -> (beginLineEnd: Int, endLineStart: Int)? {
        let bytes = Array(text.utf8)
        var begins: [Int] = [], ends: [(start: Int, after: Int)] = []
        var start = 0
        while start < bytes.count {
            var stop = start
            while stop < bytes.count, bytes[stop] != 10 { stop += 1 }
            let after = min(stop + 1, bytes.count)
            var trimmed = stop
            while trimmed > start, [0x20, 0x09, 0x0D, 0x0B, 0x0C].contains(bytes[trimmed - 1]) { trimmed -= 1 }
            let line = Array(bytes[start..<trimmed])
            if line == Array(beginMarker.utf8) { begins.append(after) }
            if line == Array(endMarker.utf8) { ends.append((start, after)) }
            start = after
        }
        guard begins.count == 1, ends.count == 1, begins[0] <= ends[0].start else { return nil }
        return (begins[0], ends[0].start)
    }

    @Test(arguments: Array(1...60) as [UInt64])
    func confinementInvariantHoldsAcrossRandomOperations(_ seed: UInt64) async throws {
        var rng = SeededRandom(seed: seed)
        let target = HostsDocumentPropertyTests.target(seed)
        var generated = HostsDocumentPropertyTests.generate(&rng, target: target)
        generated.pre.insert((.filler("127.0.0.1 localhost"), "\n"), at: 0)
        let dir = try makeTempDir("inv")
        let hostsURL = try makeHostsFile(in: dir, generated.text(), mode: 0o644)
        let svc = HostsService(hostsURL: hostsURL, writer: DirectWriter(target: hostsURL),
                               backups: BackupManager(directory: dir.appendingPathComponent("backups")))
        let lines = (0..<5).map { HostLine(ip: HostsDocumentPropertyTests.ips[$0 % 4], hostname: HostsDocumentPropertyTests.hosts[$0 % 3]) }
            + [target]
        var groups = [HostGroup(name: "G", lines: lines)]
        for step in 0..<12 {
            let before = try readText(hostsURL)
            let line = lines[Int.random(in: 0..<lines.count, using: &rng)]
            let op = Int.random(in: 0..<6, using: &rng)
            let ctx = "seed \(seed) step \(step) op \(op): \(before.debugDescription)"
            do {
                switch op {
                case 0, 1: try await svc.apply { HostsEditor.setLine(line, enabled: op == 0, groups: groups, in: &$0) }
                case 2: try await svc.apply { HostsEditor.setGroup(groups[0], enabled: Bool.random(using: &rng), groups: groups, in: &$0) }
                case 3:
                    let new = HostLine(id: line.id, ip: "192.0.2.\(Int.random(in: 1...9, using: &rng))", hostname: line.hostname)
                    var next = groups
                    next[0].lines = next[0].lines.map { $0.id == line.id ? new : $0 }
                    try await svc.apply { HostsEditor.replaceLine(line, with: new, groups: next, in: &$0) }
                    groups = next
                case 4: try await svc.apply { $0.remove(line) }
                default: try await svc.apply { HostsEditor.setLine(line, enabled: true, groups: groups, in: &$0) }
                }
            } catch let error as HostsServiceError {
                #expect(error == .missingLocalhost || error == .confinementViolated || { if case .blockDamaged = error { return true } else { return false } }(), "\(ctx): \(error)")
            }
            let after = try readText(hostsURL)
            if let old = Self.blockOffsets(before) {
                let o = Array(before.utf8), n = Array(after.utf8)
                let new = Self.blockOffsets(after)
                #expect(new != nil, "\(ctx) block survives")
                if let new {
                    #expect(Array(n[..<new.beginLineEnd]) == Array(o[..<old.beginLineEnd]), "\(ctx) prefix")
                    #expect(Array(n[new.endLineStart...]) == Array(o[old.endLineStart...]), "\(ctx) suffix")
                }
            } else if HostsDocument(before).blockDamage == nil {
                #expect(after == before || after.hasPrefix(before), "\(ctx) old is an exact prefix")
                if after != before { #expect(Self.blockOffsets(after) != nil, "\(ctx) created block is well formed") }
            } else {
                #expect(after == before, "\(ctx) damaged file untouched")
            }
            #expect(HostsDocument(after).blockDamage == nil || HostsDocument(before).blockDamage != nil, "\(ctx) no damage introduced")
        }
    }
}
