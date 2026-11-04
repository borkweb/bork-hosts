import Foundation
import Testing
@testable import HostsCore

struct BackupManagerTests {
    @Test func createsTimestampedCopyInNewDirectory() throws {
        let dir = try makeTempDir("backup").appendingPathComponent("not/yet/there")
        let m = BackupManager(directory: dir)
        let when = Date(timeIntervalSince1970: 1_700_000_000.123)
        let url = try m.createBackup(of: "a\r\nb", now: when)
        #expect(url.lastPathComponent.range(of: #"^hosts-\d{8}-\d{6}-\d{3}$"#, options: .regularExpression) != nil)
        #expect(try readText(url) == "a\r\nb")
    }

    @Test func sameMillisecondDoesNotOverwrite() throws {
        let m = BackupManager(directory: try makeTempDir("backup"))
        let when = Date()
        let a = try m.createBackup(of: "one", now: when)
        let b = try m.createBackup(of: "two", now: when)
        #expect(a != b)
        #expect(try readText(a) == "one" && readText(b) == "two")
    }

    @Test func pruneKeepsNewestNAndIgnoresOtherNames() throws {
        let dir = try makeTempDir("backup")
        let m = BackupManager(directory: dir, keep: 3)
        for i in 0..<6 { _ = try m.createBackup(of: "v\(i)", now: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))) }
        try Data("keep me".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try m.prune()
        let names = backupNames(dir)
        #expect(names.count == 4 && names.contains("notes.txt"))
        let kept = try names.filter { $0 != "notes.txt" }.map { try readText(dir.appendingPathComponent($0)) }
        #expect(kept == ["v3", "v4", "v5"])
    }

    @Test func discardRemovesFile() throws {
        let dir = try makeTempDir("backup")
        let m = BackupManager(directory: dir)
        let url = try m.createBackup(of: "x")
        m.discard(url)
        #expect(backupNames(dir).isEmpty)
    }

    @Test func defaultLocationIsBuiltUnderTheSupportDirectory() throws {
        let base = try makeTempDir("support")
        let dir = BackupManager.directory(inSupportDirectory: base)
        #expect(dir.path == base.path + "/BorkHosts/backups")
        // First run: the directory does not exist yet and createBackup makes the whole path.
        let url = try BackupManager(directory: dir).createBackup(of: "x")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
