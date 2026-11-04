import CryptoKit
import Foundation

public enum HostsWriteError: Error, Equatable {
    case stale, cancelled, failed(String)
}

extension HostsWriteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .stale: return "The hosts file changed while it was being updated."
        case .cancelled: return "Authentication was cancelled."
        case let .failed(message): return message
        }
    }
}

public protocol HostsWriter: Sendable {
    func write(newContent: String, expectedCurrentSHA256: String) async throws
}

public func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Private helpers shared by the writers.
enum WriterSupport {
    static let contentFilePrefix = "bork-hosts-content-"

    /// Creates the content file with an unpredictable name and mode 0600, failing if it exists.
    static func createContentFile(_ content: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(contentFilePrefix)\(UUID().uuidString)")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HostsWriteError.failed("Could not create a temporary file.") }
        defer { close(fd) }
        let bytes = Array(content.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else {
                try? FileManager.default.removeItem(at: url)
                throw HostsWriteError.failed("Could not write a temporary file.")
            }
            offset += n
        }
        return url
    }

    /// Runs a process off the cooperative pool and returns its exit status and stderr.
    static func run(_ executable: String, _ arguments: [String]) async throws -> (status: Int32, stderr: String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let err = Pipe()
                process.standardError = err
                process.standardOutput = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = err.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    cont.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    static func brief(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 200 ? String(t.prefix(200)) : t
    }
}

/// Runs the apply script with `/bin/sh` and no elevation. Used by tests and integration tests.
public struct LocalScriptWriter: HostsWriter {
    let target: URL
    let flushDNS: Bool
    let tempDirectory: URL

    public init(target: URL, flushDNS: Bool = false, tempDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory())) {
        self.target = target
        self.flushDNS = flushDNS
        self.tempDirectory = tempDirectory
    }

    public func write(newContent: String, expectedCurrentSHA256: String) async throws {
        let file = try WriterSupport.createContentFile(newContent, in: tempDirectory)
        defer { try? FileManager.default.removeItem(at: file) }
        let result: (status: Int32, stderr: String)
        do {
            result = try await WriterSupport.run("/bin/sh", [
                "-c", ApplyScript.source, "sh", target.path, file.path,
                expectedCurrentSHA256, sha256Hex(newContent), flushDNS ? "1" : "0",
            ])
        } catch {
            throw HostsWriteError.failed("Could not start the write: \(error.localizedDescription)")
        }
        switch result.status {
        case 0: return
        case ApplyScript.exitStale: throw HostsWriteError.stale
        case ApplyScript.exitContentTampered: throw HostsWriteError.failed("The new content was changed before it could be written.")
        default:
            let detail = WriterSupport.brief(result.stderr)
            throw HostsWriteError.failed(detail.isEmpty ? "The write failed (exit \(result.status))." : detail)
        }
    }
}
