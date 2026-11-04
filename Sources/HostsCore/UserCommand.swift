import Foundation

/// Runs a command as the current user (no elevation) and captures its output.
enum UserCommand {
    struct Result: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
        /// True when the command ran past its time limit and was stopped.
        var timedOut = false
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// `PATH` for tools started from a GUI app, which inherits only a minimal one.
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// `timeout` stops a command that hangs, such as an ssh to a sandbox that has gone away.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil) async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = searchPath
                process.environment = environment
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                    let expired = Flag()
                    if let timeout {
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                            if process.isRunning { expired.set(); process.terminate() }
                        }
                    }
                    // Output from these commands is a few lines, well under the pipe buffer, so reading one
                    // stream to EOF and then the other cannot deadlock.
                    let outData = out.fileHandleForReading.readDataToEndOfFile()
                    let errData = err.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    cont.resume(returning: Result(status: process.terminationStatus,
                                                  stdout: String(decoding: outData, as: UTF8.self),
                                                  stderr: String(decoding: errData, as: UTF8.self),
                                                  timedOut: expired.isSet))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
