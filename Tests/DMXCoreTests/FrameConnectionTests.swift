import Darwin
import Foundation
import Testing
@testable import DMXCore

@Suite(.serialized) struct FrameConnectionTests {
    private final class ReadResult: @unchecked Sendable {
        // Written before signaling, read only after waiting on the semaphore.
        var frame: (FrameKind, Data)?
    }

    private func socketPair() throws -> [Int32] {
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        for fd in fds {
            var on: Int32 = 1
            #expect(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0)
        }
        return fds
    }

    /// Force Close -> OS reuse -> stale I/O without relying on a lucky thread schedule.
    private func withReusedDescriptor(_ body: (FrameConnection, Int32, Int32) throws -> Void) throws {
        let original = try socketPair(), victim = try socketPair()
        let fd = original[0]
        let connection = FrameConnection(fd: fd) { _ = Darwin.close(fd) }
        connection.close()
        defer {
            connection.close() // must not close the reused number a second time
            Darwin.close(fd)
            Darwin.close(original[1])
            Darwin.close(victim[0])
            Darwin.close(victim[1])
        }
        #expect(dup2(victim[0], fd) == fd)
        try body(connection, fd, victim[1])
    }

    @Test func closedWriterCannotSendToReusedDescriptor() throws {
        try withReusedDescriptor { connection, _, victimPeer in
            let secret = Data("old-connection-secret".utf8)
            var rejected = false
            do { try connection.writeFrame(.stdin, secret) }
            catch let error as DMXError { rejected = error.code == "agent_disconnected" }
            #expect(rejected, "a closed connection must reject a late frame writer")
            var bytes = [UInt8](repeating: 0, count: 128)
            let received = recv(victimPeer, &bytes, bytes.count, MSG_DONTWAIT)
            #expect(received == -1 && errno == EAGAIN, "the unrelated socket must receive no bytes")
        }
    }

    @Test func closedReaderCannotConsumeFromReusedDescriptor() throws {
        try withReusedDescriptor { connection, reused, victimPeer in
            // A complete, valid stdout frame belonging to the new connection.
            let frame: [UInt8] = [0, 0, 0, 4, FrameKind.stdout.rawValue, 10, 20, 30]
            #expect(frame.withUnsafeBytes { write(victimPeer, $0.baseAddress!, $0.count) } == frame.count)
            var rejected = false
            do { _ = try connection.readFrame() }
            catch let error as DMXError { rejected = error.code == "agent_disconnected" }
            #expect(rejected, "a closed connection must reject a late frame reader")
            var bytes = [UInt8](repeating: 0, count: frame.count)
            let remaining = recv(reused, &bytes, bytes.count, MSG_PEEK | MSG_DONTWAIT)
            #expect(remaining == frame.count, "the new connection's frame must remain unread")
        }
    }

    @Test func frameKeepsItsSocketAcrossCloseBetweenHeaderAndBody() throws {
        let original = try socketPair(), victim = try socketPair()
        let fd = original[0]
        let connection = FrameConnection(fd: fd) { _ = Darwin.close(fd) }
        let finished = DispatchSemaphore(value: 0), result = ReadResult()
        defer {
            connection.close()
            Darwin.close(fd)
            Darwin.close(original[1])
            Darwin.close(victim[0])
            Darwin.close(victim[1])
        }
        let header: [UInt8] = [0, 0, 0, 4]
        #expect(header.withUnsafeBytes { write(original[1], $0.baseAddress!, $0.count) } == header.count)
        DispatchQueue.global().async {
            result.frame = try? connection.readFrame()
            finished.signal()
        }
        // Observe that the real reader consumed the header; no delay injected into production.
        var consumed = false, byte: UInt8 = 0
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) < 0 && errno == EAGAIN {
                consumed = true
                break
            }
            usleep(1000)
        }
        #expect(consumed, "the reader must reach the header/body boundary")
        connection.close()
        #expect(dup2(victim[0], fd) == fd)
        let body: [UInt8] = [FrameKind.stdout.rawValue, 10, 20, 30]
        #expect(body.withUnsafeBytes { write(victim[1], $0.baseAddress!, $0.count) } == body.count)
        // Wake an old poll already inside the kernel; its next read must not use the new socket.
        shutdown(original[1], SHUT_RDWR)
        let ended = finished.wait(timeout: .now() + 2) == .success
        if !ended {
            shutdown(victim[0], SHUT_RDWR)
            _ = finished.wait(timeout: .now() + 2)
        }
        #expect(ended, "close must finish the pending read")
        if ended { #expect(result.frame == nil, "one frame must never mix two connections") }
        var bytes = [UInt8](repeating: 0, count: body.count)
        let remaining = recv(victim[0], &bytes, bytes.count, MSG_PEEK | MSG_DONTWAIT)
        #expect(remaining == body.count, "the unrelated socket's body must remain unread")
    }
}
