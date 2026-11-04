import Foundation
import Security

/// Runs the apply script as root using one macOS authorization that the app keeps while it runs.
///
/// macOS gives the system "run as root" right a built-in timeout (300 seconds). Because this writer
/// reuses a single `AuthorizationRef`, you authenticate once and later writes inside that window
/// run without another prompt, the way sudo's grace period works. The window is set by macOS and counts
/// from when you authenticated. Quitting the app destroys the authorization.
///
/// The script is passed inline to `/bin/sh` (never from a writable file), and the app never sees the
/// credential: macOS shows the dialog. `AuthorizationExecuteWithPrivileges` is deprecated by Apple, so it
/// is looked up at runtime; `OsascriptWriter` remains as an alternative behind the same protocol.
public final class AuthorizationWriter: HostsWriter, PrivilegedRunning, @unchecked Sendable {
    typealias ExecuteFunction = @convention(c) (
        AuthorizationRef, UnsafePointer<CChar>, AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    struct Invocation: Equatable {
        var tool: String
        var arguments: [String]
    }

    /// Printed after the script finishes. `AuthorizationExecuteWithPrivileges` does not return an exit
    /// status, so the outer shell appends one to the output stream.
    static let exitMarker = "bork-exit:"
    /// Both shells run with `-p` so they keep root if the privileged launcher sets only the effective user ID;
    /// without it, sh resets to the real user and every write would fail.
    static let wrapper = "/bin/sh -p -c \"$1\" sh \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" 2>&1; echo \"\(exitMarker)$?\""

    /// For `runAsRoot`: `"$@"` is the program and its arguments, then the exit marker, with stderr merged into stdout.
    static let commandWrapper = "\"$@\" 2>&1; echo \"\(exitMarker)$?\""

    private let target: URL
    private let flushDNS: Bool
    private let tempDirectory: URL
    private let queue = DispatchQueue(label: "bork-hosts.authorization-writer")
    private var authorization: AuthorizationRef?

    public convenience init(target: URL = URL(fileURLWithPath: "/etc/hosts")) {
        self.init(target: target, flushDNS: true, tempDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
    }

    init(target: URL, flushDNS: Bool, tempDirectory: URL) {
        self.target = target
        self.flushDNS = flushDNS
        self.tempDirectory = tempDirectory
    }

    deinit {
        if let authorization { AuthorizationFree(authorization, [.destroyRights]) }
    }

    // MARK: Pure helpers (unit tested)

    static func invocation(newContentFile: String, expectedCurrentSHA256: String, expectedNewSHA256: String,
                           target: String, flushDNS: Bool) -> Invocation {
        Invocation(tool: "/bin/sh", arguments: [
            "-p", "-c", wrapper, "sh", ApplyScript.source, target, newContentFile,
            expectedCurrentSHA256, expectedNewSHA256, flushDNS ? "1" : "0",
        ])
    }

    /// Finds the last `bork-exit:<n>` line. Everything before it is the script's own output.
    static func parseOutcome(_ output: String) -> (status: Int32, detail: String)? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let index = lines.lastIndex(where: { $0.hasPrefix(exitMarker) }),
              let status = Int32(lines[index].dropFirst(exitMarker.count).trimmingCharacters(in: .whitespaces))
        else { return nil }
        let detail = lines[..<index].joined(separator: "\n")
        return (status, detail.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `nil` means success.
    static func mapOutcome(status: Int32, detail: String) -> HostsWriteError? {
        switch status {
        case 0: return nil
        case ApplyScript.exitStale: return .stale
        case ApplyScript.exitContentTampered: return .failed("The new content was changed before it could be written.")
        default:
            let generic = "The hosts file could not be written (exit \(status))."
            if detail.isEmpty || detail.contains("set -eu") || detail.contains("/bin/sh -c") || detail.contains("$tmp") {
                return .failed(generic)
            }
            return .failed(WriterSupport.brief(detail))
        }
    }

    static func mapAuthorizationStatus(_ status: OSStatus) -> HostsWriteError {
        switch status {
        case errAuthorizationCanceled: return .cancelled
        case errAuthorizationDenied: return .failed("macOS did not grant permission to edit the hosts file.")
        case errAuthorizationInteractionNotAllowed: return .failed("macOS could not show the authentication dialog.")
        default: return .failed("macOS could not authorize the write (code \(status)).")
        }
    }

    static func executeFunction() -> ExecuteFunction? {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "AuthorizationExecuteWithPrivileges") else { return nil }
        return unsafeBitCast(symbol, to: ExecuteFunction.self)
    }

    // MARK: Writing

    public func write(newContent: String, expectedCurrentSHA256: String) async throws {
        let file = try WriterSupport.createContentFile(newContent, in: tempDirectory)
        defer { try? FileManager.default.removeItem(at: file) }
        let invocation = Self.invocation(newContentFile: file.path, expectedCurrentSHA256: expectedCurrentSHA256,
                                         expectedNewSHA256: sha256Hex(newContent), target: target.path, flushDNS: flushDNS)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                continuation.resume(with: Result { try self.runPrivileged(invocation) })
            }
        }
    }

    /// Runs any program as root under the same authorization as the hosts-file write, so one macOS dialog covers both.
    /// The program and its arguments are passed to a root `sh` as separate parameters, never joined into a command string.
    public func runAsRoot(_ executable: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        let invocation = Invocation(tool: "/bin/sh", arguments: ["-p", "-c", Self.commandWrapper, "sh", executable] + arguments)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(status: Int32, output: String), Error>) in
            queue.async {
                continuation.resume(with: Result {
                    let output = try self.executePrivileged(invocation)
                    guard let outcome = Self.parseOutcome(output) else { throw HostsWriteError.failed("The command did not report a result.") }
                    return (outcome.status, outcome.detail)
                })
            }
        }
    }

    private func runPrivileged(_ invocation: Invocation) throws {
        let output = try executePrivileged(invocation)
        guard let outcome = Self.parseOutcome(output) else {
            throw HostsWriteError.failed("The write did not report a result.")
        }
        if let error = Self.mapOutcome(status: outcome.status, detail: outcome.detail) { throw error }
    }

    /// Returns everything the privileged process printed, including the trailing exit marker line.
    private func executePrivileged(_ invocation: Invocation) throws -> String {
        guard let execute = Self.executeFunction() else {
            throw HostsWriteError.failed("This version of macOS no longer supports the privileged write used by this app.")
        }
        let ref = try currentAuthorization()
        try requestAdminRight(ref)

        var cStrings: [UnsafeMutablePointer<CChar>?] = invocation.arguments.map { strdup($0) }
        defer { for pointer in cStrings { free(pointer) } }
        cStrings.append(nil)

        var pipe: UnsafeMutablePointer<FILE>?
        let status = cStrings.withUnsafeBufferPointer { buffer in
            execute(ref, invocation.tool, [], buffer.baseAddress, &pipe)
        }
        guard status == errAuthorizationSuccess else { throw Self.mapAuthorizationStatus(status) }
        guard let pipe else { throw HostsWriteError.failed("The command did not report a result.") }

        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = fread(&chunk, 1, chunk.count, pipe)
            if count <= 0 { break }
            output.append(chunk, count: count)
        }
        fclose(pipe)
        return String(decoding: output, as: UTF8.self)
    }

    private func currentAuthorization() throws -> AuthorizationRef {
        if let authorization { return authorization }
        var created: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &created)
        guard status == errAuthorizationSuccess, let created else { throw Self.mapAuthorizationStatus(status) }
        authorization = created
        return created
    }

    /// Asks macOS for the admin right. Inside the system timeout this returns without a dialog.
    private func requestAdminRight(_ ref: AuthorizationRef) throws {
        let promptText = "bork-hosts needs to update \(target.path)."
        let status: OSStatus = kAuthorizationRightExecute.withCString { rightName in
            kAuthorizationEnvironmentPrompt.withCString { promptName in
                promptText.withCString { promptValue in
                    var right = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
                    var promptItem = AuthorizationItem(name: promptName, valueLength: strlen(promptValue),
                                                       value: UnsafeMutableRawPointer(mutating: promptValue), flags: 0)
                    return withUnsafeMutablePointer(to: &right) { rightPointer in
                        withUnsafeMutablePointer(to: &promptItem) { promptPointer in
                            var rights = AuthorizationRights(count: 1, items: rightPointer)
                            var environment = AuthorizationEnvironment(count: 1, items: promptPointer)
                            let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
                            return AuthorizationCopyRights(ref, &rights, &environment, flags, nil)
                        }
                    }
                }
            }
        }
        guard status == errAuthorizationSuccess else { throw Self.mapAuthorizationStatus(status) }
    }
}
