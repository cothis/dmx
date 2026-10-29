// Fail the second client F_DUPFD_CLOEXEC via the review's child-only DYLD interposer.
import Darwin
import Foundation
@testable import DMXCore
private struct Empty: Encodable, Sendable {}
private struct Owned: Decodable { let owner: String }
private struct Request: Decodable { let id: UInt64; let method: String }
private struct Reply: Encodable { let id: UInt64; let ok = true; let result: [String:String] }
@main struct RPCFaultProbe {
    static func main() async throws {
        var pair: [Int32] = [-1,-1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let fd = pair[0], other = pair[1]
        setenv("DMX_REVIEW_CLIENT_FD", String(fd), 1)
        let connection = FrameConnection(fd: fd) { _ = Darwin.close(fd) }
        let peer = FrameConnection(fd: other) { _ = Darwin.close(other) }
        defer { connection.close(); peer.close() }
        let serving = Task {
            var methods: [String] = []
            for _ in 0..<2 {
                guard let (_, bytes) = try await peer.receive() else { fatalError("missing request") }
                let req = try FrameConnection.decoder.decode(Request.self, from: bytes)
                methods.append(req.method)
                try peer.send(Reply(id: req.id, result: ["owner":req.method]))
            }
            return methods
        }
        let first: Owned = try await connection.call("first", Empty())
        precondition(first.owner == "first")
        var failed = false
        do { let _: Owned = try await connection.call("unsent", Empty()) }
        catch let error as DMXError { failed = error.code == "agent_disconnected" }
        precondition(failed && !connection.isClosed, "pre-send dup failure must preserve alignment")
        let third: Owned = try await connection.call("third", Empty())
        precondition(third.owner == "third")
        let methods = try await serving.value
        precondition(methods == ["first","third"], "no transmission or replay of failed call")
        print("real fcntl EMFILE: first succeeds, second fails before transmission, third receives its own reply; no replay")
    }
}
