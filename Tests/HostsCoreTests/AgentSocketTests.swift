import Foundation
import Testing
@testable import HostsCore

/// Unix socket paths are limited to about 100 bytes, and the usual temp directory is too long once a UUID is added.
func shortSocketPath() throws -> String {
    let dir = "/tmp/bk-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/a.sock"
}

struct AgentSocketTests {
    func echo() -> AgentSocketServer.Handler {
        { request in AgentResponse(ok: true, message: "got \(request.cmd) \(request.name ?? "")") }
    }

    @Test func aRequestRoundTrips() async throws {
        let path = try shortSocketPath()
        let server = AgentSocketServer(path: path, handler: echo())
        try server.start()
        defer { server.stop() }
        let response = try AgentClient.send(AgentRequest(cmd: "group", name: "x y"), path: path, timeout: 5)
        #expect(response == AgentResponse(ok: true, message: "got group x y"))
    }

    @Test func theSocketIsPrivateToTheUser() throws {
        let path = try shortSocketPath()
        let server = AgentSocketServer(path: path, handler: echo())
        try server.start()
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func aStaleSocketFileIsReplaced() async throws {
        let path = try shortSocketPath()
        FileManager.default.createFile(atPath: path, contents: Data())
        let server = AgentSocketServer(path: path, handler: echo())
        try server.start()
        defer { server.stop() }
        #expect(try AgentClient.send(AgentRequest(cmd: "status"), path: path, timeout: 5).ok)
    }

    @Test func aSecondServerOnALivePathIsRefused() throws {
        let path = try shortSocketPath()
        let first = AgentSocketServer(path: path, handler: echo())
        try first.start()
        defer { first.stop() }
        #expect(throws: AgentSocketError.alreadyRunning) { try AgentSocketServer(path: path, handler: echo()).start() }
        #expect(AgentClient.isReachable(path: path), "the first server must still be there")
    }

    @Test func stoppingRemovesTheSocketFile() throws {
        let path = try shortSocketPath()
        let server = AgentSocketServer(path: path, handler: echo())
        try server.start()
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!AgentClient.isReachable(path: path))
    }

    @Test func nothingListeningIsUnreachable() throws {
        let path = try shortSocketPath()
        #expect(throws: AgentSocketError.unreachable) { try AgentClient.send(AgentRequest(cmd: "status"), path: path, timeout: 1) }
    }

    @Test func garbageGetsAnErrorReplyNotACrash() async throws {
        let path = try shortSocketPath()
        let server = AgentSocketServer(path: path, handler: echo())
        try server.start()
        defer { server.stop() }
        let fd = try AgentClient.connect(path: path)
        defer { close(fd) }
        AgentSocketSupport.setTimeout(fd, seconds: 5)
        AgentSocketSupport.writeAll(fd, Data("this is not json\n".utf8))
        let line = try #require(AgentSocketSupport.readMessage(fd, limit: 4096))
        let response = try JSONDecoder().decode(AgentResponse.self, from: line)
        #expect(!response.ok)
        #expect(try AgentClient.send(AgentRequest(cmd: "status"), path: path, timeout: 5).ok, "the server keeps working")
    }

    @Test func anOversizedRequestIsDropped() async throws {
        let path = try shortSocketPath()
        let server = AgentSocketServer(path: path, handler: echo())
        try server.start()
        defer { server.stop() }
        let fd = try AgentClient.connect(path: path)
        defer { close(fd) }
        AgentSocketSupport.setTimeout(fd, seconds: 5)
        AgentSocketSupport.writeAll(fd, Data(repeating: 65, count: AgentSocketSupport.maxRequestBytes * 2))
        #expect(AgentSocketSupport.readMessage(fd, limit: 4096)?.isEmpty ?? true, "no reply is sent for an oversized request")
        #expect(try AgentClient.send(AgentRequest(cmd: "status"), path: path, timeout: 5).ok, "the server keeps working")
    }

    @Test func aSlowHandlerStillGetsItsReply() async throws {
        let path = try shortSocketPath()
        let server = AgentSocketServer(path: path) { _ in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return AgentResponse(ok: true, message: "slow")
        }
        try server.start()
        defer { server.stop() }
        #expect(try AgentClient.send(AgentRequest(cmd: "status"), path: path, timeout: 5).message == "slow")
    }

    @Test func aReplyThatNeverComesTimesOut() async throws {
        let path = try shortSocketPath()
        let server = AgentSocketServer(path: path) { _ in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return AgentResponse(ok: true, message: "late")
        }
        try server.start()
        defer { server.stop() }
        #expect(throws: AgentSocketError.timedOut) { try AgentClient.send(AgentRequest(cmd: "status"), path: path, timeout: 0.5) }
    }

    @Test func pathsTooLongForASocketAreRefused() throws {
        let long = "/tmp/" + String(repeating: "a", count: 200) + "/s.sock"
        #expect(throws: AgentSocketError.pathTooLong) { try AgentSocketServer(path: long, handler: echo()).start() }
    }
}
