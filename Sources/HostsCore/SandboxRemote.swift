import Foundation

/// Runs a command on the sandbox, for example one that enables writes so a session can persist.
public protocol SandboxRemoteRunning: Sendable {
    func runRemote() async -> StepOutcome
}

/// Confirms the sandbox is the one answering.
public protocol SandboxVerifying: Sendable {
    func verify() async -> StepOutcome
}

/// A command run as you, with its output. Tests replace it so nothing real runs.
public typealias UserCommandRunning = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) async throws -> (status: Int32, output: String, timedOut: Bool)

enum DefaultUserCommand {
    static let run: UserCommandRunning = { executable, arguments, timeout in
        let result = try await UserCommand.run(executable, arguments, timeout: timeout)
        return (result.status, result.stderr.isEmpty ? result.stdout : result.stdout + result.stderr, result.timedOut)
    }
}

/// Runs the write-enabling command on the sandbox with `ssh`, as you. Nothing here is elevated.
///
/// The host and command come from Settings. The host is one argument after `--`, so it cannot be read as an option;
/// the command goes to the remote shell as a person's own ssh command would.
///
/// Some sandboxes accept your key and then ask for a second factor, which only you can answer. So the app never
/// authenticates inside the switch. It runs the command over a shared connection (`ControlPath`) that is already open
/// and, when there is none, tries to open one without asking anything (`BatchMode`). If the sandbox wants a second
/// factor, it opens a Terminal window that runs the one `ssh` command that signs in, waits for you to finish there,
/// and carries on. The connection stays open for a few hours, so later runs need no sign-in. The app never sees what
/// you type in that window.
public struct SandboxSSH: SandboxRemoteRunning {
    static let timeout: TimeInterval = 60
    static let signInWait: TimeInterval = 120
    static let pollInterval: TimeInterval = 1
    static let keepOpen = "4h"

    private let preferences: @Sendable () -> SandboxPreferences
    private let run: UserCommandRunning
    private let openSignIn: @Sendable (_ script: String) async throws -> Void
    private let pause: @Sendable (TimeInterval) async -> Void
    private let controlPath: @Sendable () -> String
    private let log: @Sendable (String) -> Void

    public init(preferences: @escaping @Sendable () -> SandboxPreferences = { .load() }, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(preferences: preferences, run: DefaultUserCommand.run, openSignIn: Self.openInTerminal,
                  pause: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }, controlPath: Self.defaultControlPath, log: log)
    }

    init(preferences: @escaping @Sendable () -> SandboxPreferences, run: @escaping UserCommandRunning,
         openSignIn: @escaping @Sendable (String) async throws -> Void = { _ in },
         pause: @escaping @Sendable (TimeInterval) async -> Void = { _ in },
         controlPath: @escaping @Sendable () -> String = { "/tmp/bork-test-%C" },
         log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.preferences = preferences
        self.run = run
        self.openSignIn = openSignIn
        self.pause = pause
        self.controlPath = controlPath
        self.log = log
    }

    /// `%C` is a hash of the connection, so one host gets one socket and the path stays short.
    @Sendable
    static func defaultControlPath() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("bork-hosts-%C").path
    }

    // MARK: Arguments (pure, so they are tested)

    static func checkArguments(host: String, controlPath: String) -> [String] {
        ["-O", "check", "-o", "ControlPath=\(controlPath)", "--", host]
    }

    /// Opens the shared connection in the background. `BatchMode` makes it fail instead of asking a question.
    static func quietSignInArguments(host: String, controlPath: String) -> [String] {
        ["-fN", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ControlMaster=yes", "-o", "ControlPersist=\(keepOpen)",
         "-o", "ControlPath=\(controlPath)", "--", host]
    }

    static func commandArguments(host: String, command: String, controlPath: String) -> [String] {
        ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ControlMaster=no", "-o", "ControlPath=\(controlPath)", "--", host, command]
    }

    /// What the Terminal window runs. Values are single-quoted for `sh`; the script removes its own folder afterward.
    static func signInScript(host: String, controlPath: String) -> String {
        func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        #!/bin/sh
        printf 'bork-hosts needs you to sign in to %s. Answer any prompt below; this window can close afterward.\\n' \(quoted(host))
        /usr/bin/ssh -fN -o ControlMaster=yes -o ControlPersist=\(keepOpen) -o ControlPath=\(quoted(controlPath)) -- \(quoted(host))
        status=$?
        rm -rf "$(dirname "$0")"
        exit $status

        """
    }

    // MARK: Running

    public func runRemote() async -> StepOutcome {
        let prefs = preferences()
        guard !prefs.sshHost.trimmingCharacters(in: .whitespaces).isEmpty else { return .skipped("No sandbox ssh host is set in Settings") }
        do {
            let host = try SandboxValidation.sshHost(prefs.sshHost)
            let command = try SandboxValidation.remoteCommand(prefs.remoteCommand)
            let path = controlPath()
            log("ssh \(host): \(command)")
            if let failure = try await ensureConnection(host: host, path: path) { return failure }
            let result = try await run("/usr/bin/ssh", Self.commandArguments(host: host, command: command, controlPath: path), Self.timeout)
            log("ssh exit \(result.status), timedOut=\(result.timedOut), output: \(WriterSupport.brief(result.output))")
            if result.timedOut { return .failed("ssh to \(host) took longer than \(Int(Self.timeout)) seconds.") }
            guard result.status == 0 else {
                let detail = WriterSupport.brief(result.output)
                if detail.localizedCaseInsensitiveContains("no such file or directory") {
                    return .failed("\(detail) The ssh login directory may not be the repository: give the full path to the command in Settings, or start it with cd and the path.")
                }
                return .failed(detail.isEmpty ? "ssh to \(host) exited with status \(result.status)." : detail)
            }
            return .done
        } catch {
            log("ssh failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    /// Nil when a shared connection to the host is open, else the outcome that ends the step.
    private func ensureConnection(host: String, path: String) async throws -> StepOutcome? {
        if try await isOpen(host: host, path: path) { return nil }
        let quiet = try await run("/usr/bin/ssh", Self.quietSignInArguments(host: host, controlPath: path), 30)
        log("ssh quiet sign-in exit \(quiet.status): \(WriterSupport.brief(quiet.output))")
        if quiet.status == 0 { return nil }
        // Only a refused login is worth asking you about; an unreachable host or a bad name is not.
        guard quiet.output.localizedCaseInsensitiveContains("permission denied") else {
            let detail = WriterSupport.brief(quiet.output)
            return .failed(detail.isEmpty ? "ssh to \(host) exited with status \(quiet.status)." : detail)
        }
        try await openSignIn(Self.signInScript(host: host, controlPath: path))
        log("ssh sign-in window opened; waiting up to \(Int(Self.signInWait)) seconds")
        for _ in 0..<Int(Self.signInWait / Self.pollInterval) {
            await pause(Self.pollInterval)
            if try await isOpen(host: host, path: path) { return nil }
        }
        return .failed("Sign in to \(host) in the Terminal window that opened (answer its prompt), then switch on again. \(WriterSupport.brief(quiet.output))")
    }

    private func isOpen(host: String, path: String) async throws -> Bool {
        try await run("/usr/bin/ssh", Self.checkArguments(host: host, controlPath: path), 10).status == 0
    }

    /// Writes the script to a private folder and opens it with the default handler for `.command` files (Terminal).
    @Sendable
    static func openInTerminal(_ script: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bork-hosts-signin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("sign-in.command")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]) else {
            throw SignInError(message: "Could not write the sign-in script.")
        }
        let result = try await UserCommand.run("/usr/bin/open", [file.path])
        if result.status != 0 {
            let detail = WriterSupport.brief(result.stderr)
            throw SignInError(message: detail.isEmpty ? "Could not open Terminal." : detail)
        }
    }

    struct SignInError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}

/// Fetches the check page through the SOCKS proxy, like `curl --socks5` by hand, and looks for the expected text.
///
/// `--socks5` (not `--socks5h`) resolves the name on this Mac, so it only gets the sandbox when `/etc/hosts` says so.
/// A failure here usually means the proxy is not connected, the hosts group is not on, or a cache still holds the old
/// address.
public struct SandboxProbe: SandboxVerifying {
    private let preferences: @Sendable () -> SandboxPreferences
    private let run: UserCommandRunning
    private let log: @Sendable (String) -> Void

    public init(preferences: @escaping @Sendable () -> SandboxPreferences = { .load() }, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(preferences: preferences, run: DefaultUserCommand.run, log: log)
    }

    init(preferences: @escaping @Sendable () -> SandboxPreferences, run: @escaping UserCommandRunning,
         log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.preferences = preferences
        self.run = run
        self.log = log
    }

    public func verify() async -> StepOutcome {
        let prefs = preferences()
        let url = prefs.verifyURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return .skipped("No check page is set in Settings") }
        do {
            guard !url.hasPrefix("-") else { throw SandboxValidation.Invalid(message: "The check page cannot start with a dash.") }
            let proxy = try SandboxValidation.proxyURL(prefs.proxyURL).hostPort
            let result = try await run("/usr/bin/curl", ["-sS", "--max-time", "10", "--socks5", proxy, "--", url], 15)
            log("verify exit \(result.status): \(WriterSupport.brief(result.output))")
            let expected = prefs.verifyExpected.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status == 0, expected.isEmpty || result.output.contains(expected) { return .done }
            if result.status != 0 {
                let detail = WriterSupport.brief(result.output)
                return .failed("The check through \(proxy) failed\(detail.isEmpty ? "" : ": \(detail)"). Is the proxy connected?")
            }
            return .failed("The reply did not contain \u{201C}\(expected)\u{201D}. The host may still resolve to the real server: check the groups are on, the proxy is not routing all traffic, and wait for DNS caches to clear.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
