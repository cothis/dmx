import Foundation

/// Copies a Docker client's connection to dockerd and back like `splice`, but follows the
/// client's side as HTTP/1.1 requests, so the daemon can act on a container start before dockerd
/// sees it: the host ports the container publishes are listened on first, and a port taken on
/// the Mac fails the start with Docker Desktop's error (`DockerBridge.reservePorts`).
///
/// Bytes pass unchanged both ways. The only bytes the proxy writes itself are such an error
/// reply, in place of dockerd's. Request bodies are followed by `Content-Length` or chunked
/// framing only to find where the next request starts. Once a request asks for an upgrade
/// (attach, exec, BuildKit sessions) or cannot be read as HTTP, the rest of the connection is
/// copied as it is. Replies are never parsed: Docker clients wait for a reply before sending the
/// next request on a connection, so the first bytes after a start request are its reply's status
/// line, which tells the bridge the start was answered. One blocking thread per direction; a
/// Docker client holds only a few connections.
final class DockerProxy: @unchecked Sendable {
    enum Verdict: Sendable {
        /// Pass the request on; `answered` gets the reply's status code, or nil if none came.
        case pass(answered: (@Sendable (Int?) -> Void)?)
        /// Answer it with this error message instead (HTTP 500, as dockerd answers a failed start).
        case refuse(String)
    }

    private let client: Int32, server: Int32
    /// Asked before a container starts or restarts, with its name or id as the client gave it.
    private let starting: @Sendable (String) async -> Verdict
    private let lock = NSLock()
    /// Waits for the status of a start request that went to dockerd.
    private var answered: (@Sendable (Int?) -> Void)?

    static let bufferSize = 64 << 10
    /// Longer request heads are passed on unparsed (dockerd's own limit is 1 MB).
    static let headLimit = 64 << 10

    init(client: Int32, server: Int32, starting: @escaping @Sendable (String) async -> Verdict) {
        self.client = client
        self.server = server
        self.starting = starting
    }

    /// Copies until both directions have ended. The caller closes the descriptors afterwards.
    func run() async {
        for fd in [client, server] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK) }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for direction in [requests, replies] {
                group.enter()
                let thread = Thread {
                    direction()
                    group.leave()
                }
                thread.stackSize = 256 << 10
                thread.start()
            }
            group.notify(queue: .global()) { done.resume() }
        }
        take()?(nil)
    }

    private func take() -> (@Sendable (Int?) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let hook = answered
        answered = nil
        return hook
    }

    // MARK: Replies

    private func replies() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let n = readSocket(server, buffer, Self.bufferSize)
            if n < 0 && errno == EINTR { continue }
            if n == 0 {
                shutdown(client, SHUT_WR)
                return
            }
            if n < 0 {
                abort()
                return
            }
            if let hook = take() { hook(Self.status(UnsafeRawBufferPointer(start: buffer, count: n))) }
            guard toClient(UnsafeRawBufferPointer(start: buffer, count: n)) else { return }
        }
    }

    /// The status code of a reply that starts with "HTTP/1.1 204 ...".
    static func status(_ bytes: UnsafeRawBufferPointer) -> Int? {
        let line = String(decoding: bytes.prefix(32), as: UTF8.self)
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/") else { return nil }
        return Int(parts[1])
    }

    private func toClient(_ bytes: UnsafeRawBufferPointer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return writeAll(client, bytes)
    }

    // MARK: Requests

    private func requests() {
        let input = Reader(fd: client)
        defer { input.release() }
        while true {
            let head: Data
            switch input.head(limit: Self.headLimit) {
            case .head(let bytes): head = bytes
            case .end:
                shutdown(server, SHUT_WR)
                return
            case .failed:
                abort()
                return
            case .unreadable:
                return raw(input)
            }
            guard let request = Request(head) else {
                guard writeAll(server, head) else { return }
                return raw(input)
            }
            var discard = false
            if let container = request.startedContainer {
                switch wait({ await self.starting(container) }) {
                case .pass(let hook):
                    lock.lock()
                    answered = hook
                    lock.unlock()
                case .refuse(let message):
                    discard = true
                    refuse(message)
                }
            }
            if !discard { guard writeAll(server, head) else { return } }
            switch body(request, input, discard: discard) {
            case .done: break
            case .end:
                shutdown(server, SHUT_WR)
                return
            case .failed:
                abort()
                return
            case .stopped:
                return
            case .unreadable:
                return raw(input)
            }
            if request.upgrades { return raw(input) }
        }
    }

    /// Passes on (or reads past) the request's body by its framing.
    private func body(_ request: Request, _ input: Reader, discard: Bool) -> Outcome {
        let out: (Data) -> Bool = { discard || writeAll(self.server, $0) }
        switch request.body {
        case .none:
            return .done
        case .length(let count):
            return input.copy(count, to: discard ? nil : server)
        case .chunked:
            while true {
                guard case .line(let line) = input.line(limit: 4096) else { return .unreadable }
                guard out(line) else { return .stopped }
                let size = String(decoding: line, as: UTF8.self).prefix { $0.isHexDigit }
                guard let count = Int(size, radix: 16) else { return .unreadable }
                if count == 0 { break }
                let copied = input.copy(count, to: discard ? nil : server)
                guard case .done = copied else { return copied }
                guard case .line(let end) = input.line(limit: 2), end == Data("\r\n".utf8) else { return .unreadable }
                guard out(end) else { return .stopped }
            }
            // Trailers, then the empty line.
            while true {
                guard case .line(let line) = input.line(limit: 4096) else { return .unreadable }
                guard out(line) else { return .stopped }
                if line == Data("\r\n".utf8) { return .done }
            }
        }
    }

    /// Copies the rest of the client's side unparsed.
    private func raw(_ input: Reader) {
        guard writeAll(server, input.drain()) else { return }
        switch input.copy(Int.max, to: server) {
        case .end, .done: shutdown(server, SHUT_WR)
        case .failed: abort()
        default: break
        }
    }

    /// Answers the request with dockerd's error format; the client prints the message.
    private func refuse(_ message: String) {
        let body = (try? JSONSerialization.data(withJSONObject: ["message": message])) ?? Data()
        let head = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: \(body.count + 1)\r\n\r\n"
        let reply = Data(head.utf8) + body + Data("\n".utf8)
        _ = reply.withUnsafeBytes { toClient($0) }
    }

    /// Ends both directions after a read error: that side is gone.
    private func abort() {
        shutdown(client, SHUT_RDWR)
        shutdown(server, SHUT_RDWR)
    }

    private func wait(_ ask: @escaping @Sendable () async -> Verdict) -> Verdict {
        final class Box: @unchecked Sendable { var verdict = Verdict.pass(answered: nil) }
        let box = Box(), done = DispatchSemaphore(value: 0)
        Task {
            box.verdict = await ask()
            done.signal()
        }
        done.wait()
        return box.verdict
    }
}

/// What the proxy needs to know about one request.
struct DockerRequest {
    enum Body: Equatable { case none, length(Int), chunked }

    let method: String
    let target: String
    let body: Body
    /// Asks to take the connection over (attach, exec start, BuildKit's session and gRPC).
    let upgrades: Bool

    /// Parses a request head ending in an empty line; nil if it is not HTTP/1.x that we can frame.
    init?(_ head: Data) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return nil }
        method = String(start[0])
        target = String(start[1])
        var length: Int?, chunked = false, encoded = false, upgrade = false
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
            switch name {
            case "content-length":
                guard let n = Int(value), n >= 0, length == nil || length == n else { return nil }
                length = n
            case "transfer-encoding":
                encoded = true
                chunked = value.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) == "chunked"
            case "upgrade":
                upgrade = true
            case "connection":
                if value.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) { upgrade = true }
            default:
                break
            }
        }
        if encoded {
            guard chunked else { return nil }
            body = .chunked
        } else {
            body = length.map { $0 > 0 ? .length($0) : .none } ?? .none
        }
        upgrades = upgrade || method == "CONNECT"
    }

    /// The container a `POST /containers/{id}/start` (or `restart`) is for, with or without the
    /// API version prefix.
    var startedContainer: String? {
        guard method == "POST" else { return nil }
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        if let first = parts.first, first.hasPrefix("v"), Double(first.dropFirst()) != nil { parts = parts.dropFirst() }
        guard parts.count == 3, parts.first == "containers", !parts[parts.startIndex + 1].isEmpty,
              ["start", "restart"].contains(parts.last!) else { return nil }
        return String(parts[parts.startIndex + 1])
    }
}

private typealias Request = DockerRequest

/// Buffered reads from the client's socket.
private final class Reader {
    enum Head { case head(Data), end, failed, unreadable }
    enum Line { case line(Data), end, failed, unreadable }

    let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    func release() { buffer = Data() }

    /// Reads more; 0 at end of stream, -1 on an error.
    private func fill() -> Int {
        var chunk = [UInt8](repeating: 0, count: DockerProxy.bufferSize)
        while true {
            let n = chunk.withUnsafeMutableBytes { readSocket(fd, $0.baseAddress!, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n > 0 { buffer.append(contentsOf: chunk[..<n]) }
            return n
        }
    }

    /// Everything buffered, which the caller passes on.
    func drain() -> Data {
        defer { buffer = Data() }
        return buffer
    }

    /// A request head up to and including its empty line.
    func head(limit: Int) -> Head {
        var searched = 0
        while true {
            if let end = buffer.range(of: Data("\r\n\r\n".utf8), in: (buffer.startIndex + max(searched - 3, 0))..<buffer.endIndex) {
                let head = buffer[buffer.startIndex..<end.upperBound]
                buffer = Data(buffer[end.upperBound...])
                return .head(Data(head))
            }
            searched = buffer.count
            if buffer.count > limit { return .unreadable }
            switch fill() {
            case 0: return buffer.isEmpty ? .end : .unreadable
            case ..<0: return .failed
            default: continue
            }
        }
    }

    /// One line up to and including CRLF.
    func line(limit: Int) -> Line {
        while true {
            if let end = buffer.range(of: Data("\r\n".utf8)) {
                let line = buffer[buffer.startIndex..<end.upperBound]
                buffer = Data(buffer[end.upperBound...])
                return .line(Data(line))
            }
            if buffer.count > limit { return .unreadable }
            switch fill() {
            case 0: return .end
            case ..<0: return .failed
            default: continue
            }
        }
    }

    /// Copies `count` bytes (or up to the end of stream for Int.max) to `to`, or reads past them.
    func copy(_ count: Int, to: Int32?) -> Outcome {
        var left = count
        if !buffer.isEmpty {
            let n = min(left, buffer.count)
            if let to { guard writeAll(to, buffer.prefix(n)) else { return .stopped } }
            buffer = Data(buffer.dropFirst(n))
            left -= n
        }
        guard left > 0 else { return .done }
        let chunk = UnsafeMutableRawPointer.allocate(byteCount: DockerProxy.bufferSize, alignment: 16)
        defer { chunk.deallocate() }
        while left > 0 {
            let n = readSocket(fd, chunk, min(left, DockerProxy.bufferSize))
            if n < 0 && errno == EINTR { continue }
            if n == 0 { return .end }
            if n < 0 { return .failed }
            if let to { guard writeAll(to, UnsafeRawBufferPointer(start: chunk, count: n)) else { return .stopped } }
            left -= n
        }
        return .done
    }
}

/// How copying part of a request went: `end` and `failed` are the client's end of stream and read
/// error, `stopped` means dockerd took no more bytes, `unreadable` that the framing was not HTTP.
private enum Outcome { case done, end, failed, stopped, unreadable }

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { writeAll(fd, $0) }
}

private func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let n = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { return false }
        offset += n
    }
    return true
}
