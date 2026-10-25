import Foundation

/// The host end of a forwarded UDP port: one socket bound to the host port. Each peer (address and
/// port) that sends to it gets its own vsock stream to dmx-agent (`connect` with `udp`), on which
/// datagrams travel framed as a big-endian u16 length and the bytes. The agent sends them from a
/// socket of its own to the guest port and frames the replies back, and they leave the host port
/// for that peer, so the peer sees replies from the address it sent to.
///
/// UDP has no end, so a peer's stream closes after `idleTimeout` without a datagram either way
/// (docker-proxy, in the guest behind a published port, keeps its own flows 90 s). An open stream
/// counts as using the VM, as a forwarded TCP connection does. Datagrams are dropped rather than
/// queued without bound: at most `pendingLimit` wait per peer while its stream opens, and a guest
/// that does not take them in time holds back only this port's sender, as a full socket buffer
/// would.
final class UDPRelay: @unchecked Sendable {
    static let idleTimeout: Duration = .seconds(60)
    static let pendingLimit = 64
    static let datagramLimit = 65507

    /// A peer's socket address (IPv4 or IPv6), as received.
    private struct Peer: Hashable {
        let bytes: [UInt8]
    }

    private final class Flow: @unchecked Sendable {
        let peer: sockaddr_storage
        let length: socklen_t
        var connection: FrameConnection?
        var pending: [Data] = []
        var lastActive = ContinuousClock.now
        var ended = false

        init(peer: sockaddr_storage, length: socklen_t) { self.peer = peer; self.length = length }
    }

    let forward: PortForward
    private let v6: Bool
    private var fd: Int32
    private let queue = DispatchQueue(label: "dmx.udp")
    private var source: DispatchSourceRead?
    private var sweeper: DispatchSourceTimer?
    private var flows: [Peer: Flow] = [:]
    private var total = 0
    /// Reply threads still sending from the socket, which is closed only after the last one.
    private var senders = 0
    private var cancelled = false
    private let connect: @MainActor @Sendable () async throws -> FrameConnection
    private let using: @MainActor @Sendable (Bool) -> Void

    /// Binds the host port (its IPv6 companion with `v6`); throws `port_in_use` when another
    /// program has it.
    init(_ forward: PortForward, v6: Bool = false, connect: @escaping @MainActor @Sendable () async throws -> FrameConnection,
         using: @escaping @MainActor @Sendable (Bool) -> Void) throws {
        self.forward = forward
        self.v6 = v6
        self.connect = connect
        self.using = using
        fd = try bindUDP(forward, v6: v6)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in receive() }
        source.setCancelHandler { [self] in
            cancelled = true
            closeWhenDone()
        }
        source.resume()
        self.source = source
        let sweeper = DispatchSource.makeTimerSource(queue: queue)
        sweeper.schedule(deadline: .now() + 10, repeating: 10)
        sweeper.setEventHandler { [self] in sweep() }
        sweeper.resume()
        self.sweeper = sweeper
    }

    /// Peers with an open stream, and peers since the port was bound.
    var counts: (active: Int, total: Int) { queue.sync { (flows.count, total) } }

    /// Stops listening and closes every peer's stream. Needed: the dispatch sources hold the relay until then.
    func close() {
        queue.sync {
            sweeper?.cancel()
            sweeper = nil
            source?.cancel()
            source = nil
            for flow in Array(flows.values) { end(flow) }
        }
    }

    // MARK: On the queue

    private func receive() {
        var buffer = [UInt8](repeating: 0, count: Self.datagramLimit)
        // A bounded number per event, so one busy port does not starve the others' streams.
        for _ in 0..<64 {
            var from = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { return }
            let key = withUnsafeBytes(of: &from) { Peer(bytes: Array($0.prefix(Int(length)))) }
            let flow = flows[key] ?? open(key, from, length)
            flow.lastActive = .now
            let datagram = Data(buffer[..<n])
            if let connection = flow.connection {
                send(datagram, on: connection, flow)
            } else if flow.pending.count < Self.pendingLimit {
                flow.pending.append(datagram)
            }
        }
    }

    private func open(_ key: Peer, _ peer: sockaddr_storage, _ length: socklen_t) -> Flow {
        let flow = Flow(peer: peer, length: length)
        flows[key] = flow
        total += 1
        let connect = connect, using = using
        Task { @MainActor in
            using(true)
            do {
                let connection = try await connect()
                queue.async { [self] in started(flow, connection) }
            } catch {
                log("port \(forward.endpoint(v6: v6)): \((error as? DMXError)?.message ?? "\(error)")")
                queue.async { [self] in end(flow) }
            }
        }
        return flow
    }

    private func started(_ flow: Flow, _ connection: FrameConnection) {
        guard !flow.ended else { return connection.close() }
        flow.connection = connection
        for datagram in flow.pending { send(datagram, on: connection, flow) }
        flow.pending = []
        senders += 1
        let thread = Thread { [self] in replies(flow, connection) }
        thread.stackSize = 256 << 10
        thread.start()
    }

    /// Frames one datagram onto the peer's stream. Blocks while the guest's side is full.
    private func send(_ datagram: Data, on connection: FrameConnection, _ flow: Flow) {
        var frame = Data(capacity: 2 + datagram.count)
        frame.append(UInt8(datagram.count >> 8))
        frame.append(UInt8(datagram.count & 0xff))
        frame.append(datagram)
        let ok = frame.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(connection.fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
        if !ok { end(flow) }
    }

    private func sweep() {
        for flow in Array(flows.values) where ContinuousClock.now - flow.lastActive > Self.idleTimeout {
            end(flow)
        }
    }

    /// Forgets the peer; its reply thread sees the stream end and closes it.
    private func end(_ flow: Flow) {
        guard !flow.ended else { return }
        flow.ended = true
        flows = flows.filter { $0.value !== flow }
        if let connection = flow.connection { shutdown(connection.fd, SHUT_RDWR) }
        let using = using
        Task { @MainActor in using(false) }
    }

    // MARK: Reply thread

    /// Sends the guest's framed replies to the peer until the stream ends.
    private func replies(_ flow: Flow, _ connection: FrameConnection) {
        var buffer = [UInt8](repeating: 0, count: Self.datagramLimit)
        func readExactly(_ count: Int) -> Bool {
            var offset = 0
            while offset < count {
                let n = buffer.withUnsafeMutableBytes { read(connection.fd, $0.baseAddress! + offset, count - offset) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
        var peer = flow.peer
        while readExactly(2) {
            let count = min(Int(buffer[0]) << 8 | Int(buffer[1]), Self.datagramLimit)
            guard readExactly(count) else { break }
            // A full socket buffer drops the datagram, as a network would.
            _ = withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer, count, 0, $0, flow.length)
                }
            }
            queue.async { flow.lastActive = .now }
        }
        queue.async { [self] in
            end(flow)
            connection.close()
            senders -= 1
            closeWhenDone()
        }
    }

    private func closeWhenDone() {
        guard cancelled, senders == 0, fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }
}

/// A UDP socket bound to the forward's host address and port (or its IPv6 companion). No
/// SO_REUSEADDR: on macOS it would let us bind 127.0.0.1 under another program's 0.0.0.0 socket
/// and take its datagrams.
private func bindUDP(_ forward: PortForward, v6: Bool) throws -> Int32 {
    guard let fd = try bindForward(forward, v6: v6, type: SOCK_DGRAM) else {
        throw DMXError("port_in_use", "host port \(forward.endpoint(v6: v6)) is in use by another program",
                       hint: "pick another host port, or find the owner with `lsof -nP -iUDP:\(forward.hostPort)`")
    }
    return fd
}
