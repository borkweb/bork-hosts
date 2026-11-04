import Foundation

public enum SandboxMode: String, Sendable { case on, off }

public enum StepOutcome: Equatable, Sendable {
    case done
    /// Done, with something worth telling the user, such as a server the step could not change.
    case doneWith(note: String)
    /// Not an error: the step had nothing to do, or could not run for a known, harmless reason.
    case skipped(String)
    case failed(String)
}

/// The network half of the sandbox: the proxy bypass for the sandbox host and a DNS flush.
public protocol SandboxNetworking: Sendable {
    func apply(_ mode: SandboxMode) async -> StepOutcome
}

/// Runs a program as root. Production shares the hosts-file authorization, so one macOS dialog covers both.
public protocol PrivilegedRunning: Sendable {
    func runAsRoot(_ executable: String, _ arguments: [String]) async throws -> (status: Int32, output: String)
}

/// The `networksetup` proxy bypass list, as text in and out. Pure, so it is unit tested.
public enum ProxyBypass {
    /// Parses `networksetup -getproxybypassdomains`: one domain per line, or a sentence when the list is empty.
    public static func parse(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("There aren't any") }
    }

    /// The list with `host` last and no earlier copy of it.
    public static func adding(_ host: String, to list: [String]) -> [String] { removing(host, from: list) + [host] }

    public static func removing(_ host: String, from list: [String]) -> [String] { list.filter { $0 != host } }

    /// `networksetup` clears a list only when given the single word `Empty`.
    public static func setArguments(service: String, domains: [String]) -> [String] {
        ["-setproxybypassdomains", service] + (domains.isEmpty ? ["Empty"] : domains)
    }
}

struct MissingNetworkService: LocalizedError {
    var errorDescription: String? { "No network service is set. Enter it in Settings (for example Wi-Fi)." }
}

extension SandboxPreferences {
    /// The service from Settings. `SandboxNetwork.apply` validates it before it can reach `networksetup` as root.
    func resolvedNetworkService() throws -> String {
        let chosen = networkService.trimmingCharacters(in: .whitespaces)
        guard !chosen.isEmpty else { throw MissingNetworkService() }
        return chosen
    }
}

/// Wraps a command so it runs with both the real and the effective user ID set to root.
///
/// The privileged launcher gives the process an effective user ID of root but leaves the real one as the user, and
/// bash (and some system tools) drop or distrust that. This raises the real IDs to match, clears the environment
/// variables that change how programs start, then runs the command. It prints the IDs before and after so the log
/// shows what the launcher really gave us. (Perl is in taint mode while the IDs differ, so the arguments are matched
/// to untaint them.)
public enum RootCommand {
    static let raiseToRoot = """
    print "uid before=$< $> "; $< = $>; $( = $); print "after=$< $>\\n"; \
    $ENV{PATH} = "/usr/bin:/bin"; delete @ENV{qw(IFS CDPATH ENV BASH_ENV)}; \
    my @a = map { /^(.*)$/s; $1 } @ARGV; exec { $a[0] } @a or die "exec failed: $!\\n";
    """

    public static func launch(_ command: [String]) -> (executable: String, arguments: [String]) {
        ("/usr/bin/perl", ["-e", raiseToRoot] + command)
    }
}

/// Adds or removes the sandbox host from the proxy bypass list, then flushes the DNS cache.
///
/// The API group already owns the host's `/etc/hosts` line. With the host in the bypass list the browser resolves it
/// locally, so `/etc/hosts` applies, instead of letting the SOCKS proxy resolve it remotely. The bypass is changed as root through the shared authorization; the
/// list is read as the user, and re-read afterward to confirm the change took effect. The service and host come from
/// Settings and are validated first.
public struct SandboxNetwork: SandboxNetworking {
    private let runner: PrivilegedRunning
    private let resolveService: @Sendable () throws -> String
    private let host: @Sendable () -> String
    private let readBypass: @Sendable (String) async throws -> [String]
    private let log: @Sendable (String) -> Void

    public init(runner: PrivilegedRunning, preferences: @escaping @Sendable () -> SandboxPreferences = { .load() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(runner: runner, resolveService: { try preferences().resolvedNetworkService() },
                  host: { preferences().bypassHost }, readBypass: Self.readBypassList, log: log)
    }

    init(runner: PrivilegedRunning, resolveService: @escaping @Sendable () throws -> String,
         host: @escaping @Sendable () -> String = { "api.example.com" },
         readBypass: @escaping @Sendable (String) async throws -> [String], log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.runner = runner
        self.resolveService = resolveService
        self.host = host
        self.readBypass = readBypass
        self.log = log
    }

    public func apply(_ mode: SandboxMode) async -> StepOutcome {
        do {
            guard !self.host().trimmingCharacters(in: .whitespaces).isEmpty else { return .skipped("No proxy bypass host is set in Settings") }
            let host = try SandboxValidation.bypassHost(self.host())
            let service = try SandboxValidation.networkService(resolveService())
            let current = try await readBypass(service)
            let desired = mode == .on ? ProxyBypass.adding(host, to: current) : ProxyBypass.removing(host, from: current)
            log("proxy bypass on \(service): \(current) -> \(desired)")
            if desired != current {
                let result = try await runRoot(["/usr/sbin/networksetup"] + ProxyBypass.setArguments(service: service, domains: desired))
                if result.status != 0 { return .failed(Self.describe("networksetup", result)) }
            }
            let after = try await readBypass(service)
            guard after.contains(host) == (mode == .on) else {
                return .failed("The proxy bypass list on \(service) did not change.")
            }
            let flush = try await runRoot(["/bin/sh", "-c", "/usr/bin/dscacheutil -flushcache && { /usr/bin/killall -HUP mDNSResponder || true; }"])
            if flush.status != 0 { return .failed(Self.describe("DNS flush", flush)) }
            return .done
        } catch {
            log("proxy bypass failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    private func runRoot(_ command: [String]) async throws -> (status: Int32, output: String) {
        let launch = RootCommand.launch(command)
        let result = try await runner.runAsRoot(launch.executable, launch.arguments)
        log("\(command.first ?? ""): exit \(result.status), output: \(WriterSupport.brief(result.output))")
        return result
    }

    private static func describe(_ what: String, _ result: (status: Int32, output: String)) -> String {
        let detail = WriterSupport.brief(result.output)
        return detail.isEmpty ? "\(what) exited with status \(result.status)." : detail
    }

    @Sendable
    static func readBypassList(service: String) async throws -> [String] {
        let result = try await UserCommand.run("/usr/sbin/networksetup", ["-getproxybypassdomains", service])
        guard result.status == 0 else {
            let detail = WriterSupport.brief(result.stderr.isEmpty ? result.stdout : result.stderr)
            throw ReadError(message: detail.isEmpty ? "Could not read the proxy bypass list for \(service)." : detail)
        }
        return ProxyBypass.parse(result.stdout)
    }

    struct ReadError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}
