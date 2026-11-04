import Foundation
import Testing
@testable import HostsCore

struct GroupStoreTests {
    @Test func loadMissingFileReturnsEmptyAndCreatesNothing() throws {
        let dir = try makeTempDir()
        let sub = dir.appendingPathComponent("nope/deeper")
        let store = GroupStore(fileURL: sub.appendingPathComponent("groups.json"))
        #expect(try store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("nope").path))
    }

    @Test func saveThenLoadRoundTripsIdsAndOrder() throws {
        let dir = try makeTempDir()
        let store = GroupStore(fileURL: dir.appendingPathComponent("groups.json"))
        let groups = [
            HostGroup(name: "Z", lines: [HostLine(ip: "1.1.1.1", hostname: "z.com")]),
            HostGroup(name: "A", lines: [HostLine(ip: "::1", hostname: "a.com"), HostLine(ip: "2.2.2.2", hostname: "b.com")]),
        ]
        try store.save(groups)
        #expect(try store.load() == groups)
    }

    @Test func saveCreatesIntermediateDirectories() throws {
        let dir = try makeTempDir()
        let store = GroupStore(fileURL: dir.appendingPathComponent("a/b/c/groups.json"))
        try store.save([])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a/b/c/groups.json").path))
    }

    @Test func saveIsAtomic() throws {
        let dir = try makeTempDir()
        let store = GroupStore(fileURL: dir.appendingPathComponent("groups.json"))
        try store.save([HostGroup(name: "A", lines: [])])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["groups.json"])
    }

    @Test func loadCorruptJSONThrowsAndLeavesFile() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("groups.json")
        let junk = Data("{not json".utf8)
        try junk.write(to: url)
        #expect(throws: (any Error).self) { try GroupStore(fileURL: url).load() }
        #expect(try Data(contentsOf: url) == junk)
    }

    @Test func defaultLocationIsBuiltUnderTheSupportDirectory() throws {
        let base = try makeTempDir("support")
        let url = GroupStore.url(inSupportDirectory: base)
        #expect(url.path == base.path + "/BorkHosts/groups.json")
        let store = GroupStore(fileURL: url)
        #expect(try store.load().isEmpty, "first run with no BorkHosts folder")
        try store.save([HostGroup(name: "A", lines: [])])
        #expect(try store.load().count == 1)
    }
}
