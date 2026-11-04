import Foundation

/// Appends timestamped lines to `~/Library/Logs/BorkHosts/sandbox.log` so a toggle that goes by too fast
/// to read can be inspected afterward. Never throws; logging must not break a toggle.
public enum SandboxLog {
    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BorkHosts", isDirectory: true)
            .appendingPathComponent("sandbox.log")
    }

    private static let lock = NSLock()
    private static let maxBytes = 256 * 1024

    @Sendable
    public static func append(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let url = fileURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Start over rather than grow without bound.
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int), size > maxBytes {
            try? fm.removeItem(at: url)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = Data("\(stamp) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}
