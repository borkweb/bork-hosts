import Foundation

public enum AgentSocketError: Error, Equatable, LocalizedError {
    case pathTooLong
    case alreadyRunning
    case system(String)
    case unreachable
    case timedOut
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .pathTooLong: return "The socket path is too long."
        case .alreadyRunning: return "Another bork-hosts is already listening for agents."
        case let .system(message): return message
        case .unreachable: return "bork-hosts is not running, or is not accepting agent requests."
        case .timedOut: return "Timed out waiting for bork-hosts. If a macOS authentication dialog is showing, approve it and try again."
        case .badResponse: return "bork-hosts sent a reply that could not be read."
        }
    }
}

enum AgentSocketSupport {
    static let maxRequestBytes = 16 * 1024

    static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw AgentSocketError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in path.utf8.enumerated() { raw[i] = byte }
            raw[path.utf8.count] = 0
        }
        return address
    }

    static func withAddress<T>(_ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var copy = address
        return withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// A write to a connection the other side already closed must fail with an error, not kill the process.
    static func ignoreBrokenPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setTimeout(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Reads until a newline or end of input. Returns nil on timeout, error, or an oversized request.
    static func readMessage(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count <= limit {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { return nil }
            if n == 0 { break }
            data.append(chunk, count: n)
            if data.contains(10) { break }
        }
        guard data.count <= limit else { return nil }
        if let newline = data.firstIndex(of: 10) { data = data[..<newline] }
        return data
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        var offset = 0
        data.withUnsafeBytes { raw in
            while offset < data.count {
                let n = write(fd, raw.baseAddress! + offset, data.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }
}

/// Listens on a Unix socket that only the current user can reach (mode 0600, and each connection's peer is checked),
/// reads one JSON request per connection, and answers with one JSON line.
public final class AgentSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AgentRequest) async -> AgentResponse

    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BorkHosts/agent.sock").path
    }

    public let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "bork-hosts.agent-socket")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String = AgentSocketServer.defaultPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        // Belt and braces: a reply to a client that has gone away must never kill the app.
        signal(SIGPIPE, SIG_IGN)
        let address = try AgentSocketSupport.address(for: path)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // A leftover file from a crashed run is replaced; a live listener is not.
        if (try? AgentClient.connect(path: path)).map({ close($0); return true }) == true { throw AgentSocketError.alreadyRunning }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSocketError.system("Could not create the agent socket.") }
        let bound = AgentSocketSupport.withAddress(address) { bind(fd, $0, $1) }
        guard bound == 0 else { close(fd); throw AgentSocketError.system("Could not bind the agent socket: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { close(fd); unlink(path); throw AgentSocketError.system("Could not listen on the agent socket.") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
            unlink(path)
        }
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            // Set here, straight after accept: on macOS this fails once the peer has already hung up.
            AgentSocketSupport.ignoreBrokenPipe(client)
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        // Reads must not block the accept loop, and a stalled client must not hold a connection open for long.
        DispatchQueue.global().async { [handler] in
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { close(client); return }
            // An accepted socket inherits the listener's non-blocking mode on macOS; reads here must wait for the request.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            AgentSocketSupport.setTimeout(client, seconds: 5)
            // An empty read is a probe that connected and hung up (the "is another one running" check), so there is nobody to answer.
            guard let line = AgentSocketSupport.readMessage(client, limit: AgentSocketSupport.maxRequestBytes), !line.isEmpty else { close(client); return }
            guard let request = try? JSONDecoder().decode(AgentRequest.self, from: line) else {
                Self.reply(.failure("That was not a valid request."), to: client)
                return
            }
            // The request can wait on a macOS dialog, so the reply has no deadline.
            Task {
                let response = await handler(request)
                DispatchQueue.global().async { Self.reply(response, to: client) }
            }
        }
    }

    private static func reply(_ response: AgentResponse, to client: Int32) {
        defer { close(client) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(response) else { return }
        data.append(10)
        var tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        AgentSocketSupport.writeAll(client, data)
    }
}

/// The blocking client the command-line tool uses.
public enum AgentClient {
    static func connect(path: String) throws -> Int32 {
        let address = try AgentSocketSupport.address(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSocketError.system("Could not create a socket.") }
        let result = AgentSocketSupport.withAddress(address) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else { close(fd); throw AgentSocketError.unreachable }
        AgentSocketSupport.ignoreBrokenPipe(fd)
        return fd
    }

    /// Sends one request and waits up to `timeout` seconds for the reply (long enough to approve the macOS dialog).
    public static func send(_ request: AgentRequest, path: String = AgentSocketServer.defaultPath, timeout: TimeInterval = 120) throws -> AgentResponse {
        let fd = try connect(path: path)
        defer { close(fd) }
        AgentSocketSupport.setTimeout(fd, seconds: timeout)
        var data = try JSONEncoder().encode(request)
        data.append(10)
        AgentSocketSupport.writeAll(fd, data)
        guard let reply = AgentSocketSupport.readMessage(fd, limit: 1 << 20) else {
            throw errno == EAGAIN || errno == EWOULDBLOCK ? AgentSocketError.timedOut : AgentSocketError.badResponse
        }
        guard let response = try? JSONDecoder().decode(AgentResponse.self, from: reply) else { throw AgentSocketError.badResponse }
        return response
    }

    public static func isReachable(path: String = AgentSocketServer.defaultPath) -> Bool {
        guard let fd = try? connect(path: path) else { return false }
        close(fd)
        return true
    }
}
