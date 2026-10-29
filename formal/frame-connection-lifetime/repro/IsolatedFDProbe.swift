// Destructive descriptor reuse belongs in this single-purpose child, never the unit runner.
import Darwin
import Foundation
@testable import DMXCore
private final class ReadResult: @unchecked Sendable { var frame: (FrameKind, Data)? }
@main struct IsolatedFDProbe {
    static func pair() -> [Int32] {
        var fds: [Int32] = [-1,-1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return fds
    }
    static func main() throws {
        let original = pair(), victim = pair(), fd = original[0]
        let mode = CommandLine.arguments[1]
        let connection = FrameConnection(fd: fd, duplicateFD: { n in
            let copy = fcntl(n, F_DUPFD_CLOEXEC, 0)
            if mode == "gated" { setenv("DMX_GATE_COPY", String(copy), 1) }
            return copy
        }) { _ = Darwin.close(fd) }
        if mode == "gated" {
            var notify: [Int32] = [-1,-1], release: [Int32] = [-1,-1]
            precondition(pipe(&notify) == 0 && pipe(&release) == 0)
            setenv("DMX_GATE_ORIGINAL", String(fd), 1)
            setenv("DMX_GATE_NOTIFY", String(notify[1]), 1)
            setenv("DMX_GATE_RELEASE", String(release[0]), 1)
            let header: [UInt8] = [0,0,0,4]
            precondition(header.withUnsafeBytes { write(original[1], $0.baseAddress!, $0.count) } == 4)
            let result = ReadResult(), done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { result.frame = try? connection.readFrame(); done.signal() }
            var byte: UInt8 = 0
            precondition(read(notify[0], &byte, 1) == 1, "interposer paused before body poll")
            connection.close()
            precondition(dup2(victim[0], fd) == fd)
            let body: [UInt8] = [FrameKind.stdout.rawValue,10,20,30]
            precondition(body.withUnsafeBytes { write(victim[1], $0.baseAddress!, $0.count) } == 4)
            precondition(write(release[1], &byte, 1) == 1)
            precondition(done.wait(timeout: .now()+2) == .success, "close ends gated read")
            precondition(result.frame == nil, "cannot splice a frame from two sockets")
            var bytes = [UInt8](repeating: 0, count: 4)
            precondition(recv(victim[0], &bytes, 4, MSG_PEEK | MSG_DONTWAIT) == 4, "foreign body remains unread")
        } else if mode == "midframe" {
            let header: [UInt8] = [0,0,0,4]
            precondition(header.withUnsafeBytes { write(original[1], $0.baseAddress!, $0.count) } == 4)
            let result = ReadResult(), done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { result.frame = try? connection.readFrame(); done.signal() }
            var byte: UInt8 = 0, consumed = false
            let until = Date().addingTimeInterval(2)
            while Date() < until {
                if recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) < 0 && errno == EAGAIN { consumed = true; break }
                usleep(1000)
            }
            precondition(consumed, "reader reached header/body boundary")
            connection.close()
            precondition(dup2(victim[0], fd) == fd)
            let body: [UInt8] = [FrameKind.stdout.rawValue,10,20,30]
            precondition(body.withUnsafeBytes { write(victim[1], $0.baseAddress!, $0.count) } == 4)
            // Assert before touching the old peer: shutdown here would mask a missing wakeup.
            precondition(done.wait(timeout: .now()+2) == .success, "close alone must finish read")
            precondition(result.frame == nil, "cannot splice a frame from two sockets")
            var bytes = [UInt8](repeating: 0, count: 4)
            precondition(recv(victim[0], &bytes, 4, MSG_PEEK | MSG_DONTWAIT) == 4, "foreign body remains unread")
        } else {
            connection.close()
            precondition(dup2(victim[0], fd) == fd)
            var rejected = false
            if mode == "write" {
                do { try connection.writeFrame(.stdin, Data([1,2,3])) }
                catch let error as DMXError { rejected = error.code == "agent_disconnected" }
                var byte: UInt8 = 0
                precondition(recv(victim[1], &byte, 1, MSG_DONTWAIT) == -1 && errno == EAGAIN, "no foreign write")
            } else {
                let frame: [UInt8] = [0,0,0,4,FrameKind.stdout.rawValue,10,20,30]
                precondition(frame.withUnsafeBytes { write(victim[1], $0.baseAddress!, $0.count) } == 8)
                do { _ = try connection.readFrame() }
                catch let error as DMXError { rejected = error.code == "agent_disconnected" }
                var bytes = [UInt8](repeating: 0, count: 8)
                precondition(recv(fd, &bytes, 8, MSG_PEEK | MSG_DONTWAIT) == 8, "no foreign read")
            }
            precondition(rejected, "closed connection must reject acquisition")
        }
        connection.close() // idempotent close must leave the child's deliberately reused slot open.
        precondition(fcntl(fd, F_GETFD) >= 0)
        print("isolated descriptor probe passed: \(mode)")
        // Child exit owns cleanup. No other suite shares this descriptor namespace.
    }
}
