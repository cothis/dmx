import Foundation

/// The vsock port dmx-agent listens on inside the guest.
public let agentPort: UInt32 = 1024
/// The protocol version this host speaks; see docs/agent-protocol.md.
public let agentProtocol = 1

enum FrameKind: UInt8 {
    case json = 0, stdin, stdout, stderr
}

public struct AgentHello: Codable, Sendable {
    public let agent: String
    public let version: String
    public let `protocol`: Int
    public let kernel: String
}

/// Guest memory in bytes, from /proc/meminfo.
public struct GuestMemory: Codable, Sendable {
    public let total: UInt64
    public let free: UInt64
    public let available: UInt64
    public let buffers: UInt64
    public let cached: UInt64
    public let shmem: UInt64
    public let swapTotal: UInt64
    public let swapFree: UInt64
    /// Held by the balloon, so returned to the host. Absent from agents before it was added.
    public let balloon: UInt64?

    /// Memory the guest cannot reclaim without swapping: everything except free pages and
    /// droppable cache (shmem, which includes the unpacked initramfs, counts as used).
    /// Not `total - available`: MemAvailable also subtracts the kernel's watermark reserve,
    /// which grows with the ceiling (about 88 MB at 8 GB) without being touched. Balloon pages
    /// count as allocated in /proc/meminfo but belong to the host, so they are left out.
    public var used: UInt64 {
        let reclaimable = free + buffers + (cached > shmem ? cached - shmem : 0) + (balloon ?? 0)
        return total > reclaimable ? total - reclaimable : 0
    }

    /// Clean page cache the guest can drop: block device buffers and file pages, without shmem.
    public var cache: UInt64 { buffers + (cached > shmem ? cached - shmem : 0) }
}

public struct GuestCgroup: Codable, Sendable {
    public let path: String
    public let memoryCurrent: UInt64
}

public struct AgentStats: Codable, Sendable {
    public let memory: GuestMemory
    public let uptimeS: Double
    public let load: [Double]
    public let cgroups: [GuestCgroup]
}

public struct ReclaimResult: Codable, Sendable {
    /// Guest MemFree before and after.
    public let freeBefore: UInt64
    public let freeAfter: UInt64
    /// False when the kernel could not reclaim all of it (`memory.reclaim` said EAGAIN).
    public let complete: Bool
}

public struct DropCachesResult: Codable, Sendable {
    public let availableBefore: UInt64
    public let availableAfter: UInt64
}

public struct ExecRequest: Codable, Sendable {
    public var argv: [String]
    public var env: [String] = []
    public var cwd: String?
    public var tty = false
    /// Without a tty: whether stdin will be sent. Otherwise the process reads /dev/null.
    public var stdin = false
    public var rows = 24
    public var cols = 80

    public init(argv: [String]) { self.argv = argv }

    /// Every field but `argv` is optional on the wire, as the agent reads it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        argv = try c.decode([String].self, forKey: .argv)
        env = try c.decodeIfPresent([String].self, forKey: .env) ?? []
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        tty = try c.decodeIfPresent(Bool.self, forKey: .tty) ?? false
        stdin = try c.decodeIfPresent(Bool.self, forKey: .stdin) ?? false
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 24
        cols = try c.decodeIfPresent(Int.self, forKey: .cols) ?? 80
    }
}

public struct ExecExit: Codable, Sendable {
    public let code: Int32?
    public let signal: Int32?
}

public enum ExecEvent: Sendable {
    case stdout(Data)
    case stderr(Data)
    case exit(ExecExit)
}

public struct ExecOutput: Sendable {
    public let exit: ExecExit
    public let stdout: Data
    public let stderr: Data
}

/// One connection speaking the agent protocol's framing: to dmx-agent, or to the dmx daemon,
/// which speaks the same protocol. Requests on it are answered in order; an exec takes it over.
/// Blocking socket I/O runs on the connection's own queue, never on the caller's thread.
public final class FrameConnection: @unchecked Sendable {
    /// Who is on the other end. Agent error codes get an `agent_` prefix; the daemon's are
    /// already dmx error codes and pass through unchanged.
    public enum Peer: String, Sendable {
        case agent, daemon
    }

    let peer: Peer
    private let closeConnection: @Sendable () -> Void
    let fd: Int32
    private let queue = DispatchQueue(label: "dmx.frame.connection")
    private let writeLock = NSLock()
    private var nextID: UInt64 = 1

    /// A connection on any stream socket; `close` releases it.
    init(fd: Int32, peer: Peer = .agent, close: @escaping @Sendable () -> Void) {
        self.peer = peer
        closeConnection = close
        self.fd = fd
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private let closeLock = NSLock()
    private var closed = false

    deinit { close() }

    /// Closes once; later calls do nothing, so a reused descriptor number is never closed.
    public func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        closeConnection()
    }

    public func call<P: Encodable & Sendable, R: Decodable>(_ method: String, _ params: P) async throws -> R {
        let data = try await onQueue { () throws -> Data in
            let id = self.nextID
            self.nextID += 1
            try self.writeJSON(Request(id: id, method: method, params: params))
            return try self.readReply(method: method)
        }
        do {
            return try Self.decoder.decode(Reply<R>.self, from: data).result
        } catch {
            throw DMXError("\(peer)_protocol", "\(method): unexpected reply: \(error)")
        }
    }

    /// Starts a process in the guest. This connection belongs to the session from now on.
    public func exec(_ request: ExecRequest) async throws -> ExecSession {
        let reply = try await onQueue { () throws -> Data in
            let id = self.nextID
            self.nextID += 1
            try self.writeJSON(Request(id: id, method: "exec", params: request))
            return try self.readReply(method: "exec")
        }
        struct Started: Decodable { let pid: Int }
        guard let started = try? Self.decoder.decode(Reply<Started>.self, from: reply).result else {
            throw DMXError("\(peer)_protocol", "exec: unexpected reply")
        }
        return ExecSession(connection: self, pid: started.pid)
    }

    /// The next output frame or the exit status of the exec on this connection. Frames are read
    /// only when asked for, so a guest process that writes faster than the caller consumes waits
    /// on vsock credit instead of piling its output up in host memory.
    func nextEvent() async throws -> ExecEvent {
        try await onQueue { () throws -> ExecEvent in
            while let (kind, payload) = try self.readFrame() {
                switch kind {
                case .stdout: return .stdout(Data(payload))
                case .stderr: return .stderr(Data(payload))
                case .json:
                    if let exit = try? Self.decoder.decode(ExecExit.self, from: payload),
                       (try? Self.decoder.decode(Envelope.self, from: payload))?.event == "exit" {
                        return .exit(exit)
                    }
                case .stdin: break
                }
            }
            throw DMXError("\(self.peer)_disconnected", "exec: connection closed before the process exited")
        }
    }

    /// The next frame from the peer, or nil at end of stream. For the serving side of a connection.
    func receive() async throws -> (FrameKind, Data)? {
        try await onQueue { try self.readFrame() }
    }

    /// Sends one JSON frame. For the serving side of a connection.
    func send(_ value: some Encodable) throws { try writeJSON(value) }

    // MARK: Framing

    func writeFrame(_ kind: FrameKind, _ payload: Data) throws {
        var header = Data(count: 5)
        let length = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: length) { header.replaceSubrange(0..<4, with: $0) }
        header[4] = kind.rawValue
        writeLock.lock()
        defer { writeLock.unlock() }
        try writeAll(header + payload)
    }

    private func writeJSON(_ value: some Encodable) throws {
        try writeFrame(.json, try Self.encoder.encode(value))
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw DMXError("\(peer)_disconnected", "write to \(peer): \(String(cString: strerror(errno)))")
                }
                offset += n
            }
        }
    }

    private func readExactly(_ count: Int) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
            if n < 0 {
                if errno == EINTR { continue }
                throw DMXError("\(peer)_disconnected", "read from \(peer): \(String(cString: strerror(errno)))")
            }
            if n == 0 {
                if offset == 0 { return nil }
                throw DMXError("\(peer)_disconnected", "\(peer) closed the connection mid-frame")
            }
            offset += n
        }
        return data
    }

    func readFrame() throws -> (FrameKind, Data)? {
        guard let header = try readExactly(4) else { return nil }
        let length = Int(header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard length >= 1, length <= 16 << 20 else {
            throw DMXError("\(peer)_protocol", "bad frame length \(length)")
        }
        guard let body = try readExactly(length) else {
            throw DMXError("\(peer)_disconnected", "\(peer) closed the connection mid-frame")
        }
        guard let kind = FrameKind(rawValue: body[body.startIndex]) else {
            throw DMXError("\(peer)_protocol", "unknown frame kind \(body[body.startIndex])")
        }
        return (kind, body.dropFirst())
    }

    /// Reads the next JSON frame and turns an error reply into a DMXError.
    private func readReply(method: String) throws -> Data {
        guard let (kind, payload) = try readFrame() else {
            throw DMXError("\(peer)_disconnected", "\(method): \(peer) closed the connection")
        }
        guard kind == .json else { throw DMXError("\(peer)_protocol", "\(method): expected a JSON frame") }
        let envelope: Envelope
        do {
            envelope = try Self.decoder.decode(Envelope.self, from: payload)
        } catch {
            throw DMXError("\(peer)_protocol", "\(method): unreadable reply: \(error)")
        }
        if envelope.ok != true {
            let failure = envelope.error ?? AgentFailure(code: "unknown", message: "no error given", hint: nil)
            switch peer {
            case .agent: throw DMXError("agent_\(failure.code)", "\(method): \(failure.message)", hint: failure.hint)
            case .daemon: throw DMXError(failure.code, failure.message, hint: failure.hint)
            }
        }
        return Data(payload)
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

/// Talks to dmx-agent: control calls share one connection, each exec opens its own
/// (the agent hands an exec's connection over to that process's streams).
public final class AgentClient: Sendable {
    private let control: FrameConnection
    /// Opens a new connection to the agent (exec and connect take theirs over).
    let open: @MainActor @Sendable () async throws -> FrameConnection

    init(control: FrameConnection, open: @escaping @MainActor @Sendable () async throws -> FrameConnection) {
        self.control = control
        self.open = open
    }

    public func close() { control.close() }

    public func call<P: Encodable & Sendable, R: Decodable>(_ method: String, _ params: P) async throws -> R {
        try await control.call(method, params)
    }

    public func hello() async throws -> AgentHello { try await control.call("hello", Empty()) }
    public func stats() async throws -> AgentStats { try await control.call("stats", Empty()) }

    public func dropCaches(level: Int = 3) async throws -> DropCachesResult {
        try await control.call("drop_caches", ["level": level])
    }

    /// Asks the guest kernel to reclaim `bytes` through the root cgroup's `memory.reclaim`.
    /// `swappiness` 0 takes only file cache; nil lets the guest's swappiness decide, so anonymous
    /// and tmpfs pages may go to zram too.
    public func reclaim(bytes: UInt64, swappiness: Int? = nil) async throws -> ReclaimResult {
        struct Params: Encodable, Sendable { let bytes: UInt64; let swappiness: Int? }
        return try await control.call("reclaim", Params(bytes: bytes, swappiness: swappiness))
    }

    /// Turns on zram swap in the guest if it is not on yet; returns its size in bytes.
    public func swapOn() async throws -> UInt64 {
        struct Result: Decodable { let size: UInt64 }
        let result: Result = try await control.call("swap_on", Empty())
        return result.size
    }

    /// Sets the smallest block of free pages that free page reporting hands back, as a page order
    /// (0: one 16 KB page); returns the order it replaced.
    public func setReportingOrder(_ order: Int) async throws -> Int {
        struct Result: Decodable { let previous: Int }
        let result: Result = try await control.call("reporting_order", ["order": order])
        return result.previous
    }

    /// Has every guest slab cache free its empty slabs; returns the guest's MemFree before and after.
    public func shrinkSlabs() async throws -> (freeBefore: UInt64, freeAfter: UInt64) {
        struct Result: Decodable { let freeBefore: UInt64; let freeAfter: UInt64 }
        let result: Result = try await control.call("shrink_slabs", Empty())
        return (result.freeBefore, result.freeAfter)
    }

    /// Sets the guest clock to the host clock and returns how far off it was, in nanoseconds.
    public func syncTime() async throws -> Int64 {
        struct Params: Encodable { let unixNs: Int64 }
        struct Result: Decodable { let offsetNs: Int64 }
        let now = Int64(Date().timeIntervalSince1970 * 1e9)
        let result: Result = try await control.call("time_sync", Params(unixNs: now))
        return result.offsetNs
    }

    /// Asks the guest to sync and power off. The VM stops shortly after this returns.
    public func shutdown() async throws {
        let _: Empty = try await control.call("shutdown", Empty())
    }

    /// Starts a process in the guest on a new connection.
    public func exec(_ request: ExecRequest) async throws -> ExecSession {
        try await open().exec(request)
    }

    /// Runs a process to completion and collects its output.
    public func run(_ argv: [String], stdin: Data? = nil, tty: Bool = false) async throws -> ExecOutput {
        var request = ExecRequest(argv: argv)
        request.tty = tty
        request.stdin = stdin != nil
        let session = try await exec(request)
        // Output is read only while we iterate, so stdin goes in alongside: a process that echoes
        // a large stdin would otherwise block on its full stdout while we block on its stdin.
        let feed = Task.detached {
            if let stdin {
                if !stdin.isEmpty { try session.write(stdin) }
                try session.closeStdin()
            }
        }
        var out = Data(), err = Data()
        for try await event in session.events {
            switch event {
            case .stdout(let d): out.append(d)
            case .stderr(let d): err.append(d)
            case .exit(let exit):
                try await feed.value
                return ExecOutput(exit: exit, stdout: out, stderr: err)
            }
        }
        throw DMXError("agent_disconnected", "\(argv.first ?? "exec"): connection closed before the process exited")
    }
}

/// A running process in the guest. Output arrives on `events`, ending with `.exit`.
public final class ExecSession: Sendable {
    public let pid: Int
    public let events: ExecEvents
    let connection: FrameConnection

    init(connection: FrameConnection, pid: Int) {
        self.connection = connection
        self.pid = pid
        events = ExecEvents(connection: connection)
    }

    public func write(_ data: Data) throws { try connection.writeFrame(.stdin, data) }
    public func closeStdin() throws { try connection.writeFrame(.stdin, Data()) }

    public func resize(rows: Int, cols: Int) throws {
        try control("resize", ["rows": rows, "cols": cols])
    }

    public func signal(_ number: Int32) throws {
        try control("signal", ["signal": Int(number)])
    }

    private func control(_ method: String, _ params: [String: Int]) throws {
        let body = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        try connection.writeFrame(.json, body)
    }
}

/// A process's output and then its exit status, read from the guest as it is consumed.
/// Iterate it once.
public struct ExecEvents: AsyncSequence, Sendable {
    public typealias Element = ExecEvent
    let connection: FrameConnection

    public func makeAsyncIterator() -> Iterator { Iterator(connection: connection) }

    public struct Iterator: AsyncIteratorProtocol {
        let connection: FrameConnection
        var finished = false

        public mutating func next() async throws -> ExecEvent? {
            guard !finished else { return nil }
            do {
                let event = try await connection.nextEvent()
                if case .exit = event { finished = true }
                return event
            } catch {
                finished = true
                throw error
            }
        }
    }
}

private struct Empty: Codable, Sendable {}

private struct Request<P: Encodable>: Encodable {
    let id: UInt64
    let method: String
    let params: P
}

private struct AgentFailure: Decodable {
    let code: String
    let message: String
    let hint: String?
}

private struct Envelope: Decodable {
    let ok: Bool?
    let error: AgentFailure?
    let event: String?
}

private struct Reply<R: Decodable>: Decodable {
    let result: R
}

/// Connects to dmx-agent, retrying until it listens (it starts a few hundred ms into boot).
/// `open` makes one connection to the agent's port; `isStopped` ends the wait early.
@MainActor
func connectAgent(timeout: Duration, isStopped: () -> Bool,
                  open: @escaping @MainActor @Sendable () async throws -> FrameConnection) async throws -> AgentClient {
    let deadline = ContinuousClock.now + timeout
    var lastError = ""
    while ContinuousClock.now < deadline {
        if isStopped() {
            throw DMXError("vm_stopped", "the VM stopped before the agent answered", hint: "run `dmx boot --verbose` to see the guest console")
        }
        do {
            let client = AgentClient(control: try await open(), open: open)
            let hello = try await client.hello()
            guard hello.protocol == agentProtocol else {
                throw DMXError("agent_version", "agent speaks protocol \(hello.protocol), this dmx speaks \(agentProtocol)", hint: "run `make guest` to rebuild the guest with a matching agent")
            }
            return client
        } catch let error as DMXError where error.code == "agent_version" || error.code == "vm_error" {
            throw error
        } catch {
            lastError = (error as? DMXError)?.message ?? (error as NSError).localizedDescription
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw DMXError("agent_unreachable", "no answer from dmx-agent on vsock port \(agentPort) within \(timeout): \(lastError)", hint: "run `dmx boot --verbose` and look for dmx-init or dmx-agent errors")
}

extension Machine {
    @MainActor
    public func connectAgent(timeout: Duration) async throws -> AgentClient {
        try await DMXCore.connectAgent(timeout: timeout, isStopped: { stopping }) { [self] in
            let fd = try await vsock.connect(port: agentPort)
            return FrameConnection(fd: fd) { _ = Darwin.close(fd) }
        }
    }
}
