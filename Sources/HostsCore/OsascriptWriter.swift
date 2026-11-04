import Foundation

public enum ShellQuote {
    /// Wraps in single quotes; each `'` becomes `'\''`.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum AppleScriptString {
    /// Escapes for use inside an AppleScript string literal: backslash first, then double quote.
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Runs the apply script as root through the system authentication dialog (osascript).
/// The script is passed inline, never read from a writable file, so it cannot be swapped.
/// The app itself never sees the credential; macOS shows the dialog.
public struct OsascriptWriter: HostsWriter {
    let target: URL
    let flushDNS: Bool
    let elevated: Bool
    let tempDirectory: URL
    let osascriptPath: String

    public init(target: URL = URL(fileURLWithPath: "/etc/hosts")) {
        self.init(target: target, flushDNS: true, elevated: true,
                  tempDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), osascriptPath: "/usr/bin/osascript")
    }

    /// Test seam: `elevated: false` drops only the privilege suffix, so the same quoting runs through real osascript.
    init(target: URL, flushDNS: Bool, elevated: Bool, tempDirectory: URL, osascriptPath: String = "/usr/bin/osascript") {
        self.target = target
        self.flushDNS = flushDNS
        self.elevated = elevated
        self.tempDirectory = tempDirectory
        self.osascriptPath = osascriptPath
    }

    static func buildCommand(newContentFile: String, expectedCurrentSHA256: String, expectedNewSHA256: String,
                             target: String, flushDNS: Bool) -> String {
        let args = [target, newContentFile, expectedCurrentSHA256, expectedNewSHA256, flushDNS ? "1" : "0"]
        return "/bin/sh -c \(ShellQuote.quote(ApplyScript.source)) sh " + args.map(ShellQuote.quote).joined(separator: " ")
    }

    static func appleScript(for command: String, elevated: Bool) -> String {
        "do shell script \"\(AppleScriptString.escape(command))\"" + (elevated ? " with administrator privileges" : "")
    }

    public func write(newContent: String, expectedCurrentSHA256: String) async throws {
        let file = try WriterSupport.createContentFile(newContent, in: tempDirectory)
        defer { try? FileManager.default.removeItem(at: file) }
        let command = Self.buildCommand(newContentFile: file.path, expectedCurrentSHA256: expectedCurrentSHA256,
                                        expectedNewSHA256: sha256Hex(newContent), target: target.path, flushDNS: flushDNS)
        let result: (status: Int32, stderr: String)
        do {
            result = try await WriterSupport.run(osascriptPath, ["-e", Self.appleScript(for: command, elevated: elevated)])
        } catch {
            throw HostsWriteError.failed("Could not ask macOS for permission to write the hosts file.")
        }
        if result.status == 0 { return }
        throw Self.mapFailure(status: result.status, stderr: result.stderr)
    }

    /// osascript reports `... execution error: <message> (<code>)`. Only the trailing code counts:
    /// `-128` is "User canceled", and the script's exit 3 means the file changed underneath us.
    /// The `.failed` text is a short message without the command line, which contains the script.
    static func mapFailure(status: Int32, stderr: String) -> HostsWriteError {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = text.range(of: #"\((-?\d+)\)$"#, options: .regularExpression) else {
            return .failed(sanitized(text, code: nil))
        }
        let code = Int(text[match].dropFirst().dropLast())
        switch code {
        case -128: return .cancelled
        case 3: return .stale
        case 4: return .failed("The new content was changed before it could be written.")
        default: return .failed(sanitized(String(text[..<match.lowerBound]), code: code))
        }
    }

    private static func sanitized(_ text: String, code: Int?) -> String {
        var message = text
        if let r = message.range(of: "execution error: ") { message = String(message[r.upperBound...]) }
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic = "The hosts file could not be written" + (code.map { " (exit \($0))." } ?? ".")
        if message.isEmpty || message.contains("set -eu") || message.contains("/bin/sh -c") || message.contains("$tmp") {
            return generic
        }
        return message.count > 200 ? String(message.prefix(200)) : message
    }
}
