import Foundation

/// A host TCP port forwarded to a TCP port in the guest (`dmx port add`). The daemon listens on
/// the host port; each connection gets its own vsock stream to dmx-agent, which connects to the
/// guest port on loopback (see `connect` in docs/agent-protocol.md). No privileged helper and no
/// guest networking beyond `lo` is involved.
public struct PortForward: Codable, Sendable, Equatable {
    /// The IPv4 address listened on. 127.0.0.1 unless given; 0.0.0.0 lets other machines in.
    public var hostAddress: String
    public var hostPort: Int
    public var guestPort: Int

    public init(hostAddress: String = "127.0.0.1", hostPort: Int, guestPort: Int) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.guestPort = guestPort
    }

    /// `host_address` is optional on the wire.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostAddress = try c.decodeIfPresent(String.self, forKey: .hostAddress) ?? "127.0.0.1"
        hostPort = try c.decode(Int.self, forKey: .hostPort)
        guestPort = try c.decode(Int.self, forKey: .guestPort)
    }

    /// Parses `[HOST_IP:]HOST_PORT[:GUEST_PORT]`, Docker's `-p` without the protocol. Without a
    /// guest port, the guest port is the host port.
    public init(parsing spec: String) throws {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let bad = DMXError("bad_port_spec", "cannot read \"\(spec)\" as [HOST_IP:]HOST_PORT[:GUEST_PORT]", hint: "e.g. `dmx port add 8080:80`")
        let ports: [String]
        switch parts.count {
        case 1, 2: hostAddress = "127.0.0.1"; ports = parts
        case 3: hostAddress = parts[0]; ports = Array(parts[1...])
        default: throw bad
        }
        guard let host = Int(ports[0]), let guest = Int(ports.last!) else { throw bad }
        hostPort = host
        guestPort = guest
        try validate()
    }

    /// Checks the ports' range and puts the address in its canonical form.
    mutating func validate() throws {
        for (name, port) in [("host", hostPort), ("guest", guestPort)] where !(1...65535).contains(port) {
            throw DMXError("bad_port_spec", "\(name) port \(port) is not between 1 and 65535", hint: "e.g. `dmx port add 8080:80`")
        }
        if hostAddress == "localhost" { hostAddress = "127.0.0.1" }
        var address = in_addr()
        guard inet_pton(AF_INET, hostAddress, &address) == 1 else {
            throw DMXError("bad_port_spec", "\"\(hostAddress)\" is not an IPv4 address", hint: "leave it out to listen on 127.0.0.1, or use 0.0.0.0 for every interface")
        }
    }

    var hostEndpoint: String { "\(hostAddress):\(hostPort)" }

    /// Whether two forwards would listen on the same host port (0.0.0.0 overlaps every address).
    func overlaps(_ other: PortForward) -> Bool {
        hostPort == other.hostPort
            && (hostAddress == other.hostAddress || hostAddress == "0.0.0.0" || other.hostAddress == "0.0.0.0")
    }
}

/// A forward and what the daemon is doing with it (`dmx port ls`).
public struct PortForwardStatus: Codable, Sendable {
    public let hostAddress: String
    public let hostPort: Int
    public let guestPort: Int
    /// Whether the daemon listens on the host port. When not, `error` says why.
    public let listening: Bool
    public let error: String?
    /// Connections open now, and accepted since the daemon started.
    public let connections: Int
    public let totalConnections: Int
}

public struct PortList: Codable, Sendable {
    public let forwards: [PortForwardStatus]
}

extension Paths {
    /// The forwards, so a new daemon listens on them again.
    var ports: URL { home.appendingPathComponent("ports.json") }
}

/// The daemon's forwards. They are kept in `~/.dmx/ports.json` and listened on for as long as the
/// daemon runs, VM or not: the first connection boots the VM, and an open connection counts as
/// using it, so the VM stops for being idle only once every forwarded connection has closed.
/// The daemon stays up while any forward exists (4 MB with the VM stopped).
@MainActor
final class PortForwards {
    private let paths: Paths
    private var listeners: [Listener] = []
    /// The running VM's agent, booting the VM first if needed.
    private var agent: (@MainActor () async throws -> AgentClient)?
    /// Called with true when a forwarded connection opens and false when it closes.
    private var using: (@MainActor (Bool) -> Void)?
    /// Forwarded connections open on all forwards, and the pending malloc trim after a burst.
    private var open = 0
    private var trim: Task<Void, Never>?

    init(paths: Paths) { self.paths = paths }

    var isEmpty: Bool { listeners.isEmpty }

    /// Listens on every saved forward. A port that cannot be listened on stays in the list with
    /// its error (`dmx port ls`) until it is removed.
    func start(agent: @escaping @MainActor () async throws -> AgentClient, using: @escaping @MainActor (Bool) -> Void) {
        self.agent = agent
        self.using = using
        raiseDescriptorLimit()
        guard let data = try? Data(contentsOf: paths.ports) else { return }
        guard let saved = try? FrameConnection.decoder.decode([PortForward].self, from: data) else {
            return log("cannot read \(paths.ports.path); no ports forwarded")
        }
        for forward in saved {
            let listener = Listener(forward)
            do {
                try listen(listener)
            } catch {
                listener.error = (error as? DMXError)?.message ?? "\(error)"
                log("port \(forward.hostEndpoint): \(listener.error!)")
            }
            listeners.append(listener)
        }
    }

    /// Stops listening (the daemon is exiting). The forwards stay saved for the next daemon;
    /// connections already open end with the VM.
    func stop() {
        for listener in listeners { listener.close() }
    }

    /// Listens on a new forward and saves it. Does not boot the VM.
    func add(_ forward: PortForward) throws -> PortForwardStatus {
        var forward = forward
        try forward.validate()
        if let taken = listeners.first(where: { $0.forward.overlaps(forward) }) {
            throw DMXError("port_forwarded", "\(taken.forward.hostEndpoint) is already forwarded to guest port \(taken.forward.guestPort)",
                           hint: "run `dmx port rm \(taken.forward.hostEndpoint)` first, or pick another host port")
        }
        let listener = Listener(forward)
        try listen(listener)
        listeners.append(listener)
        do {
            try save()
        } catch {
            listeners.removeLast()
            listener.close()
            throw error
        }
        log("forwarding \(forward.hostEndpoint) to guest port \(forward.guestPort)")
        return listener.status
    }

    /// Removes the forwards on `hostPort` (only the one on `hostAddress` if given) and returns
    /// them. Connections already open stay open until either end closes them.
    func remove(hostPort: Int, hostAddress: String?) throws -> [PortForwardStatus] {
        let address = hostAddress == "localhost" ? "127.0.0.1" : hostAddress
        let matching = listeners.filter { $0.forward.hostPort == hostPort && (address == nil || $0.forward.hostAddress == address) }
        guard !matching.isEmpty else {
            throw DMXError("port_not_forwarded", "no forward on host port \(address.map { "\($0):" } ?? "")\(hostPort)", hint: "run `dmx port ls`")
        }
        listeners.removeAll { l in matching.contains { $0 === l } }
        for listener in matching {
            listener.close()
            log("stopped forwarding \(listener.forward.hostEndpoint)")
        }
        try save()
        return matching.map(\.status)
    }

    func list() -> [PortForwardStatus] { listeners.map(\.status) }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try (encoder.encode(listeners.map(\.forward)) + Data("\n".utf8)).write(to: paths.ports, options: .atomic)
        } catch {
            throw DMXError("daemon_error", "cannot save \(paths.ports.path): \(error.localizedDescription)", hint: "check that \(paths.home.path) is writable")
        }
    }

    // MARK: Connections

    private func listen(_ listener: Listener) throws {
        let fd = try listenTCP(listener.forward)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [unowned self] in MainActor.assumeIsolated { accept(listener) } }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        listener.source = source
        listener.error = nil
    }

    private func accept(_ listener: Listener) {
        guard let source = listener.source, !listener.paused else { return }
        while true {
            let fd = Darwin.accept(Int32(source.handle), nil, nil)
            guard fd >= 0 else {
                // Out of descriptors: the connection stays queued and the source would fire
                // again at once. Wait for connections to close instead of spinning.
                if errno == EMFILE || errno == ENFILE {
                    log("port \(listener.forward.hostEndpoint): out of file descriptors, pausing accept")
                    listener.paused = true
                    source.suspend()
                    Task {
                        try? await Task.sleep(for: .milliseconds(100))
                        guard listener.paused else { return }
                        listener.paused = false
                        source.resume()
                    }
                }
                return
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            Task { await forward(fd, listener) }
        }
    }

    /// Connects one accepted client to the guest port, booting the VM if it is stopped, and
    /// copies bytes until both sides are done.
    private func forward(_ client: Int32, _ listener: Listener) async {
        listener.active += 1
        listener.total += 1
        open += 1
        using?(true)
        defer {
            Darwin.close(client)
            listener.active -= 1
            open -= 1
            using?(false)
            if open == 0 { trimSoon() }
        }
        let stream: FrameConnection
        do {
            guard let agent else { return }
            stream = try await agent().connect(port: listener.forward.guestPort)
        } catch {
            // The client sees the connection close, as if nothing listened in the guest.
            log("port \(listener.forward.hostEndpoint): \((error as? DMXError)?.message ?? "\(error)")")
            return
        }
        await splice(client, stream.fd)
        stream.close()
    }

    /// malloc keeps the regions a burst of connections emptied (17 MB after 500 at once). Give
    /// them back once forwarded traffic has been quiet for a moment.
    private func trimSoon() {
        trim?.cancel()
        trim = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, open == 0 else { return }
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}

/// One forward and its listening socket.
@MainActor
private final class Listener {
    let forward: PortForward
    var source: DispatchSourceRead?
    var error: String?
    var active = 0, total = 0
    /// Accepting is suspended for a moment after running out of descriptors.
    var paused = false

    init(_ forward: PortForward) { self.forward = forward }

    func close() {
        if paused { source?.resume() }
        paused = false
        source?.cancel()
        source = nil
    }

    var status: PortForwardStatus {
        PortForwardStatus(hostAddress: forward.hostAddress, hostPort: forward.hostPort, guestPort: forward.guestPort,
                          listening: source != nil, error: error, connections: active, totalConnections: total)
    }
}

/// launchd starts agents with a soft limit of 256 descriptors, and each forwarded connection
/// takes three (the client, our end of the vsock stream, the vsock device's end).
private func raiseDescriptorLimit() {
    var limit = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
    let wanted = min(limit.rlim_max, rlim_t(OPEN_MAX))
    guard limit.rlim_cur < wanted else { return }
    limit.rlim_cur = wanted
    _ = setrlimit(RLIMIT_NOFILE, &limit)
}

/// A listening TCP socket on the forward's host address and port.
private func listenTCP(_ forward: PortForward) throws -> Int32 {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(forward.hostPort).bigEndian)
    inet_pton(AF_INET, forward.hostAddress, &address.sin_addr)

    func bound(reuse: Bool) throws -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DMXError("daemon_error", "socket: \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        if reuse { _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size)) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result == 0, listen(fd, 128) == 0 { return fd }
        let code = errno
        Darwin.close(fd)
        if code == EADDRINUSE { return nil }
        throw DMXError("port_unavailable", "cannot listen on \(forward.hostEndpoint): \(String(cString: strerror(code)))",
                       hint: "use 127.0.0.1 or 0.0.0.0, or another port")
    }

    // Without SO_REUSEADDR a port fails while connections of an earlier listener linger in
    // TIME_WAIT; with it, macOS would let us bind 127.0.0.1 under another program's 0.0.0.0
    // listener and take its local connections. So try without, and if the port is busy, reuse it
    // only when nothing accepts connections on it.
    if let fd = try bound(reuse: false) { return fd }
    if !accepts(address), let fd = try bound(reuse: true) { return fd }
    throw DMXError("port_in_use", "host port \(forward.hostEndpoint) is in use by another program",
                   hint: "pick another host port (`dmx port add <port>:\(forward.guestPort)`), or find the owner with `lsof -nP -iTCP:\(forward.hostPort) -sTCP:LISTEN`")
}

/// Whether something accepts TCP connections at `address` (0.0.0.0 is tried as 127.0.0.1).
private func accepts(_ address: sockaddr_in) -> Bool {
    var target = address
    if target.sin_addr.s_addr == INADDR_ANY { target.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    let result = withUnsafePointer(to: &target) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    return result == 0
}

extension AgentClient {
    /// Opens a TCP connection to `port` in the guest (on `host`, loopback by default). From now
    /// on the returned connection carries the TCP stream's bytes, unframed; close it when done.
    @MainActor
    func connect(port: Int, host: String? = nil) async throws -> FrameConnection {
        struct Params: Encodable, Sendable { let port: Int; let host: String? }
        struct Connected: Decodable {}
        let connection = try await open()
        do {
            let _: Connected = try await connection.call("connect", Params(port: port, host: host))
        } catch {
            connection.close()
            throw error
        }
        return connection
    }
}

extension DaemonClient {
    /// Forwards a host port to a guest port, from now on and after daemon restarts.
    public func addPort(_ forward: PortForward) async throws -> PortForwardStatus {
        try await control.call("port_add", forward)
    }

    /// Removes the forwards on `hostPort` (only the one on `hostAddress` if given).
    public func removePort(hostPort: Int, hostAddress: String? = nil) async throws -> [PortForwardStatus] {
        struct Params: Encodable, Sendable { let hostPort: Int; let hostAddress: String? }
        let list: PortList = try await control.call("port_rm", Params(hostPort: hostPort, hostAddress: hostAddress))
        return list.forwards
    }

    public func ports() async throws -> [PortForwardStatus] {
        let list: PortList = try await control.call("port_ls", NoParams())
        return list.forwards
    }
}

extension PortForwards {
    /// Answers `port_add`, `port_rm` and `port_ls` on the control socket.
    func serve(_ method: String, id: UInt64, payload: Data, on connection: FrameConnection) throws {
        func params<P: Decodable>(_: P.Type) throws -> P {
            do {
                return try FrameConnection.decoder.decode(DaemonParams<P>.self, from: payload).params
            } catch {
                throw DMXError("bad_request", "\(method): \(error)")
            }
        }
        switch method {
        case "port_add":
            try connection.send(DaemonReply(id: id, result: try add(try params(PortForward.self))))
        case "port_rm":
            struct Params: Decodable { let hostPort: Int; let hostAddress: String? }
            let p = try params(Params.self)
            try connection.send(DaemonReply(id: id, result: PortList(forwards: try remove(hostPort: p.hostPort, hostAddress: p.hostAddress))))
        default:
            try connection.send(DaemonReply(id: id, result: PortList(forwards: list())))
        }
    }
}

// MARK: Splice

/// Copies bytes both ways between two connected stream sockets until both directions have ended.
/// A side is read only once the other side has taken everything read from it before, so a slow
/// reader holds the writer back through TCP and vsock flow control instead of bytes piling up
/// here: at most one 64 KB buffer per direction, and only while bytes are in flight. End of
/// stream on one side becomes a half close (SHUT_WR) on the other; an error on either ends both.
/// The caller closes the descriptors afterwards.
func splice(_ a: Int32, _ b: Int32) async {
    let splice = Splice(a, b)
    await withCheckedContinuation { splice.run($0) }
}

private final class Splice: @unchecked Sendable {
    static let bufferSize = 64 << 10

    /// One direction. Its reader is suspended while a buffer waits for the writer.
    private final class Direction {
        let from: Int32, to: Int32
        var reader: DispatchSourceRead?
        var writer: DispatchSourceWrite?
        var readerSuspended = false, writerResumed = false
        var buffer: UnsafeMutableRawPointer?
        var start = 0, end = 0
        var done = false

        init(from: Int32, to: Int32) { self.from = from; self.to = to }
    }

    private let a: Int32, b: Int32
    private let queue = DispatchQueue(label: "dmx.splice")
    private var directions: [Direction] = []
    /// Dispatch sources not yet cancelled; the splice ends when the last one is.
    private var sources = 0
    private var finished: CheckedContinuation<Void, Never>?

    init(_ a: Int32, _ b: Int32) { self.a = a; self.b = b }

    func run(_ continuation: CheckedContinuation<Void, Never>) {
        queue.async { [self] in
            finished = continuation
            for fd in [a, b] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
            for (from, to) in [(a, b), (b, a)] {
                let d = Direction(from: from, to: to)
                let reader = DispatchSource.makeReadSource(fileDescriptor: from, queue: queue)
                reader.setEventHandler { [unowned self] in readable(d) }
                reader.setCancelHandler { [self] in sourceCancelled() }
                d.reader = reader
                sources += 1
                directions.append(d)
            }
            for d in directions { d.reader?.resume() }
        }
    }

    private func readable(_ d: Direction) {
        // A bounded number of reads per event, so one busy direction does not starve the queue.
        for _ in 0..<16 where !d.done {
            if d.buffer == nil { d.buffer = .allocate(byteCount: Self.bufferSize, alignment: 16) }
            let n = read(d.from, d.buffer!, Self.bufferSize)
            if n > 0 {
                d.start = 0
                d.end = n
                guard flush(d) else {
                    if !d.done { waitForWriter(d) }
                    return
                }
            } else if n == 0 {
                shutdown(d.to, SHUT_WR)
                end(d)
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                // Nothing in flight: an idle connection holds no buffer.
                d.buffer?.deallocate()
                d.buffer = nil
                return
            } else {
                abort()
            }
        }
    }

    /// Writes the buffered bytes; false while some are left or after an error.
    private func flush(_ d: Direction) -> Bool {
        while d.start < d.end {
            let n = write(d.to, d.buffer! + d.start, d.end - d.start)
            if n > 0 {
                d.start += n
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && errno == EAGAIN {
                return false
            } else {
                abort()
                return false
            }
        }
        return true
    }

    private func waitForWriter(_ d: Direction) {
        d.reader?.suspend()
        d.readerSuspended = true
        if d.writer == nil {
            let writer = DispatchSource.makeWriteSource(fileDescriptor: d.to, queue: queue)
            writer.setEventHandler { [unowned self] in writable(d) }
            writer.setCancelHandler { [self] in sourceCancelled() }
            d.writer = writer
            sources += 1
        }
        d.writer?.resume()
        d.writerResumed = true
    }

    private func writable(_ d: Direction) {
        guard !d.done, flush(d) else { return }
        d.writer?.suspend()
        d.writerResumed = false
        d.reader?.resume()
        d.readerSuspended = false
    }

    /// Ends both directions after an error on either side.
    private func abort() {
        shutdown(a, SHUT_RDWR)
        shutdown(b, SHUT_RDWR)
        for d in directions where !d.done { end(d) }
    }

    private func end(_ d: Direction) {
        d.done = true
        // A suspended source never runs its cancel handler; resume before cancelling.
        if let reader = d.reader {
            if d.readerSuspended { reader.resume() }
            reader.cancel()
        }
        if let writer = d.writer {
            if !d.writerResumed { writer.resume() }
            writer.cancel()
        }
        d.buffer?.deallocate()
        d.buffer = nil
    }

    private func sourceCancelled() {
        sources -= 1
        guard sources == 0, directions.allSatisfy(\.done) else { return }
        directions.removeAll()
        finished?.resume()
        finished = nil
    }
}
