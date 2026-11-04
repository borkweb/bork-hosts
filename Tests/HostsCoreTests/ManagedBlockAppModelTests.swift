import Foundation
import Testing
@testable import HostsCore

@MainActor
struct ManagedBlockAppModelTests {
    let x1 = HostLine(ip: "10.0.0.1", hostname: "x.com")
    let y1 = HostLine(ip: "10.0.0.1", hostname: "y.com")
    let x2 = HostLine(ip: "10.0.0.2", hostname: "x.com")
    let localhost = "127.0.0.1 localhost\n"

    func model(_ env: ModelEnv) -> AppModel { AppModel(service: env.service, store: env.store) }

    // MARK: Writes land in the block

    @Test func setLineOnBlocklessFileCreatesTheBlock() async throws {
        let w = FakeWriter()
        let env = try makeEnv(hosts: sampleHosts, writer: { _, _ in w }, groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        await m.setLine(x1, enabled: true)
        #expect(w.calls.count == 1)
        #expect(w.calls[0].content == sampleHosts + "\n" + blk("10.0.0.1 x.com\n"), "the outside comment is not adopted")
    }

    @Test func turningOffAMissingLineWritesNothing() async throws {
        let w = FakeWriter()
        let env = try makeEnv(hosts: sampleHosts, writer: { _, _ in w }, groups: [HostGroup(name: "G", lines: [x1, y1])])
        let m = model(env)
        await m.reload()
        await m.setLine(x1, enabled: false)
        await m.setGroup(m.groups[0], enabled: false)
        #expect(w.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.backups.path))
        #expect(try readText(env.hostsURL) == sampleHosts)
        #expect(m.errorMessage == nil && !m.isBusy)
    }

    @Test func groupOnCreatesOneBlockWithAllLines() async throws {
        let w = FakeWriter()
        let env = try makeEnv(hosts: localhost, writer: { _, _ in w }, groups: [HostGroup(name: "G", lines: [x1, y1])])
        let m = model(env)
        await m.reload()
        await m.setGroup(m.groups[0], enabled: true)
        #expect(w.calls.count == 1)
        #expect(w.calls[0].content == localhost + "\n" + blk("10.0.0.1 x.com\n10.0.0.1 y.com\n"))
    }

    @Test func addGroupCreatesTheBlockThenAddLineInsertsBeforeEnd() async throws {
        let env = try makeEnv(hosts: localhost, groups: [])
        let m = model(env)
        await m.reload()
        try await m.addGroup(name: "G", input: "10.0.0.1 x.com")
        #expect(try readText(env.hostsURL) == localhost + "\n" + blk("10.0.0.1 x.com\n"))
        try await m.addLine(to: m.groups[0].id, ip: "10.0.0.1", hostname: "y.com")
        #expect(try readText(env.hostsURL) == localhost + "\n" + blk("10.0.0.1 x.com\n10.0.0.1 y.com\n"))
    }

    @Test func outsideActiveLineIsNeverTurnedOffByTheOneIPRule() async throws {
        let outside = localhost + "10.0.0.2 x.com\n"
        let env = try makeEnv(hosts: outside, groups: [HostGroup(name: "G", lines: [x1, x2])])
        let m = model(env)
        await m.reload()
        #expect(m.lineState(x2) == .missing)
        await m.setLine(x1, enabled: true)
        #expect(try readText(env.hostsURL) == outside + "\n" + blk("10.0.0.1 x.com\n"))
        #expect(m.notice == nil)
        #expect(m.conflictIDs.isEmpty)
    }

    // MARK: Delete and edit touch only the block

    @Test func deleteLineRemovesOnlyTheBlockCopy() async throws {
        let text = localhost + "10.0.0.1 x.com\n" + blk("10.0.0.1 x.com\n10.0.0.1 y.com\n") + "# 10.0.0.1 x.com\n"
        let env = try makeEnv(hosts: text, groups: [HostGroup(name: "G", lines: [x1, y1])])
        let m = model(env)
        await m.reload()
        await m.deleteLine(x1.id)
        #expect(try readText(env.hostsURL) == localhost + "10.0.0.1 x.com\n" + blk("10.0.0.1 y.com\n") + "# 10.0.0.1 x.com\n")
        #expect(m.groups[0].lines.map(\.id) == [y1.id])
        await m.deleteGroup(m.groups[0].id)
        #expect(try readText(env.hostsURL) == localhost + "10.0.0.1 x.com\n" + blk() + "# 10.0.0.1 x.com\n", "markers stay when the block empties")
        #expect(m.groups.isEmpty)
    }

    @Test func deleteLineWithNoBlockCopyStillLeavesTheStoreWithoutWriting() async throws {
        let w = FakeWriter()
        let text = localhost + "10.0.0.1 x.com\n"
        let env = try makeEnv(hosts: text, writer: { _, _ in w }, groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        await m.deleteLine(x1.id)
        #expect(w.calls.isEmpty)
        #expect(m.groups[0].lines.isEmpty)
        #expect(try readText(env.hostsURL) == text)
    }

    @Test func editLineRewritesOnlyTheBlockCopyAndKeepsState() async throws {
        let text = localhost + "10.0.0.1 x.com\n" + blk("# 10.0.0.1 x.com\n")
        let env = try makeEnv(hosts: text, groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        let ok = await m.editLine(x1.id, ip: "10.0.0.9", hostname: "x.com")
        #expect(ok)
        #expect(try readText(env.hostsURL) == localhost + "10.0.0.1 x.com\n" + blk("# 10.0.0.9 x.com\n"))
        #expect(m.groups[0].lines[0].ip == "10.0.0.9")
    }

    @Test func editLineWithOnlyAnOutsideCopyUpdatesTheStoreWithoutWriting() async throws {
        let w = FakeWriter()
        let text = localhost + "10.0.0.1 x.com\n"
        let env = try makeEnv(hosts: text, writer: { _, _ in w }, groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        let ok = await m.editLine(x1.id, ip: "10.0.0.9", hostname: "x.com")
        #expect(ok)
        #expect(w.calls.isEmpty)
        #expect(try readText(env.hostsURL) == text)
        #expect(m.groups[0].lines[0].ip == "10.0.0.9")
    }

    // MARK: Damaged markers: every operation refuses and names the problem

    nonisolated static let damageShapes: [String] = [
        "127.0.0.1 localhost\n" + beginMarker + "\n10.0.0.1 x.com\n",
        "127.0.0.1 localhost\n" + endMarker + "\n" + beginMarker + "\n10.0.0.1 x.com\n",
    ]

    enum Op: String, CaseIterable, CustomTestStringConvertible {
        case setLineOn, setLineOff, setGroupOn, setGroupOff, addGroup, addLine, editLine, deleteGroup, deleteLine
        var testDescription: String { rawValue }
    }

    @Test(arguments: damageShapes, Op.allCases)
    func damagedMarkersRefuseEveryOperation(_ text: String, _ op: Op) async throws {
        let w = FakeWriter()
        let g = HostGroup(name: "G", lines: [x1])
        let env = try makeEnv(hosts: text, writer: { _, _ in w }, groups: [g])
        let m = model(env)
        await m.reload()
        m.dismissError()
        switch op {
        case .setLineOn: await m.setLine(x1, enabled: true)
        case .setLineOff: await m.setLine(x1, enabled: false)
        case .setGroupOn: await m.setGroup(g, enabled: true)
        case .setGroupOff: await m.setGroup(g, enabled: false)
        case .addGroup: try? await m.addGroup(name: "New", input: "10.0.0.5 new.com")
        case .addLine: try? await m.addLine(to: g.id, ip: "10.0.0.5", hostname: "new.com")
        case .editLine: _ = await m.editLine(x1.id, ip: "10.0.0.9", hostname: "x.com")
        case .deleteGroup: await m.deleteGroup(g.id)
        case .deleteLine: await m.deleteLine(x1.id)
        }
        #expect(try readText(env.hostsURL) == text)
        #expect(w.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.backups.path) || backupNames(env.backups).isEmpty)
        let message = m.errorMessage ?? ""
        #expect(message.contains("BEGIN") || message.contains("END"), "error names the marker: \(message)")
        #expect(!message.lowercased().contains("cancel"))
        #expect(!m.isBusy)
        #expect(try env.store.load() == [g], "the store is unchanged when the write is refused")
    }

    // MARK: Damaged markers: reading and display still work

    @Test(arguments: damageShapes)
    func reloadOnDamagedMarkersShowsTheProblemAndStillDisplays(_ text: String) async throws {
        let env = try makeEnv(hosts: text, groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        #expect(m.document.text == text)
        #expect(m.document.displayLines.count == text.split(separator: "\n", omittingEmptySubsequences: false).count - 1)
        #expect(m.lineState(x1) == .missing, "damaged markers mean no block, so nothing reads as managed")
        #expect(m.outsideWarnings.isEmpty)
        let message = m.errorMessage ?? ""
        #expect(message.contains("BEGIN") || message.contains("END"), "launch and focus reload name the problem: \(message)")
        try Data(HostsDocument(text).text.replacingOccurrences(of: beginMarker, with: "# gone").replacingOccurrences(of: endMarker, with: "# gone").utf8).write(to: env.hostsURL)
        await m.reload()
        #expect(m.errorMessage == nil, "the reload message clears once the file is healthy")
    }

    @Test func reloadJoinsDamageWithAStoreProblem() async throws {
        let env = try makeEnv(hosts: Self.damageShapes[0])
        try FileManager.default.createDirectory(at: env.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: env.storeURL)
        let m = model(env)
        await m.reload()
        let message = m.errorMessage ?? ""
        #expect(message.contains("groups could not be read") && message.contains("END"))
    }

    @Test func noOpOnDamagedFileStillReports() async throws {
        let env = try makeEnv(hosts: Self.damageShapes[0], groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        m.dismissError()
        await m.setLine(x1, enabled: false)
        #expect((m.errorMessage ?? "").contains("END"))
    }

    // MARK: Outside-line warnings

    func warningEnv(_ hosts: String, writer: HostsWriter? = nil) throws -> (ModelEnv, AppModel) {
        let env = try makeEnv(hosts: hosts, writer: writer.map { w in { _, _ in w } }, groups: [HostGroup(name: "G", lines: [x1, y1])])
        return (env, model(env))
    }

    @Test func warningIsOnlyForOnLinesAndNamesTheOutsideLine() async throws {
        let (_, m) = try warningEnv(localhost + blk("10.0.0.1 y.com\n") + "10.0.0.7 x.com\n# 10.0.0.8 y.com\n")
        await m.reload()
        #expect(m.lineState(x1) == .missing && m.lineState(y1) == .on)
        #expect(m.outsideWarnings.isEmpty, "x is off and the only outside line for y is commented")
    }

    @Test func warningLineNumberFollowsTheBlockAsItGrows() async throws {
        let (env, m) = try warningEnv(localhost + blk("10.0.0.1 y.com\n") + "10.0.0.7 x.com\n")
        await m.reload()
        #expect(m.outsideWarnings.isEmpty)
        await m.setLine(x1, enabled: true)
        #expect(m.lineState(x1) == .on)
        #expect(m.outsideWarnings == [x1.id: 6], "outside line moved from physical line 5 to 6")
        #expect(try readText(env.hostsURL).split(separator: "\n", omittingEmptySubsequences: false)[5] == "10.0.0.7 x.com")
        await m.setLine(x1, enabled: false)
        #expect(m.outsideWarnings.isEmpty)
    }

    @Test func creatingTheBlockAtTheEndKeepsEarlierLineNumbers() async throws {
        let (_, m) = try warningEnv("10.0.0.7 x.com\n" + localhost)
        await m.reload()
        await m.setGroup(m.groups[0], enabled: true)
        #expect(m.outsideWarnings == [x1.id: 1])
        #expect(m.conflictIDs.isEmpty, "an outside match is not an in-block conflict")
    }

    @Test func warningFollowsExternalEditsOnReload() async throws {
        let (env, m) = try warningEnv(localhost + blk("10.0.0.1 x.com\n"))
        await m.reload()
        #expect(m.outsideWarnings.isEmpty)
        try Data((localhost + blk("10.0.0.1 x.com\n") + "10.0.0.7 x.com\n").utf8).write(to: env.hostsURL)
        await m.reload()
        #expect(m.outsideWarnings == [x1.id: 5])
        try Data(("# top\n" + localhost + blk("10.0.0.1 x.com\n") + "10.0.0.7 other x.com\n").utf8).write(to: env.hostsURL)
        await m.reload()
        #expect(m.outsideWarnings == [x1.id: 6], "multi-hostname outside lines count too")
        try Data((localhost + blk("10.0.0.1 x.com\n") + "# 10.0.0.7 x.com\n").utf8).write(to: env.hostsURL)
        await m.reload()
        #expect(m.outsideWarnings.isEmpty)
    }

    @Test func lowestOutsideLineIsNamed() async throws {
        let (_, m) = try warningEnv("10.0.0.7 x.com\n" + localhost + blk("10.0.0.1 x.com\n") + "10.0.0.8 x.com\n")
        await m.reload()
        #expect(m.outsideWarnings == [x1.id: 1])
    }

    @Test func inBlockConflictAddsNoWarning() async throws {
        let env = try makeEnv(hosts: localhost + blk("10.0.0.1 x.com\n10.0.0.2 x.com\n"),
                              groups: [HostGroup(name: "A", lines: [x1]), HostGroup(name: "B", lines: [x2])])
        let m = model(env)
        await m.reload()
        #expect(m.conflictIDs == [x1.id, x2.id])
        #expect(m.outsideWarnings.isEmpty)
    }

    @Test func outsideWarningTextNamesTheLine() {
        let text = AppModel.outsideWarningText(lineNumber: 12)
        #expect(text.contains("line 12"))
        #expect(text.contains("bork-hosts block"))
    }

    // MARK: Refusals leave no residue

    @Test func nextOperationSucceedsAfterARefusal() async throws {
        let env = try makeEnv(hosts: Self.damageShapes[0], groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        await m.setLine(x1, enabled: true)
        #expect(!m.isBusy)
        try Data((localhost).utf8).write(to: env.hostsURL)
        await m.reload()
        await m.setLine(x1, enabled: true)
        #expect(m.lineState(x1) == .on)
        #expect(try readText(env.hostsURL) == localhost + "\n" + blk("10.0.0.1 x.com\n"))
    }
}
