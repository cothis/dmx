import Darwin
import Foundation
import Testing
@testable import DMXCore

@Suite(.serialized) struct FrameConnectionTests {
    private final class Outcome: @unchecked Sendable {
        var error: Error?
        var frame: (FrameKind, Data)?
    }
    private final class Duplicator: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0
        let failAt: Int?
        init(failAt: Int? = nil) { self.failAt = failAt }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func copy(_ fd: Int32) -> Int32 {
            lock.lock(); calls += 1; let fail = calls == failAt; lock.unlock()
            if fail { errno = EMFILE; return -1 }
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            entered.signal()
            return copy
        }
    }
    private struct Params: Encodable, Sendable {}
    private struct Owned: Codable, Sendable { let owner: String }
    private struct Request: Decodable { let id: UInt64; let method: String }
    private struct Failure: Encodable { let code: String; let message: String }
    private struct Reply: Encodable {
        let id: UInt64; let ok: Bool; var result: Owned?; var error: Failure?
    }

    private func pair(duplicate: Duplicator? = nil) throws -> (FrameConnection, Int32) {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let fd = fds[0]
        let connection = FrameConnection(fd: fd, duplicateFD: { n in
            duplicate?.copy(n) ?? fcntl(n, F_DUPFD_CLOEXEC, 0)
        }) { _ = Darwin.close(fd) }
        return (connection, fds[1])
    }
    private func peer(_ fd: Int32) -> FrameConnection {
        FrameConnection(fd: fd) { _ = Darwin.close(fd) }
    }
    private func request(_ connection: FrameConnection) async throws -> Request {
        let frame = try #require(try await connection.receive())
        return try FrameConnection.decoder.decode(Request.self, from: frame.1)
    }
    private func assertDisconnected(_ body: () throws -> Void) {
        var code: String?
        do { try body() } catch let error as DMXError { code = error.code } catch {}
        #expect(code == "agent_disconnected")
    }

    @Test func closedConnectionRejectsNewFrames() throws {
        let (connection, fd) = try pair()
        defer { connection.close(); Darwin.close(fd) }
        connection.close()
        assertDisconnected { try connection.writeFrame(.stdin, Data([1])) }
        assertDisconnected { _ = try connection.readFrame() }
    }

    @Test func closeAloneEndsLeasedReadWhilePeerRemainsOpen() throws {
        let duplicate = Duplicator(), result = Outcome(), finished = DispatchSemaphore(value: 0)
        let (connection, fd) = try pair(duplicate: duplicate)
        defer { connection.close(); Darwin.close(fd) }
        DispatchQueue.global().async {
            do { result.frame = try connection.readFrame() } catch { result.error = error }
            finished.signal()
        }
        try #require(duplicate.entered.wait(timeout: .now() + 2) == .success)
        connection.close()
        let ended = finished.wait(timeout: .now() + 2) == .success
        #expect(ended, "close alone must end I/O on its private duplicate; peer is still open")
        // Only rescue a failing test after its assertion; do not let teardown prove the property.
        if !ended { shutdown(fd, SHUT_RDWR); _ = finished.wait(timeout: .now() + 2) }
        if ended { #expect(result.frame == nil) }
    }

    @Test func abortAloneEndsBlockedWriteWhilePeerDoesNotRead() throws {
        let duplicate = Duplicator(), result = Outcome(), finished = DispatchSemaphore(value: 0)
        let (connection, fd) = try pair(duplicate: duplicate)
        defer { connection.close(); Darwin.close(fd) }
        var size: Int32 = 4096
        // Bound the peer receive buffer without closing/reusing a descriptor number.
        // The peer never drains it. The payload exceeds the platform's normal socket buffers.
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.global().async {
            do { try connection.writeFrame(.stdin, Data(repeating: 65, count: 8 << 20)) }
            catch { result.error = error }
            finished.signal()
        }
        try #require(duplicate.entered.wait(timeout: .now() + 2) == .success)
        var byte: UInt8 = 0
        let until = Date().addingTimeInterval(2)
        while Date() < until, recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) < 0 { usleep(1000) }
        #expect(recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 1, "writer reached the socket")
        connection.abort()
        let ended = finished.wait(timeout: .now() + 2) == .success
        #expect(ended, "abort alone must end the leased write before peer-side teardown")
        if !ended { shutdown(fd, SHUT_RDWR); _ = finished.wait(timeout: .now() + 2) }
        if ended { #expect(result.error != nil) }
    }

    @Test func failedRPCLeaseSendsNothingAndKeepsReplyAlignment() async throws {
        let (connection, fd) = try pair(duplicate: Duplicator(failAt: 2)), server = peer(fd)
        defer { connection.close(); server.close() }
        let serving = Task { () throws -> [String] in
            var methods: [String] = []
            for _ in 0..<2 {
                let req = try await request(server); methods.append(req.method)
                try server.send(Reply(id: req.id, ok: true, result: Owned(owner: req.method)))
            }
            return methods
        }
        let first: Owned = try await connection.call("first", Params())
        #expect(first.owner == "first")
        do {
            let _: Owned = try await connection.call("unsent", Params())
            Issue.record("the injected descriptor acquisition must fail")
        } catch let error as DMXError { #expect(error.code == "agent_disconnected") }
        #expect(!connection.isClosed, "no request was sent, so alignment is intact")
        let third: Owned = try await connection.call("third", Params())
        #expect(third.owner == "third")
        #expect(try await serving.value == ["first", "third"], "failed call must not be transmitted or replayed")
    }

    @Test func wrongResponseIDRetiresConnection() async throws {
        let (connection, fd) = try pair(), server = peer(fd)
        defer { connection.close(); server.close() }
        let serving = Task {
            let req = try await request(server)
            try server.send(Reply(id: req.id + 1, ok: true, result: Owned(owner: "wrong")))
        }
        do {
            let _: Owned = try await connection.call("first", Params())
            Issue.record("a reply for another request must not be accepted")
        } catch let error as DMXError { #expect(error.code == "agent_protocol") }
        #expect(connection.isClosed)
        try await serving.value
    }

    @Test func applicationErrorDoesNotRetireAlignedConnection() async throws {
        let (connection, fd) = try pair(), server = peer(fd)
        defer { connection.close(); server.close() }
        let serving = Task {
            let first = try await request(server)
            try server.send(Reply(id: first.id, ok: false, error: Failure(code: "unknown_method", message: "fixture")))
            let next = try await request(server)
            try server.send(Reply(id: next.id, ok: true, result: Owned(owner: next.method)))
        }
        do { let _: Owned = try await connection.call("unknown", Params()); Issue.record("expected application error") }
        catch let error as DMXError { #expect(error.code == "agent_unknown_method") }
        #expect(!connection.isClosed)
        let next: Owned = try await connection.call("next", Params())
        #expect(next.owner == "next")
        try await serving.value
    }

    @Test func daemonApplicationErrorPreservesMessageCodeAndHint() async throws {
        var fds: [Int32] = [-1,-1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let fd = fds[0], other = fds[1]
        let connection = FrameConnection(fd: fd, peer: .daemon) { _ = Darwin.close(fd) }
        let server = peer(other)
        defer { connection.close(); server.close() }
        let serving = Task {
            let req = try await request(server)
            struct ErrorReply: Encodable {
                let id: UInt64; let ok = false
                let error = DMXError("fixture", "exec: original message", hint: "run `dmx status`")
            }
            try server.send(ErrorReply(id: req.id))
        }
        do { let _: Owned = try await connection.call("exec", Params()); Issue.record("expected daemon error") }
        catch let error as DMXError {
            #expect(error.code == "fixture")
            #expect(error.message == "exec: original message")
            #expect(error.hint == "run `dmx status`")
        }
        try await serving.value
    }

    @Test func servingLeaseFailureClosesConnection() throws {
        let (connection, fd) = try pair(duplicate: Duplicator(failAt: 1))
        defer { connection.close(); Darwin.close(fd) }
        assertDisconnected { try connection.send(Reply(id: 1, ok: true, result: Owned(owner: "unsent"))) }
        #expect(connection.isClosed, "a failed server reply cannot leave its client waiting")
    }

    @Test func malformedRPCRepliesRetireBeforeTheNextCall() async throws {
        for variant in 0..<3 {
            let (connection, fd) = try pair(), server = peer(fd)
            defer { connection.close(); server.close() }
            let serving = Task {
                _ = try await request(server)
                if variant == 2 {
                    let invalidLength: [UInt8] = [0,0,0,0]
                    #expect(invalidLength.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) } == 4)
                } else {
                    try server.writeFrame(variant == 0 ? .stdout : .json, Data("{".utf8))
                }
            }
            do { let _: Owned = try await connection.call("bad", Params()); Issue.record("expected invalid frame") }
            catch let error as DMXError { #expect(error.code == "agent_protocol") }
            #expect(connection.isClosed, "kind/JSON/framing errors must retire, not only wrong IDs")
            do { let _: Owned = try await connection.call("next", Params()); Issue.record("must reject reuse") }
            catch let error as DMXError { #expect(error.code == "agent_disconnected") }
            try await serving.value
        }
    }

    @Test func acquiredBindingControlsBothReadAndWrite() throws {
        var original: [Int32] = [-1,-1], bound: [Int32] = [-1,-1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &original) == 0)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &bound) == 0)
        let fd = original[0], boundFD = bound[0]
        // An alternate valid owned descriptor exposes using self.fd instead of the lease.
        // No descriptor is forcibly reused or closed under another test.
        let connection = FrameConnection(fd: fd, duplicateFD: { _ in fcntl(boundFD, F_DUPFD_CLOEXEC, 0) }) { _ = Darwin.close(fd) }
        defer { connection.close(); Darwin.close(original[1]); Darwin.close(bound[0]); Darwin.close(bound[1]) }
        let a: [UInt8] = [0,0,0,2,FrameKind.stdout.rawValue,1]
        let b: [UInt8] = [0,0,0,2,FrameKind.stdout.rawValue,2]
        #expect(a.withUnsafeBytes { Darwin.write(original[1], $0.baseAddress!, $0.count) } == a.count)
        #expect(b.withUnsafeBytes { Darwin.write(bound[1], $0.baseAddress!, $0.count) } == b.count)
        #expect(try connection.readFrame()?.1 == Data([2]), "read must use the acquired binding")
        try connection.writeFrame(.stdin, Data([3]))
        var bytes = [UInt8](repeating: 0, count: 6)
        #expect(recv(bound[1], &bytes, 6, MSG_DONTWAIT) == 6, "write must use the acquired binding")
        #expect(bytes == [0,0,0,2,FrameKind.stdin.rawValue,3])
        var byte: UInt8 = 0
        #expect(recv(original[1], &byte, 1, MSG_DONTWAIT) == -1 && errno == EAGAIN)
    }

    @Test func retiredControlReconnectsForNextCallWithoutReplay() async throws {
        let (first, fd1) = try pair(), peer1 = peer(fd1)
        let (fresh, fd2) = try pair(), peer2 = peer(fd2)
        let opened = Duplicator()
        let agent = AgentClient(control: first, open: { _ = opened.copy(-1); return fresh })
        defer { agent.close(); peer1.close(); peer2.close() }
        let serving1 = Task {
            let req = try await request(peer1)
            try peer1.send(Reply(id: req.id + 1, ok: true, result: Owned(owner: "invalid")))
        }
        do { let _: Owned = try await agent.call("once", Params()); Issue.record("expected invalid response") }
        catch let error as DMXError { #expect(error.code == "agent_protocol") }
        try await serving1.value
        // Yield to the MainActor opener. No call is automatically retried on the new socket.
        let until = ContinuousClock.now + .seconds(2)
        while opened.count == 0 && ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(1)) }
        try #require(opened.count == 1)
        let serving2 = Task {
            let req = try await request(peer2)
            #expect(req.method == "next", "the failed request must not be replayed")
            try peer2.send(Reply(id: req.id, ok: true, result: Owned(owner: req.method)))
        }
        // The opener records entry before returning; allow the swap to finish on MainActor.
        await MainActor.run {}
        let next: Owned = try await agent.call("next", Params())
        #expect(next.owner == "next")
        try await serving2.value
    }

    @Test func explicitAgentCloseDoesNotReconnect() async throws {
        let (connection, fd) = try pair()
        defer { Darwin.close(fd) }
        let opened = Duplicator()
        let agent = AgentClient(control: connection, open: {
            _ = opened.copy(-1)
            throw DMXError("fixture", "must not reopen")
        })
        agent.close()
        do { let _: Owned = try await agent.call("closed", Params()); Issue.record("expected closed connection") }
        catch let error as DMXError { #expect(error.code == "agent_disconnected") }
        try await Task.sleep(for: .milliseconds(30))
        #expect(opened.count == 0)
    }
}
