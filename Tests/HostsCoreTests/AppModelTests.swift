import Foundation
import Testing
@testable import HostsCore

struct ModelEnv {
    var dir: URL
    var hostsURL: URL
    var storeURL: URL
    var backups: URL
    var service: HostsService
    var store: GroupStore
}

@MainActor
func makeEnv(hosts: String? = sampleHosts, writer: ((URL, URL) -> HostsWriter)? = nil, groups: [HostGroup]? = nil) throws -> ModelEnv {
    let dir = try makeTempDir("model")
    let hostsURL = dir.appendingPathComponent("hosts")
    if let hosts { try Data(hosts.utf8).write(to: hostsURL) }
    let backups = dir.appendingPathComponent("backups")
    let storeURL = dir.appendingPathComponent("support/groups.json")
    let w = writer?(hostsURL, dir) ?? LocalScriptWriter(target: hostsURL, tempDirectory: dir)
    let store = GroupStore(fileURL: storeURL)
    if let groups { try store.save(groups) }
    return ModelEnv(dir: dir, hostsURL: hostsURL, storeURL: storeURL, backups: backups,
                    service: HostsService(hostsURL: hostsURL, writer: w, backups: BackupManager(directory: backups)), store: store)
}

@MainActor
struct AppModelTests {
    let x1 = HostLine(ip: "10.0.0.1", hostname: "x.com")
    let y1 = HostLine(ip: "10.0.0.1", hostname: "y.com")
    let x2 = HostLine(ip: "10.0.0.2", hostname: "x.com")

    func model(_ env: ModelEnv) -> AppModel { AppModel(service: env.service, store: env.store) }

    // MARK: Reload

    @Test func reloadDerivesStateFromFile() async throws {
        let env = try makeEnv(hosts: "127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n# 10.0.0.1 y.com\n"),
                              groups: [HostGroup(name: "G", lines: [x1, y1, HostLine(ip: "10.0.0.1", hostname: "z.com")])])
        let m = model(env)
        await m.reload()
        #expect(m.lineState(x1) == .on && m.lineState(y1) == .off)
        #expect(m.lineState(m.groups[0].lines[2]) == .missing)
        #expect(m.groupState(m.groups[0]) == .mixed)
        #expect(m.errorMessage == nil)
    }

    @Test func reloadPicksUpExternalEdit() async throws {
        let env = try makeEnv(groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        #expect(m.lineState(x1) == .missing, "the commented copy sits outside the block")
        try Data((sampleHosts + blk("10.0.0.1 x.com\n")).utf8).write(to: env.hostsURL)
        await m.reload()
        #expect(m.lineState(x1) == .on)
    }

    @Test func reloadFlagsConflictsAndDoesNotWrite() async throws {
        let text = "127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n10.0.0.2 x.com\n")
        let w = FakeWriter()
        let env = try makeEnv(hosts: text, writer: { _, _ in w }, groups: [HostGroup(name: "A", lines: [x1]), HostGroup(name: "B", lines: [x2])])
        let m = model(env)
        await m.reload()
        #expect(m.conflictIDs == [x1.id, x2.id])
        #expect(try readText(env.hostsURL) == text)
        #expect(w.calls.isEmpty && !FileManager.default.fileExists(atPath: env.backups.path))
    }

    @Test func reloadIsReadOnlyForTheStoreToo() async throws {
        let env = try makeEnv()
        let m = model(env)
        await m.reload()
        #expect(!FileManager.default.fileExists(atPath: env.storeURL.deletingLastPathComponent().path))
    }

    @Test func reloadWithUnreadableFileSetsErrorAndKeepsPriorDocument() async throws {
        let env = try makeEnv(groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        let before = m.document
        #expect(!before.text.isEmpty)
        try FileManager.default.removeItem(at: env.hostsURL)
        await m.reload()
        #expect(m.errorMessage != nil)
        #expect(m.document == before)
    }

    @Test func reloadWithCorruptStoreSetsErrorAndSurvives() async throws {
        let env = try makeEnv()
        try FileManager.default.createDirectory(at: env.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: env.storeURL)
        let m = model(env)
        await m.reload()
        #expect(m.errorMessage != nil)
        #expect(m.groups.isEmpty)
        #expect(m.document.text == sampleHosts, "the file pane still loads")
    }

    @Test func corruptStoreIsNotClobbered() async throws {
        let env = try makeEnv()
        let junk = Data("{broken but precious".utf8)
        try FileManager.default.createDirectory(at: env.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try junk.write(to: env.storeURL)
        let m = model(env)
        await m.reload()
        try await m.addGroup(name: "New", input: "10.0.0.1 x.com")
        let siblings = try FileManager.default.contentsOfDirectory(at: env.storeURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let preserved = try siblings.contains { try Data(contentsOf: $0) == junk }
        #expect(preserved, "the unreadable groups file must survive as a sibling copy")
        #expect(try env.store.load().count == 1)
    }

    // MARK: Toggles

    @Test func setLineWritesOneChange() async throws {
        let w = FakeWriter()
        let env = try makeEnv(writer: { _, _ in w }, groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        await m.setLine(x1, enabled: true)
        #expect(w.calls.count == 1)
        #expect(w.calls[0].content == sampleHosts + "\n" + blk("10.0.0.1 x.com\n"), "the outside comment is not adopted")
        #expect(m.errorMessage == nil)
    }

    @Test func setLineWithRealWriterUpdatesDocument() async throws {
        let env = try makeEnv(groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        await m.setLine(x1, enabled: true)
        #expect(m.lineState(x1) == .on)
        #expect(try readText(env.hostsURL) == sampleHosts + "\n" + blk("10.0.0.1 x.com\n"))
        await m.setLine(x1, enabled: false)
        #expect(m.lineState(x1) == .off)
        #expect(try readText(env.hostsURL) == sampleHosts + "\n" + blk("# 10.0.0.1 x.com\n"))
    }

    @Test func setLineSetsNoticeWhenAutoDisabling() async throws {
        let env = try makeEnv(hosts: "127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n# 10.0.0.2 x.com\n"),
                              groups: [HostGroup(name: "A", lines: [x1]), HostGroup(name: "B", lines: [x2])])
        let m = model(env)
        await m.reload()
        await m.setLine(x2, enabled: true)
        #expect(m.notice == "Turned off 10.0.0.1 x.com")
        #expect(m.lineState(x1) == .off && m.lineState(x2) == .on)
        #expect(m.conflictIDs.isEmpty)
    }

    @Test func setGroupTogglesAllLinesInOneWrite() async throws {
        let w = FakeWriter()
        let env = try makeEnv(hosts: "127.0.0.1 localhost\n" + blk("# 10.0.0.1 x.com\n"), writer: { _, _ in w }, groups: [HostGroup(name: "G", lines: [x1, y1])])
        let m = model(env)
        await m.reload()
        await m.setGroup(m.groups[0], enabled: true)
        #expect(w.calls.count == 1)
        #expect(w.calls[0].content == "127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n10.0.0.1 y.com\n"))
    }

    @Test func cancelledToggleLeavesStateAndNoErrorAndNoBackups() async throws {
        let w = FakeWriter(results: [.failure(.cancelled)])
        let env = try makeEnv(writer: { _, _ in w }, groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        await m.setLine(x1, enabled: true)
        #expect(m.errorMessage == nil)
        #expect(m.lineState(x1) == .missing)
        #expect(backupNames(env.backups).isEmpty)
        #expect(try readText(env.hostsURL) == sampleHosts)
    }

    // MARK: Add group

    @Test func addGroupEnablesExistingCommentedBlockLinesWithoutDuplicates() async throws {
        let env = try makeEnv(hosts: "127.0.0.1 localhost\n" + blk("# 10.0.0.1 x.com\n"))
        let m = model(env)
        await m.reload()
        try await m.addGroup(name: "Sandbox", input: "10.0.0.1 x.com")
        #expect(try readText(env.hostsURL) == "127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n"))
        #expect(m.groupState(m.groups[0]) == .on)
    }

    @Test func addGroupAppendsMissingLinesEnabled() async throws {
        let env = try makeEnv()
        let m = model(env)
        await m.reload()
        try await m.addGroup(name: "Sandbox", input: "192.0.2.10 bork-test.example.test\n192.0.2.10 api.bork-test.example.test")
        #expect(try readText(env.hostsURL) == sampleHosts + "\n" + blk("192.0.2.10 bork-test.example.test\n192.0.2.10 api.bork-test.example.test\n"))
        #expect(backupNames(env.backups).count == 1)
    }

    @Test func addGroupConservesLineCounts() async throws {
        let existing = "127.0.0.1 localhost\n" + blk("10.0.0.1 a.com\n# 10.0.0.1 b.com\n10.0.0.9 c.com\n10.0.0.1 other.com\n")
        let env = try makeEnv(hosts: existing)
        let m = model(env)
        await m.reload()
        try await m.addGroup(name: "G", input: "10.0.0.1 a.com\n10.0.0.1 b.com\n10.0.0.1 c.com\n10.0.0.1 d.com\n10.0.0.1 e.com")
        let before = existing.split(separator: "\n").count
        let text = try readText(env.hostsURL)
        let after = text.split(separator: "\n")
        #expect(after.count == before + (5 - 2), "N=5 new pairs, K=2 already present")
        #expect(Set(after).count == after.count, "no line appears twice")
        #expect(text.contains("10.0.0.9 c.com") && text.contains("10.0.0.1 other.com"))
    }

    @Test func addGroupThrowsAndChangesNothingOnInvalidInput() async throws {
        let w = FakeWriter()
        let env = try makeEnv(writer: { _, _ in w })
        let m = model(env)
        await m.reload()
        await #expect(throws: AddInputError.invalidLine(number: 1, text: "nope")) { try await m.addGroup(name: "G", input: "nope") }
        await #expect(throws: AddInputError.blankName) { try await m.addGroup(name: "  ", input: "1.1.1.1 a.com") }
        await #expect(throws: AddInputError.reservedHostname("localhost")) { try await m.addGroup(name: "G", input: "1.1.1.1 localhost") }
        #expect(m.groups.isEmpty && w.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.storeURL.path))
    }

    @Test func addGroupRejectsPairAlreadyInAnotherGroup() async throws {
        let env = try makeEnv(groups: [HostGroup(name: "First", lines: [x1])])
        let m = model(env)
        await m.reload()
        await #expect(throws: AddInputError.alreadyInGroup(pair: "10.0.0.1 x.com", group: "First")) {
            try await m.addGroup(name: "Second", input: "10.0.0.1 X.com")
        }
        #expect(m.groups.count == 1)
    }

    @Test func addGroupKeepsGroupWhenAuthCancelled() async throws {
        let w = FakeWriter(results: [.failure(.cancelled)])
        let env = try makeEnv(writer: { _, _ in w })
        let m = model(env)
        await m.reload()
        try await m.addGroup(name: "G", input: "10.0.0.1 x.com")
        #expect(m.groups.count == 1)
        #expect(try env.store.load().count == 1)
        #expect(m.errorMessage == nil)
        #expect(m.lineState(m.groups[0].lines[0]) != .on)
        #expect(m.groupState(m.groups[0]) == .off)
        #expect(backupNames(env.backups).isEmpty)
    }

    @Test func addGroupStoreSaveFailsMeansNoFileWrite() async throws {
        let w = FakeWriter()
        let env = try makeEnv(writer: { _, _ in w })
        let supportDir = env.storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: supportDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: supportDir.path) }
        let m = model(env)
        await m.reload()
        await #expect(throws: (any Error).self) { try await m.addGroup(name: "G", input: "10.0.0.1 x.com") }
        #expect(w.calls.isEmpty && m.groups.isEmpty)
    }

    // MARK: Edit / add line

    @Test func editLineRewritesIPInFileKeepingState() async throws {
        let env = try makeEnv(hosts: "127.0.0.1 localhost\n" + blk("# 10.0.0.1 x.com\n10.0.0.1 y.com\n"), groups: [HostGroup(name: "G", lines: [x1, y1])])
        let m = model(env)
        await m.reload()
        #expect(await m.editLine(x1.id, ip: "10.0.0.5", hostname: "x.com"))
        #expect(await m.editLine(y1.id, ip: "10.0.0.5", hostname: "y.com"))
        #expect(try readText(env.hostsURL) == "127.0.0.1 localhost\n" + blk("# 10.0.0.5 x.com\n10.0.0.5 y.com\n"))
        #expect(m.groups[0].lines.map(\.ip) == ["10.0.0.5", "10.0.0.5"])
        #expect(try env.store.load() == m.groups)
    }

    @Test func editLineRejectsBadInputWithoutChanges() async throws {
        let w = FakeWriter()
        let other = HostGroup(name: "Other", lines: [HostLine(ip: "10.0.0.3", hostname: "z.com")])
        let env = try makeEnv(writer: { _, _ in w }, groups: [HostGroup(name: "G", lines: [x1]), other])
        let m = model(env)
        await m.reload()
        for (ip, host) in [("", "x.com"), ("10.0.0.1", ""), ("10.0.0.1", "bad host"), ("10.0.0.3", "z.com"), ("127.0.0.1", "localhost")] {
            await m.editLine(x1.id, ip: ip, hostname: host)
            #expect(m.errorMessage != nil, "\(ip) \(host)")
            m.dismissError()
        }
        #expect(w.calls.isEmpty && m.groups[0].lines == [x1])
    }

    @Test func editLineStoreSaveFailsAfterWrite() async throws {
        let env = try makeEnv(hosts: "127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n"), groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        let supportDir = env.storeURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: supportDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: supportDir.path) }
        await m.editLine(x1.id, ip: "10.0.0.7", hostname: "x.com")
        #expect(m.errorMessage != nil)
        #expect(try readText(env.hostsURL) == "127.0.0.1 localhost\n" + blk("10.0.0.7 x.com\n"))
        await m.reload()
        #expect(m.lineState(m.groups[0].lines[0]) == .missing, "reload shows the true file state, not a silent split brain")
    }

    @Test func editLineToConflictTurnsOtherOff() async throws {
        let other = HostLine(ip: "10.0.0.9", hostname: "x.com")
        let env = try makeEnv(hosts: "127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n10.0.0.9 x.com\n"),
                              groups: [HostGroup(name: "A", lines: [HostLine(id: x1.id, ip: "10.0.0.1", hostname: "x.com")]), HostGroup(name: "O", lines: [other])])
        let m = model(env)
        await m.reload()
        #expect(m.conflictIDs.count == 2)
        await m.editLine(x1.id, ip: "10.0.0.9", hostname: "x.com")
        // Same pair as the other group's line is refused (D7); the file is untouched.
        #expect(m.errorMessage != nil)
        await m.editLine(x1.id, ip: "10.0.0.8", hostname: "x.com")
        #expect(m.lineState(other) == .off)
        #expect(m.conflictIDs.isEmpty)
    }

    @Test func addLineAppendsEnabledAndKeepsGroup() async throws {
        let env = try makeEnv(groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        let gid = m.groups[0].id
        try await m.addLine(to: gid, ip: "10.0.0.1", hostname: "new.com")
        #expect(m.groups[0].lines.count == 2)
        #expect(try readText(env.hostsURL) == sampleHosts + "\n" + blk("10.0.0.1 new.com\n"))
        #expect(try env.store.load().first?.lines.count == 2)
    }

    @Test func addLineValidation() async throws {
        let env = try makeEnv(groups: [HostGroup(name: "G", lines: [x1]), HostGroup(name: "O", lines: [y1.withHost("o.com")])])
        let m = model(env)
        await m.reload()
        let gid = m.groups[0].id
        await #expect(throws: AddInputError.self) { try await m.addLine(to: gid, ip: "", hostname: "a.com") }
        await #expect(throws: AddInputError.self) { try await m.addLine(to: gid, ip: "1.1.1.1", hostname: "a b") }
        await #expect(throws: AddInputError.conflictingHostname("x.com")) { try await m.addLine(to: gid, ip: "10.0.0.2", hostname: "x.com") }
        await #expect(throws: AddInputError.alreadyInGroup(pair: "10.0.0.1 o.com", group: "O")) { try await m.addLine(to: gid, ip: "10.0.0.1", hostname: "o.com") }
        await #expect(throws: AddInputError.reservedHostname("broadcasthost")) { try await m.addLine(to: gid, ip: "255.255.255.255", hostname: "broadcasthost") }
        #expect(m.groups[0].lines.count == 1)
    }

    // MARK: Delete

    @Test func deleteGroupRemovesMatchingFileLinesOnly() async throws {
        let text = "127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n# 10.0.0.1 y.com\n10.0.0.1 other.com\n10.0.0.2 x.com\n10.0.0.1 x.com extra\n") + "9.9.9.9 keep\n"
        let env = try makeEnv(hosts: text, groups: [HostGroup(name: "G", lines: [x1, y1])])
        let m = model(env)
        await m.reload()
        await m.deleteGroup(m.groups[0].id)
        #expect(try readText(env.hostsURL) == "127.0.0.1 localhost\n" + blk("10.0.0.1 other.com\n10.0.0.2 x.com\n10.0.0.1 x.com extra\n") + "9.9.9.9 keep\n")
        #expect(m.groups.isEmpty)
        #expect(try env.store.load().isEmpty)
    }

    @Test func deleteGroupKeptWhenWriteFails() async throws {
        let w = FakeWriter(results: [.failure(.failed("nope"))])
        let env = try makeEnv(hosts: "127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n"), writer: { _, _ in w }, groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        await m.deleteGroup(m.groups[0].id)
        #expect(m.groups.count == 1 && m.errorMessage == "nope")
        #expect(try env.store.load().count == 1)
    }

    @Test func deleteLineRemovesOnlyThatLine() async throws {
        let env = try makeEnv(hosts: "127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n10.0.0.1 y.com\n"), groups: [HostGroup(name: "G", lines: [x1, y1])])
        let m = model(env)
        await m.reload()
        await m.deleteLine(x1.id)
        #expect(try readText(env.hostsURL) == "127.0.0.1 localhost\n" + blk("10.0.0.1 y.com\n"))
        #expect(m.groups[0].lines == [y1])
    }

    @Test func deleteNeverRemovesSystemEntriesEvenFromLegacyData() async throws {
        let sys = HostLine(ip: "127.0.0.1", hostname: "localhost")
        let env = try makeEnv(hosts: "127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n"), groups: [HostGroup(name: "G", lines: [sys, x1])])
        let m = model(env)
        await m.reload()
        await m.deleteGroup(m.groups[0].id)
        #expect(try readText(env.hostsURL) == "127.0.0.1 localhost\n" + blk())
    }

    // MARK: Persistence and renaming

    @Test func groupsPersistAcrossModelInstances() async throws {
        let env = try makeEnv()
        let m1 = model(env)
        await m1.reload()
        try await m1.addGroup(name: "Keep", input: "10.0.0.1 x.com")
        await m1.renameGroup(m1.groups[0].id, to: "Renamed")
        let m2 = model(env)
        await m2.reload()
        #expect(m2.groups.map(\.name) == ["Renamed"])
        #expect(m2.groups == m1.groups)
        await m2.renameGroup(m2.groups[0].id, to: "  ")
        #expect(m2.groups[0].name == "Renamed" && m2.errorMessage != nil)
    }

    // MARK: Injection and failures

    @Test func groupsJsonWithNewlineInHostnameCannotInject() async throws {
        let w = FakeWriter()
        let evil = HostLine(ip: "1.1.1.1", hostname: "a.com\n6.6.6.6 evil.com")
        let evilIP = HostLine(ip: "1.1.1.1\n6.6.6.6", hostname: "b.com")
        let hashIP = HostLine(ip: "1.1.1.1 # x", hostname: "c.com")
        let env = try makeEnv(writer: { _, _ in w }, groups: [HostGroup(name: "Evil", lines: [evil, evilIP, hashIP])])
        let m = model(env)
        await m.reload()
        for line in [evil, evilIP, hashIP] {
            await m.setLine(line, enabled: true)
            #expect(m.errorMessage != nil)
            m.dismissError()
        }
        await m.setGroup(m.groups[0], enabled: true)
        #expect(m.errorMessage != nil)
        #expect(w.calls.isEmpty)
        #expect(try readText(env.hostsURL) == sampleHosts)
    }

    @Test func missingHostsFileOnWriteSetsError() async throws {
        let env = try makeEnv(hosts: nil, groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        #expect(m.errorMessage != nil)
        m.dismissError()
        await m.setLine(x1, enabled: true)
        #expect(m.errorMessage != nil)
    }

    @Test func backupDirectoryUnwritableSetsErrorAndWritesNothing() async throws {
        let w = FakeWriter()
        let env = try makeEnv(writer: { _, _ in w }, groups: [HostGroup(name: "G", lines: [x1])])
        try FileManager.default.createDirectory(at: env.backups, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: env.backups.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: env.backups.path) }
        let m = model(env)
        await m.reload()
        await m.setLine(x1, enabled: true)
        #expect(m.errorMessage != nil && w.calls.isEmpty)
    }

    @Test func writerFailureSetsErrorAndRealOsascriptPathMissingSurvives() async throws {
        let env = try makeEnv(groups: [HostGroup(name: "G", lines: [x1])])
        let m1 = model(env)
        await m1.reload()
        let failing = FakeWriter(results: [.failure(.failed("disk on fire"))])
        let svc = HostsService(hostsURL: env.hostsURL, writer: failing, backups: BackupManager(directory: env.backups))
        let m = AppModel(service: svc, store: env.store)
        await m.reload()
        await m.setLine(x1, enabled: true)
        #expect(m.errorMessage == "disk on fire")

        let badOsa = OsascriptWriter(target: env.hostsURL, flushDNS: false, elevated: true, tempDirectory: env.dir, osascriptPath: "/nonexistent/osascript")
        let svc2 = HostsService(hostsURL: env.hostsURL, writer: badOsa, backups: BackupManager(directory: env.backups))
        let m2 = AppModel(service: svc2, store: env.store)
        await m2.reload()
        await m2.setLine(x1, enabled: true)
        #expect(m2.errorMessage != nil)
        #expect(try readText(env.hostsURL) == sampleHosts)
    }

    // MARK: Serialization (criterion 33)

    @Test func reloadWaitsForInFlightWriteAndFinalDocumentIsPostWrite() async throws {
        let gate = Gate()
        let env = try makeEnv(writer: { url, dir in GatedWriter(inner: LocalScriptWriter(target: url, tempDirectory: dir), gate: gate) },
                              groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        let toggle = Task { await m.setLine(x1, enabled: true) }
        while await gate.waitingCount == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        var reloadDone = false
        let reload = Task { await m.reload(); reloadDone = true }
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(!reloadDone, "reload must not run while a write is in flight")
        #expect(m.isBusy)
        await gate.release()
        await toggle.value
        await reload.value
        #expect(m.lineState(x1) == .on)
        #expect(try readText(env.hostsURL).contains("10.0.0.1 x.com\n"))
    }

    @Test func secondToggleWhileFirstInFlightIsQueuedWithOneWriteEach() async throws {
        let gate = Gate()
        let counting = FakeWriter()
        let env = try makeEnv(writer: { url, dir in
            return GatedWriter(inner: CountingWriter(inner: LocalScriptWriter(target: url, tempDirectory: dir), counter: counting), gate: gate)
        }, groups: [HostGroup(name: "G", lines: [x1, y1])])
        let m = model(env)
        await m.reload()
        let t1 = Task { await m.setLine(x1, enabled: true) }
        while await gate.waitingCount == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        let t2 = Task { await m.setLine(y1, enabled: true) }
        try await Task.sleep(nanoseconds: 40_000_000)
        #expect(counting.calls.isEmpty, "the first write is parked at the gate and the second must not start")
        await gate.release()
        await t1.value
        await t2.value
        #expect(counting.calls.count == 2, "exactly one write per accepted call")
        #expect(m.lineState(x1) == .on && m.lineState(y1) == .on, "no lost update")
    }

    // MARK: Corrective slice

    @Test func renameDuringInFlightEditIsNotLost() async throws {
        let gate = Gate()
        let env = try makeEnv(hosts: "127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n"),
                              writer: { url, dir in GatedWriter(inner: LocalScriptWriter(target: url, tempDirectory: dir), gate: gate) },
                              groups: [HostGroup(name: "Old", lines: [x1])])
        let m = model(env)
        await m.reload()
        let gid = m.groups[0].id
        let edit = Task { await m.editLine(x1.id, ip: "10.0.0.9", hostname: "x.com") }
        while await gate.waitingCount == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        let rename = Task { await m.renameGroup(gid, to: "New") }
        try await Task.sleep(nanoseconds: 40_000_000)
        await gate.release()
        _ = await edit.value
        await rename.value
        #expect(m.groups[0].name == "New" && m.groups[0].lines[0].ip == "10.0.0.9")
        let saved = try env.store.load()
        #expect(saved[0].name == "New" && saved[0].lines[0].ip == "10.0.0.9", "the persisted store must have both changes")
    }

    @Test func editLineReturnsFalseAndKeepsStateWhenAuthCancelled() async throws {
        let w = FakeWriter(results: [.failure(.cancelled)])
        let env = try makeEnv(hosts: "127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n"), writer: { _, _ in w }, groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        let before = m.groups
        let ok = await m.editLine(x1.id, ip: "10.0.0.9", hostname: "x.com")
        #expect(ok == false)
        #expect(m.errorMessage == nil, "a cancel is not an error")
        #expect(m.groups == before)
        #expect(try env.store.load() == before)
        #expect(backupNames(env.backups).isEmpty)
        #expect(try readText(env.hostsURL) == "127.0.0.1 localhost\n" + blk("10.0.0.1 x.com\n"))
    }

    @Test func editLineReturnsTrueForNoOpAndFalseForInvalid() async throws {
        let env = try makeEnv(groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        #expect(await m.editLine(x1.id, ip: "10.0.0.1", hostname: "x.com") == true, "unchanged values are a no-op")
        #expect(await m.editLine(x1.id, ip: "", hostname: "x.com") == false)
        #expect(m.errorMessage != nil)
    }

    @Test func reloadClearsEarlierErrorOnSuccess() async throws {
        let env = try makeEnv()
        let supportDir = env.storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: env.storeURL)
        let m = model(env)
        await m.reload()
        #expect(m.errorMessage != nil)
        try env.store.save([])
        await m.reload()
        #expect(m.errorMessage == nil, "a successful reload must not leave the old banner up")
    }

    @Test func reloadShowsBothErrorsWhenStoreAndHostsFail() async throws {
        let env = try makeEnv(hosts: nil)
        try FileManager.default.createDirectory(at: env.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: env.storeURL)
        let m = model(env)
        await m.reload()
        let parts = (m.errorMessage ?? "").components(separatedBy: "\n")
        #expect(parts.count == 2, "\(m.errorMessage ?? "nil")")
        #expect(parts.first?.contains("saved groups") == true)
        #expect(parts.last?.contains("hosts file") == true)
    }

    @Test func reloadDoesNotClearAnOperationError() async throws {
        let w = FakeWriter(results: [.failure(.failed("boom"))])
        let env = try makeEnv(writer: { _, _ in w }, groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        await m.setLine(x1, enabled: true)
        #expect(m.errorMessage == "boom")
        await m.reload()
        #expect(m.errorMessage == "boom", "a healthy reload must leave an operation's error alone")
    }

    @Test func reloadStillClearsItsOwnEarlierError() async throws {
        let env = try makeEnv(groups: [HostGroup(name: "G", lines: [x1])])
        let backup = try Data(contentsOf: env.hostsURL)
        try FileManager.default.removeItem(at: env.hostsURL)
        let m = model(env)
        await m.reload()
        #expect(m.errorMessage != nil)
        try backup.write(to: env.hostsURL)
        await m.reload()
        #expect(m.errorMessage == nil)
    }

    @Test func focusReloadQueuedBehindFailingWriteKeepsTheFailureBanner() async throws {
        let gate = Gate()
        let w = FakeWriter(results: [.failure(.failed("late failure"))]) { _, _ in await gate.wait() }
        let env = try makeEnv(writer: { _, _ in w }, groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        let toggle = Task { await m.setLine(x1, enabled: true) }
        while await gate.waitingCount == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        let focusReload = Task { await m.reload() }
        try await Task.sleep(nanoseconds: 40_000_000)
        await gate.release()
        await toggle.value
        await focusReload.value
        #expect(m.errorMessage == "late failure")
        #expect(m.lineState(x1) == .missing)
    }

    @Test func editLineOnMissingLineReportsErrorNotCancel() async throws {
        let w = FakeWriter()
        let env = try makeEnv(writer: { _, _ in w }, groups: [HostGroup(name: "G", lines: [x1])])
        let m = model(env)
        await m.reload()
        let ok = await m.editLine(UUID(), ip: "10.0.0.9", hostname: "x.com")
        #expect(ok == false)
        #expect(m.errorMessage == "That entry no longer exists, so nothing was changed.")
        #expect(w.calls.isEmpty)
    }

    // MARK: Invariant over random operations (criterion 26)

    @Test(arguments: [1, 2, 3] as [UInt64])
    func oneIPPerHostnameHoldsAfterEveryOperation(_ seed: UInt64) async throws {
        var rng = SeededRandom(seed: seed)
        let env = try makeEnv(hosts: "127.0.0.1 localhost\n# banner\n")
        let m = model(env)
        await m.reload()
        let hosts = ["a.com", "b.com", "c.com"]
        let ips = ["10.0.0.1", "10.0.0.2", "10.0.0.3"]
        func pick<T>(_ a: [T]) -> T { a[Int.random(in: 0..<a.count, using: &rng)] }
        var log: [String] = []
        for step in 0..<40 {
            let before = m.conflictIDs
            let op = Int.random(in: 0..<6, using: &rng)
            switch op {
            case 0:
                let lines = Set((0..<Int.random(in: 1...2, using: &rng)).map { _ in "\(pick(ips)) \(pick(hosts))" })
                log.append("addGroup \(lines)")
                try? await m.addGroup(name: "G\(step)", input: lines.joined(separator: "\n"))
            case 1 where !m.groups.isEmpty:
                let g = pick(m.groups); log.append("addLine \(g.name)")
                try? await m.addLine(to: g.id, ip: pick(ips), hostname: pick(hosts))
            case 2 where !m.groups.flatMap(\.lines).isEmpty:
                let l = pick(m.groups.flatMap(\.lines)); log.append("setLine on \(l.ip) \(l.hostname)")
                await m.setLine(l, enabled: true)
            case 3 where !m.groups.isEmpty:
                let g = pick(m.groups); log.append("setGroup on \(g.name)")
                await m.setGroup(g, enabled: true)
            case 4 where !m.groups.flatMap(\.lines).isEmpty:
                let l = pick(m.groups.flatMap(\.lines)); log.append("editLine \(l.ip) \(l.hostname)")
                await m.editLine(l.id, ip: pick(ips), hostname: pick(hosts))
            case 5 where !m.groups.flatMap(\.lines).isEmpty:
                let l = pick(m.groups.flatMap(\.lines)); log.append("setLine off")
                await m.setLine(l, enabled: false)
            default: continue
            }
            #expect(m.conflictIDs.isSubset(of: before), "seed \(seed) step \(step) introduced a conflict; ops: \(log.suffix(3))")
            let text = try readText(env.hostsURL)
            #expect(text.hasPrefix("127.0.0.1 localhost\n# banner\n"), "seed \(seed): unmanaged lines changed")
            m.dismissError()
        }
        #expect(!backupNames(env.backups).isEmpty, "seed \(seed): the random run should have written at least once")
    }
}

extension HostLine {
    func withHost(_ h: String) -> HostLine { HostLine(id: id, ip: ip, hostname: h) }
}

struct CountingWriter: HostsWriter {
    let inner: HostsWriter
    let counter: FakeWriter
    func write(newContent: String, expectedCurrentSHA256: String) async throws {
        try await counter.write(newContent: newContent, expectedCurrentSHA256: expectedCurrentSHA256)
        try await inner.write(newContent: newContent, expectedCurrentSHA256: expectedCurrentSHA256)
    }
}
