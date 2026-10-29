import CryptoKit
import Darwin
import Foundation
@testable import DMXCore

struct ReviewEmpty: Encodable, Sendable {}
struct ReviewOwned: Decodable, Sendable { let owner: String }
struct ReviewReply: Encodable { let id: Int; let ok: Bool; let result: [String: String] }
@main struct ReviewReproduction {
    static func main() async throws {
        if CommandLine.arguments[1] == "emfile" {
            var pair: [Int32] = [-1, -1]
            precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            let fd = pair[0], other = pair[1]
            setenv("DMX_REVIEW_CLIENT_FD", String(fd), 1)
            let client = FrameConnection(fd: fd) { _ = Darwin.close(fd) }
            let peer = FrameConnection(fd: other) { _ = Darwin.close(other) }
            let agent = AgentClient(control: client, open: { throw DMXError("unexpected_reconnect", "fixture did not expect reconnection") })
            defer { client.close(); peer.close() }
            let server = Task {
                for _ in 0..<2 {
                    guard let (_, bytes) = try await peer.receive(),
                          let request = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                          let id = request["id"] as? Int, let method = request["method"] as? String else { fatalError("bad fixture request") }
                    try peer.send(ReviewReply(id: id, ok: true, result: ["owner": method]))
                }
            }
            do {
                let first: ReviewOwned = try await agent.call("first", ReviewEmpty())
                print("first returned: \(first.owner)")
            } catch let error as DMXError { print("first failed: \(error.code): \(error.message)") }
            let second: ReviewOwned = try await agent.call("second", ReviewEmpty())
            try await server.value
            print("second request expected owner=second; observed owner=\(second.owner)")
            guard second.owner == "second" else { exit(1) }
        } else if CommandLine.arguments[1] == "equal-archive" {
            let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dmx-opus-receipt-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: home) }
            let paths = Paths(environment: ["DMX_HOME": home.path])
            try FileManager.default.createDirectory(at: paths.guest, withIntermediateDirectories: true)
            var files: [String: String] = [:]
            for (name, body) in [("Image", "kernel"), ("initramfs.gz", "initramfs"), ("docker.img", "docker"), ("manifest.json", #"{"kernel":"review-fixture"}"#)] {
                let data = Data(body.utf8)
                try data.write(to: paths.guest.appendingPathComponent(name))
                files[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            let old = GuestRelease(tag: "v1", archive: "guest.tar.gz", bytes: 1, sha256: String(repeating: "a", count: 64), files: files)
            let target = GuestRelease(tag: "v2", archive: "guest.tar.gz", bytes: 1, sha256: old.sha256, files: files)
            let store = GuestStore(paths: paths, pin: target, environment: ["DMX_RELEASE_URL": "http://127.0.0.1:1"])
            try store.writeReceipt(old)
            try await store.ensure { print($0) }
            print("binary version: \(dmxVersion); expected tag: v2; observed tag: \(store.state().tag ?? "nil")")
            guard store.state().tag == "v2" else { exit(1) }
        } else {
            var original: [Int32] = [-1, -1], victim: [Int32] = [-1, -1]
            precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &original) == 0)
            precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &victim) == 0)
            let fd = original[0]
            let connection = FrameConnection(fd: fd) { _ = Darwin.close(fd) }
            connection.close() // the actual test helper's close -> dup2 gap starts here
            let path = NSTemporaryDirectory() + "dmx-opus-fd-\(UUID().uuidString)"
            let interloper = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
            defer {
                Darwin.close(fd); Darwin.close(original[1]); Darwin.close(victim[0]); Darwin.close(victim[1]); unlink(path)
            }
            precondition(interloper == fd, "fixture must force an unrelated opener to reuse the retired number")
            precondition(dup2(victim[0], fd) == fd) // unchanged test helper's next syscall
            var attributes = stat()
            precondition(fstat(interloper, &attributes) == 0)
            let stillFile = attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            print("FrameConnectionTests helper schedule: close -> unrelated open -> dup2")
            print("expected unrelated fd to remain a regular file; observed socket: \(attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK))")
            guard stillFile else { exit(1) }
        }
    }
}
