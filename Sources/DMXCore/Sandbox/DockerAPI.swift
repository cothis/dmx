import Foundation

/// A byte stream to dockerd: a Unix socket to `~/.dmx/docker.sock` on the host, or an agent
/// `connect` stream inside the daemon. Closing it closes the descriptor.
final class DockerStream: @unchecked Sendable {
    let fd: Int32
    private let onClose: @Sendable () -> Void
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32, onClose: @escaping @Sendable () -> Void) {
        self.fd = fd
        self.onClose = onClose
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            onClose()
        }
    }

    /// Wakes a blocked read from another task without closing the descriptor.
    func shutdown() {
        lock.withLock { if !closed { _ = Darwin.shutdown(fd, SHUT_RDWR) } }
    }

    /// Tells dockerd the input is done.
    func shutdownWrite() {
        lock.withLock { if !closed { _ = Darwin.shutdown(fd, SHUT_WR) } }
    }

    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw DMXError("docker_failed", "write to dockerd: \(String(cString: strerror(errno)))") }
                offset += n
            }
        }
    }

    /// Up to `max` bytes; empty at the end of the stream.
    func read(max: Int = 64 << 10) throws -> Data {
        var buffer = Data(count: max)
        while true {
            let n = buffer.withUnsafeMutableBytes { readSocket(fd, $0.baseAddress!, max) }
            if n < 0 && errno == EINTR { continue }
            if n < 0 {
                if errno == ECONNRESET || errno == ENOTCONN { return Data() }
                throw DMXError("docker_failed", "read from dockerd: \(String(cString: strerror(errno)))")
            }
            return buffer.prefix(n)
        }
    }
}

/// dockerd's log in the guest, for hints (DockerBridge.guestLog).
let dockerdLog = "/var/lib/dmx/log/dockerd.log"

/// Just enough of the Docker Engine API for sandboxes: one connection per request, HTTP/1.0 so
/// replies are never chunked and end when dockerd closes the connection, and the raw stream
/// dockerd hands over for `exec` and `logs`. Blocking reads run on their own threads.
struct DockerAPI: Sendable {
    let open: @Sendable () async throws -> DockerStream

    /// API version sent with every request: dockerd 29 serves 1.44 and later; 1.47 has
    /// everything used here.
    static let version = "v1.47"

    /// Through the daemon's `~/.dmx/docker.sock`, starting the daemon (and so the VM and dockerd)
    /// if nothing answers.
    static func host(_ paths: Paths) -> DockerAPI {
        DockerAPI {
            do {
                return try connectUnix(paths.dockerSocket)
            } catch let error as DMXError where error.code == "daemon_unreachable" {
                // No daemon: starting one binds docker.sock (or launchd holds it already).
                guard let client = try await DaemonClient.connect(paths: paths, start: true) else { throw error }
                client.close()
                return try connectUnix(paths.dockerSocket)
            }
        }
    }

    private static func connectUnix(_ url: URL) throws -> DockerStream {
        var address = try unixAddress(url)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DMXError("docker_failed", "socket: \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw DMXError("daemon_unreachable", "connect \(url.path): \(String(cString: strerror(code)))",
                           hint: "run `dmx status`; after an upgrade, `dmx install` again so launchd holds docker.sock")
        }
        return DockerStream(fd: fd) { _ = Darwin.close(fd) }
    }

    /// Sends a request and returns the stream positioned after the reply's header, with the
    /// status code. A JSON `body` goes out with its length.
    func start(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> (status: Int, stream: DockerStream, rest: Data) {
        let stream = try await open()
        do {
            let payload = body.map(\.compactData) ?? Data()
            let head = "\(method) /\(Self.version)\(path) HTTP/1.0\r\nHost: docker\r\n"
                + (body != nil ? "Content-Type: application/json\r\nContent-Length: \(payload.count)\r\n" : "") + "\r\n"
            let (status, rest) = try await onThread { () throws -> (Int, Data) in
                try stream.writeAll(Data(head.utf8) + payload)
                var reply = Data()
                while true {
                    if let end = reply.range(of: Data("\r\n\r\n".utf8)) {
                        let line = String(decoding: reply[..<end.lowerBound], as: UTF8.self).prefix { $0 != "\r" }
                        guard let code = line.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
                            throw DMXError("docker_failed", "dockerd sent a bad reply to \(method) \(path): \(line.prefix(80))")
                        }
                        return (code, Data(reply[end.upperBound...]))
                    }
                    let chunk = try stream.read()
                    guard !chunk.isEmpty, reply.count < 1 << 20 else {
                        throw DMXError("docker_failed", "dockerd closed the connection without replying to \(method) \(path)",
                                       hint: "see the log: `dmx exec -- tail -50 \(dockerdLog)`")
                    }
                    reply.append(chunk)
                }
            }
            return (status, stream, rest)
        } catch {
            stream.close()
            throw error
        }
    }

    /// A whole request: the status and the body (at most 64 MB).
    func call(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> (status: Int, body: Data) {
        let (status, stream, rest) = try await start(method, path, body: body)
        defer { stream.close() }
        let data = try await onThread { () throws -> Data in
            var data = rest
            while data.count < 64 << 20 {
                let chunk = try stream.read()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            return data
        }
        return (status, data)
    }

    /// A request that must succeed (2xx); returns the JSON reply, or null for an empty body.
    /// dockerd's error message becomes a DMXError with `code`, or `notFound` for a 404.
    @discardableResult
    func json(_ method: String, _ path: String, body: JSONValue? = nil, code: String = "docker_failed",
              notFound: DMXError? = nil) async throws -> JSONValue {
        let (status, data) = try await call(method, path, body: body)
        guard (200..<300).contains(status) else {
            if status == 404, let notFound { throw notFound }
            let message = (try? JSONDecoder().decode(JSONValue.self, from: data))?["message"]?.string
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw DMXError(code, "dockerd: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if data.isEmpty { return .null }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }
}

/// Docker's multiplexed stream (exec and logs without a terminal): frames of an 8-byte header
/// (stream 1 stdout or 2 stderr, three zero bytes, a big-endian length) and the payload.
/// Payloads come out in pieces as they arrive, so a large frame is never held whole.
struct DockerFrames {
    private var header = Data()
    private var stream: UInt8 = 1
    private var remaining = 0

    mutating func feed(_ data: Data) -> [(stream: UInt8, payload: Data)] {
        var pieces: [(UInt8, Data)] = []
        var rest = data[...]
        while !rest.isEmpty {
            if remaining == 0 {
                let n = min(8 - header.count, rest.count)
                header.append(rest.prefix(n))
                rest = rest.dropFirst(n)
                guard header.count == 8 else { break }
                stream = header[header.startIndex]
                remaining = header.suffix(4).reduce(0) { $0 << 8 | Int($1) }
                header = Data()
                continue
            }
            let n = min(remaining, rest.count)
            pieces.append((stream, Data(rest.prefix(n))))
            rest = rest.dropFirst(n)
            remaining -= n
        }
        return pieces
    }
}

func onThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}

/// Percent-encodes a query value.
func queryValue(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}
