import Foundation

/// virtio-vsock (device 19, virtio 1.x section 5.10), stream sockets only. The host end of each
/// connection is one end of a Unix socketpair, so code that speaks over a socket descriptor
/// (`AgentConnection`) works unchanged. All state lives on one serial queue.
final class VirtioVsock: VirtioDevice, @unchecked Sendable {
    static let hostCID: UInt64 = 2
    static let guestCID: UInt64 = 3
    /// How much the guest may send us before we report it consumed (our receive window).
    static let bufferSize: UInt32 = 256 << 10

    let deviceID: UInt32 = 19
    let features: UInt64 = 0
    let queueSizes: [UInt16] = [128, 128, 16]  // rx (to the guest), tx (from it), event

    private let queue = DispatchQueue(label: "dmx.vsock")
    private var transport: VirtioMMIO?
    private var connections: [Key: Connection] = [:]
    private var control: [Header] = []  // payload-free packets waiting for an rx buffer
    private var nextPort: UInt32 = 49152

    private struct Key: Hashable {
        let local: UInt32  // host port
        let peer: UInt32   // guest port
    }

    private enum Op: UInt16 {
        case request = 1, response, rst, shutdown, rw, creditUpdate, creditRequest
    }

    private struct Header {
        static let size = 44
        var srcCID: UInt64, dstCID: UInt64, srcPort: UInt32, dstPort: UInt32
        var len: UInt32, type: UInt16, op: UInt16, flags: UInt32, bufAlloc: UInt32, fwdCnt: UInt32

        init(srcCID: UInt64 = VirtioVsock.hostCID, dstCID: UInt64 = VirtioVsock.guestCID, srcPort: UInt32,
             dstPort: UInt32, len: UInt32 = 0, op: Op, flags: UInt32 = 0, fwdCnt: UInt32 = 0) {
            self.srcCID = srcCID; self.dstCID = dstCID; self.srcPort = srcPort; self.dstPort = dstPort
            self.len = len; self.type = 1; self.op = op.rawValue; self.flags = flags
            self.bufAlloc = VirtioVsock.bufferSize; self.fwdCnt = fwdCnt
        }

        init?(_ d: Data) {
            guard d.count >= Self.size else { return nil }
            func u<T: FixedWidthInteger>(_ o: Int, _: T.Type) -> T {
                d.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: T.self)) }
            }
            srcCID = u(0, UInt64.self); dstCID = u(8, UInt64.self)
            srcPort = u(16, UInt32.self); dstPort = u(20, UInt32.self); len = u(24, UInt32.self)
            type = u(28, UInt16.self); op = u(30, UInt16.self); flags = u(32, UInt32.self)
            bufAlloc = u(36, UInt32.self); fwdCnt = u(40, UInt32.self)
        }

        var bytes: Data {
            var d = Data(capacity: Self.size)
            func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            put(srcCID); put(dstCID); put(srcPort); put(dstPort); put(len)
            put(type); put(op); put(flags); put(bufAlloc); put(fwdCnt)
            return d
        }
    }

    private final class Connection {
        let key: Key
        let fd: Int32  // our end of the socketpair, non-blocking
        var connecting: CheckedContinuation<Int32, Error>?
        var hostFD: Int32 = -1
        var readSource: DispatchSourceRead?
        var writeSource: DispatchSourceWrite?
        var readPaused = false, writeArmed = false
        var outbox = ByteQueue() // read from the host, not yet sent to the guest
        var inbox = ByteQueue()  // from the guest, not yet written to the host
        var txCount: UInt32 = 0  // bytes sent to the guest
        var fwdCount: UInt32 = 0 // bytes from the guest that reached the host socket
        var advertised: UInt32 = 0
        var peerBufAlloc: UInt32 = 0, peerFwdCount: UInt32 = 0
        var hostClosed = false, guestClosedSend = false, guestClosed = false
        /// Dispatch sources still using `fd`; it is closed when the last one is cancelled.
        var sources = 0

        func sourceDone() {
            sources -= 1
            if sources == 0 { close(fd) }
        }

        init(key: Key, fd: Int32) { self.key = key; self.fd = fd }

        var credit: Int { Int(peerBufAlloc) - Int(txCount &- peerFwdCount) }
    }

    // MARK: VirtioDevice

    func activate(_ transport: VirtioMMIO, features: UInt64) {
        queue.async {
            self.transport = transport
            self.deliver()
        }
    }

    func reset() {
        queue.async {
            for c in Array(self.connections.values) { self.drop(c, error: DMXError("agent_disconnected", "the guest reset its vsock device")) }
            self.control.removeAll()
            self.transport = nil
        }
    }

    func notify(queue index: Int) {
        queue.async {
            switch index {
            case 0: self.deliver()
            case 1: self.receiveFromGuest()
            default: break  // the event queue: we never send events
            }
        }
    }

    /// The VM stopped: closes every stream, so whoever waits on one reads EOF instead of hanging.
    func closeAll() {
        queue.async {
            for c in Array(self.connections.values) { self.drop(c, error: DMXError("vm_stopped", "the VM stopped")) }
        }
    }

    // MARK: Host side

    /// Opens a stream to `port` in the guest. Returns the host end of a connected socket.
    func connect(port: UInt32, timeout: Duration = .seconds(1)) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var fds: [Int32] = [0, 0]
                guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
                    return continuation.resume(throwing: DMXError("vm_error", "socketpair: \(String(cString: strerror(errno)))"))
                }
                for fd in fds {
                    var on: Int32 = 1, size: Int32 = 1 << 20
                    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
                    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
                }
                _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
                let key = Key(local: self.allocatePort(), peer: port)
                let c = Connection(key: key, fd: fds[0])
                c.hostFD = fds[1]
                c.connecting = continuation
                self.connections[key] = c
                self.send(c, .request)
                self.queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000))) {
                    if let c = self.connections[key], c.connecting != nil {
                        self.send(c, .rst)
                        self.drop(c, error: DMXError("agent_unreachable", "vsock connect to port \(port): no answer from the guest"))
                    }
                }
            }
        }
    }

    private func allocatePort() -> UInt32 {
        while connections.keys.contains(where: { $0.local == nextPort }) { nextPort = nextPort == .max ? 49152 : nextPort + 1 }
        defer { nextPort = nextPort == .max ? 49152 : nextPort + 1 }
        return nextPort
    }

    private func startPumping(_ c: Connection) {
        let source = DispatchSource.makeReadSource(fileDescriptor: c.fd, queue: queue)
        source.setEventHandler { [unowned self] in self.readFromHost(c) }
        source.setCancelHandler { c.sourceDone() }
        c.sources += 1
        c.readSource = source
        source.resume()
    }

    private func readFromHost(_ c: Connection) {
        guard connections[c.key] === c else { return }
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        let n = read(c.fd, &buffer, buffer.count)
        if n > 0 {
            c.outbox.append(contentsOf: buffer[0..<n])
            if c.outbox.count >= 256 << 10 { pauseReading(c) }
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            c.hostClosed = true
            pauseReading(c)
        }
        deliver()
    }

    private func pauseReading(_ c: Connection) {
        guard !c.readPaused, let source = c.readSource else { return }
        c.readPaused = true
        source.suspend()
    }

    private func resumeReading(_ c: Connection) {
        guard c.readPaused, !c.hostClosed, let source = c.readSource else { return }
        c.readPaused = false
        source.resume()
    }

    /// Writes what the guest sent to the host socket, as far as it takes it.
    private func flushInbox(_ c: Connection) {
        while !c.inbox.isEmpty {
            let n = c.inbox.withUnsafeBytes { write(c.fd, $0.baseAddress!, $0.count) }
            if n > 0 {
                c.inbox.removeFirst(n)
                c.fwdCount &+= UInt32(n)
            } else if n < 0 && errno == EAGAIN {
                if !c.writeArmed {
                    c.writeArmed = true
                    if c.writeSource == nil {
                        let source = DispatchSource.makeWriteSource(fileDescriptor: c.fd, queue: queue)
                        source.setEventHandler { [unowned self] in
                            c.writeArmed = false
                            c.writeSource?.suspend()
                            self.flushInbox(c)
                        }
                        source.setCancelHandler { c.sourceDone() }
                        c.sources += 1
                        c.writeSource = source
                    }
                    c.writeSource!.resume()
                }
                return
            } else {
                c.inbox.removeAll()  // the host end is gone; RST follows when it reads EOF
                return
            }
        }
        // Everything the guest sent has reached the host socket.
        if c.guestClosed { return drop(c, error: nil) }
        if c.guestClosedSend { shutdown(c.fd, SHUT_WR) }
        // Tell the guest about freed window before it runs dry.
        if c.fwdCount &- c.advertised >= Self.bufferSize / 4 { send(c, .creditUpdate) }
    }

    // MARK: Guest side

    private func receiveFromGuest() {
        guard let transport else { return }
        var packets: [(Header, Data)] = []
        transport.lock.lock()
        while let chain = transport.queues[1].pop() {
            let bytes = chain.readableBytes
            if let header = Header(bytes) {
                packets.append((header, bytes.dropFirst(Header.size).prefix(Int(header.len))))
            }
            transport.queues[1].push(chain, written: 0)
        }
        transport.lock.unlock()
        if !packets.isEmpty { transport.signalUsed() }

        for (h, payload) in packets where h.type == 1 && h.dstCID == Self.hostCID {
            let key = Key(local: h.dstPort, peer: h.srcPort)
            guard let c = connections[key] else {
                // No such stream (or the guest is connecting to the host, unsupported yet).
                if h.op != Op.rst.rawValue {
                    control.append(Header(srcPort: h.dstPort, dstPort: h.srcPort, op: .rst))
                }
                continue
            }
            c.peerBufAlloc = h.bufAlloc
            c.peerFwdCount = h.fwdCnt
            switch Op(rawValue: h.op) {
            case .response:
                if let continuation = c.connecting {
                    c.connecting = nil
                    startPumping(c)
                    continuation.resume(returning: c.hostFD)
                }
            case .rw:
                c.inbox.append(contentsOf: payload)
                flushInbox(c)
            case .creditRequest:
                send(c, .creditUpdate)
            case .shutdown:
                // Both directions done: confirm with RST, but close only once the host has
                // everything the guest sent.
                if h.flags & 3 == 3 {
                    c.guestClosed = true
                    send(c, .rst)
                }
                if h.flags & 2 != 0 { c.guestClosedSend = true }
                flushInbox(c)
            case .rst:
                drop(c, error: DMXError("agent_unreachable", "vsock connect to port \(c.key.peer): refused by the guest"))
            default:
                break  // credit update: handled above
            }
        }
        deliver()
    }

    /// Queues a payload-free packet for `c`, carrying our current credit.
    private func send(_ c: Connection, _ op: Op, flags: UInt32 = 0) {
        control.append(Header(srcPort: c.key.local, dstPort: c.key.peer, op: op, flags: flags, fwdCnt: c.fwdCount))
        if op != .rst { c.advertised = c.fwdCount }
        deliver()
    }

    /// Fills the guest's rx buffers: control packets first, then data while credit lasts.
    private func deliver() {
        guard let transport else { return }
        var used = false
        transport.lock.lock()
        while true {
            if !control.isEmpty {
                guard let chain = transport.queues[0].pop() else { break }
                let n = chain.write(control.removeFirst().bytes)
                transport.queues[0].push(chain, written: n)
                used = true
                continue
            }
            guard let c = connections.values.first(where: { !$0.outbox.isEmpty && $0.credit > 0 && $0.connecting == nil }),
                  let chain = transport.queues[0].pop() else { break }
            let room = chain.writableCapacity - Header.size
            guard room > 0 else { transport.queues[0].push(chain, written: 0); used = true; continue }
            let count = min(c.outbox.count, c.credit, room)
            let payload = c.outbox.prefix(count)
            c.outbox.removeFirst(count)
            c.txCount &+= UInt32(count)
            c.advertised = c.fwdCount
            let header = Header(srcPort: c.key.local, dstPort: c.key.peer, len: UInt32(count), op: .rw, fwdCnt: c.fwdCount)
            transport.queues[0].push(chain, written: chain.write(header.bytes + payload))
            used = true
        }
        transport.lock.unlock()
        if used { transport.signalUsed() }

        for c in Array(connections.values) {
            if c.outbox.count < 64 << 10 { resumeReading(c) }
            if c.hostClosed && c.outbox.isEmpty && c.connecting == nil && !c.guestClosed {
                control.append(Header(srcPort: c.key.local, dstPort: c.key.peer, op: .rst))
                drop(c, error: nil)
                deliver()
                return
            }
        }
    }

    private func drop(_ c: Connection, error: DMXError?) {
        connections[c.key] = nil
        if let continuation = c.connecting {
            c.connecting = nil
            close(c.hostFD)
            continuation.resume(throwing: error ?? DMXError("agent_disconnected", "vsock connection closed"))
        }
        if let source = c.readSource {
            if c.readPaused { source.resume() }
            source.cancel()
        }
        if let source = c.writeSource {
            if !c.writeArmed { source.resume() }
            source.cancel()
        }
        if c.sources == 0 { close(c.fd) }
    }
}

/// Bytes waiting to cross a connection in one direction. `Data.removeFirst` only moves the start
/// of the data and keeps the consumed front allocated, so a long stream through a `Data` grows
/// it by everything that ever passed. This reuses consumed space instead: it holds about twice
/// its largest backlog however much passes through.
struct ByteQueue {
    private var storage: [UInt8] = []
    private var head = 0

    var count: Int { storage.count - head }
    var isEmpty: Bool { head == storage.count }

    mutating func append<S: Sequence>(contentsOf bytes: S) where S.Element == UInt8 {
        if head > 0 && head >= storage.count / 2 {
            storage.removeFirst(head)
            head = 0
        }
        storage.append(contentsOf: bytes)
    }

    mutating func removeFirst(_ n: Int) {
        head += n
        if head == storage.count { removeAll() }
    }

    /// Keeps up to 1 MB of capacity for the next burst; a larger buffer goes back to the system.
    mutating func removeAll() {
        storage.removeAll(keepingCapacity: storage.capacity <= 1 << 20)
        head = 0
    }

    func prefix(_ n: Int) -> Data { Data(storage[head..<(head + min(n, count))]) }

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try storage.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0[head...])) }
    }
}
