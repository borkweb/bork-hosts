import Foundation

/// Timestamped copies of the hosts file, written (unprivileged) before each privileged write.
public struct BackupManager: Sendable {
    let directory: URL
    let keep: Int

    public init(directory: URL, keep: Int = 20) {
        self.directory = directory
        self.keep = keep
    }

    public static var defaultDirectory: URL {
        directory(inSupportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    static func directory(inSupportDirectory base: URL) -> URL {
        base.appendingPathComponent("BorkHosts", isDirectory: true).appendingPathComponent("backups", isDirectory: true)
    }

    private static let namePattern = #"^hosts-\d{8}-\d{6}-\d{3}$"#

    private static func name(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "hosts-" + f.string(from: date)
    }

    @discardableResult
    public func createBackup(of content: String, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var date = now
        for _ in 0..<1000 {
            let url = directory.appendingPathComponent(Self.name(for: date))
            do {
                try Data(content.utf8).write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists {
                date = date.addingTimeInterval(0.001)
            }
        }
        throw CocoaError(.fileWriteUnknown)
    }

    public func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Keeps the newest `keep` backups. Only names this manager creates are ever deleted.
    public func prune() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.range(of: Self.namePattern, options: .regularExpression) != nil }
            .sorted()
        for name in names.dropLast(keep) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
