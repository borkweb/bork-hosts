import Foundation

/// JSON persistence of the sidebar. `load` never creates anything, so launching the app is read-only.
public struct GroupStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static var defaultURL: URL {
        url(inSupportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    static func url(inSupportDirectory base: URL) -> URL {
        base.appendingPathComponent("BorkHosts", isDirectory: true).appendingPathComponent("groups.json")
    }

    public func load() throws -> [HostGroup] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([HostGroup].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ groups: [HostGroup]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(groups).write(to: fileURL, options: .atomic)
    }
}
