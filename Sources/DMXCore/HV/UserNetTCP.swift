import Foundation

/// One TCP connection from the guest, carried by a host socket. Like passt, there is no TCP stack
/// here, only the bookkeeping to speak TCP to the guest: the host socket does the real TCP to the
/// far end. From the guest, bytes are written to the socket as they arrive in order and
/// acknowledged only once the socket took them; the window we advertise is the room left in the
/// socket's send buffer, so nothing is buffered on our side. To the guest, bytes read from the
/// socket wait in `buffer` until the guest acknowledges them (at most `sendLimit`), so we can send
/// them again if it dropped some.
final class TCPFlow {
    enum State { case connecting, synReceived, established }

    let key: UserNet.FlowKey
    var socket: NetSocket!
    var state = State.connecting

    // From the guest
    let irs: UInt32             // the guest's initial sequence number
    var rcvNext: UInt32         // the next byte we expect from the guest
    var guestFinished = false   // its FIN was taken and the socket shut down for writing

    // To the guest
    let iss: UInt32             // our initial sequence number
    var sndUna: UInt32          // the oldest byte the guest has not acknowledged: `buffer` starts here
    var sndNext: UInt32         // the next byte to send
    var sndMax: UInt32          // the highest byte sent so far, plus one
    var buffer = ByteQueue()
    var finSeq: UInt32?         // set when the host socket reached EOF
    var finAcked = false
    var guestWindow: UInt32 = 0
    var guestScale: UInt8 = 0
    var ourScale: UInt8 = 0
    var mss = 536
    var lastProgress = ContinuousClock.now
    var retries = 0
    var probes = 0
    var duplicateAcks = 0

    init(key: UserNet.FlowKey, irs: UInt32) {
        self.key = key
        self.irs = irs
        rcvNext = irs &+ 1
        iss = UInt32.random(in: .min ... .max)
        sndUna = iss
        sndNext = iss
        sndMax = iss
    }

    /// Bytes in `buffer` not sent yet.
    var unsent: Int { buffer.count - Int(Int32(bitPattern: sndNext &- sndUna)) }
}

extension UserNet {
    static let fin: UInt8 = 1, syn: UInt8 = 2, rst: UInt8 = 4, psh: UInt8 = 8, ack: UInt8 = 16
    /// Host socket send buffer: the most the guest may have in flight towards the far end.
    static let socketBuffer: Int32 = 512 << 10
    /// Bytes read from the host and not yet acknowledged by the guest, per connection.
    static let sendLimit = 256 << 10
    static let windowScale: UInt8 = 7

    /// The largest segment one frame carries: the MTU less the IP and TCP headers.
    static func mss(_ key: FlowKey) -> Int { VirtioNet.mtu - (key.remote.isV4 ? 40 : 60) }

    // MARK: From the guest

    func tcpSegment(_ p: UnsafeRawBufferPointer, to destination: IPAddress) {
        guard p.count >= 20 else { return }
        let offset = Int(p[12] >> 4) * 4
        guard offset >= 20, offset <= p.count else { return }
        let key = FlowKey(guestPort: p.u16(0), remote: destination, remotePort: p.u16(2))
        let seq = p.u32(4), ack = p.u32(8), flags = p[13], window = p.u16(14)
        let options = UnsafeRawBufferPointer(rebasing: p[20..<offset])
        let payload = UnsafeRawBufferPointer(rebasing: p[offset...])

        if let flow = tcp[key], flags & (Self.syn | Self.ack) == Self.syn, seq != flow.irs {
            remove(flow, reset: true)  // the guest reuses the port for a new connection
        }
        guard let flow = tcp[key] else {
            if flags & (Self.syn | Self.ack | Self.rst) == Self.syn {
                open(key, seq: seq, options: options)
            } else if flags & Self.rst == 0 {
                // Nothing here (any more): RFC 9293 3.10.7.1.
                let length = UInt32(payload.count) + (flags & Self.syn != 0 ? 1 : 0) + (flags & Self.fin != 0 ? 1 : 0)
                if flags & Self.ack != 0 {
                    send(key, seq: ack, ack: 0, flags: Self.rst, window: 0)
                } else {
                    send(key, seq: 0, ack: seq &+ length, flags: Self.rst | Self.ack, window: 0)
                }
            }
            return
        }
        if flags & Self.rst != 0 { return remove(flow, reset: true) }
        if flags & Self.syn != 0 {
            // The guest sent its SYN again: our SYN-ACK may not have reached it.
            if flow.state == .synReceived { sendSynAck(flow) }
            return
        }
        switch flow.state {
        case .connecting:
            return
        case .synReceived:
            guard flags & Self.ack != 0, ack == flow.iss &+ 1 else { return }
            flow.state = .established
            flow.sndUna = ack
            flow.sndNext = ack
            flow.sndMax = ack
            flow.retries = 0
        case .established:
            break
        }

        if flags & Self.ack != 0 {
            acknowledged(flow, ack: ack, window: UInt32(window) << flow.guestScale,
                         pure: payload.isEmpty && flags & Self.fin == 0)
        }
        if payload.isEmpty && flags & Self.fin == 0 {
            // A segment from before what we have is a window probe (Linux sends rcvNext - 1):
            // answer it with our window.
            if seq != flow.rcvNext { send(flow, seq: flow.sndNext, flags: Self.ack) }
        } else {
            let already = Int32(bitPattern: flow.rcvNext &- seq)  // bytes of this segment we have
            if already >= 0 && !flow.guestFinished {
                let skip = Int(already)
                if skip < payload.count {
                    let n = write(flow.socket.fd, payload.baseAddress! + skip, payload.count - skip)
                    if n > 0 { flow.rcvNext &+= UInt32(n) }
                    if n < 0 && errno != EAGAIN && errno != EINTR {
                        send(flow, seq: flow.sndNext, flags: Self.rst | Self.ack)
                        return remove(flow, reset: true)
                    }
                }
                if flags & Self.fin != 0 && flow.rcvNext == seq &+ UInt32(payload.count) {
                    flow.rcvNext &+= 1
                    flow.guestFinished = true
                    shutdown(flow.socket.fd, SHUT_WR)
                }
            }
            // In order or not, acknowledge what we have: a gap makes the guest send again.
            send(flow, seq: flow.sndNext, flags: Self.ack)
        }
        pump(flow)
        closeIfDone(flow)
    }

    private func open(_ key: FlowKey, seq: UInt32, options: UnsafeRawBufferPointer) {
        let flow = TCPFlow(key: key, irs: seq)
        guard tcp.count < Self.maxTCP, let endpoint = endpoint(for: key.remote, port: key.remotePort) else {
            return send(key, seq: 0, ack: seq &+ 1, flags: Self.rst | Self.ack, window: 0)
        }
        // Options: MSS and window scale; SACK and timestamps are left off.
        var i = 0
        while i < options.count {
            let kind = options[i]
            if kind == 0 { break }
            if kind == 1 { i += 1; continue }
            guard i + 1 < options.count, options[i + 1] >= 2, i + Int(options[i + 1]) <= options.count else { break }
            if kind == 2 && options[i + 1] == 4 { flow.mss = Int(options.u16(i + 2)) }
            if kind == 3 && options[i + 1] == 3 {
                flow.guestScale = min(options[i + 2], 14)
                flow.ourScale = Self.windowScale
            }
            i += Int(options[i + 1])
        }
        flow.mss = max(64, min(flow.mss, Self.mss(key)))

        let fd = Darwin.socket(endpoint.family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return send(key, seq: 0, ack: seq &+ 1, flags: Self.rst | Self.ack, window: 0) }
        var on: Int32 = 1, size = Self.socketBuffer, low = Self.socketBuffer / 2
        let intSize = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, intSize)  // the guest's stack already batches
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, intSize)
        setsockopt(fd, SOL_SOCKET, SO_SNDLOWAT, &low, intSize)  // window updates in large steps
        flow.socket = NetSocket(fd: fd, queue: queue,
                                onRead: { [unowned self, unowned flow] in self.readHost(flow) },
                                onWrite: { [unowned self, unowned flow] in self.hostWritable(flow) })
        tcp[key] = flow
        startTimer()
        if endpoint.withSockaddr({ Darwin.connect(fd, $0, $1) }) == 0 || errno == EINPROGRESS {
            flow.socket.writing = true  // fires once connected, or failed
        } else {
            send(key, seq: 0, ack: seq &+ 1, flags: Self.rst | Self.ack, window: 0)
            remove(flow, reset: false)
        }
    }

    /// The guest acknowledged up to `ack` and has room for `window` bytes.
    private func acknowledged(_ flow: TCPFlow, ack: UInt32, window: UInt32, pure: Bool) {
        let acked = Int32(bitPattern: ack &- flow.sndUna)
        if acked > 0 && Int32(bitPattern: flow.sndMax &- ack) >= 0 {
            var bytes = Int(acked)
            if let fin = flow.finSeq, ack == fin &+ 1 {
                flow.finAcked = true
                bytes -= 1
            }
            flow.buffer.removeFirst(min(bytes, flow.buffer.count))
            flow.sndUna = ack
            if Int32(bitPattern: ack &- flow.sndNext) > 0 { flow.sndNext = ack }
            flow.lastProgress = .now
            flow.retries = 0
            flow.duplicateAcks = 0
        } else if acked == 0 && pure && flow.sndNext != flow.sndUna && window == flow.guestWindow {
            // Three duplicate ACKs: a segment got lost; send again from the oldest unacknowledged.
            flow.duplicateAcks += 1
            if flow.duplicateAcks == 3 { flow.sndNext = flow.sndUna }
        }
        if window > 0 { flow.probes = 0 }
        flow.guestWindow = window
    }

    // MARK: From the host

    private func hostWritable(_ flow: TCPFlow) {
        guard tcp[flow.key] === flow else { return }
        flow.socket.writing = false
        guard flow.state == .connecting else {
            return send(flow, seq: flow.sndNext, flags: Self.ack)  // window update
        }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(flow.socket.fd, SOL_SOCKET, SO_ERROR, &error, &length)
        if error != 0 {
            send(flow.key, seq: 0, ack: flow.rcvNext, flags: Self.rst | Self.ack, window: 0)
            return remove(flow, reset: false)
        }
        flow.state = .synReceived
        sendSynAck(flow)
    }

    private func sendSynAck(_ flow: TCPFlow) {
        var options: [UInt8] = [2, 4]
        options.be16(UInt16(Self.mss(flow.key)))
        if flow.ourScale > 0 { options += [1, 3, 3, flow.ourScale] }
        send(flow, seq: flow.iss, flags: Self.syn | Self.ack, options: options)
        flow.sndNext = flow.iss &+ 1
        flow.sndMax = flow.sndNext
        flow.lastProgress = .now
    }

    private func readHost(_ flow: TCPFlow) {
        guard tcp[flow.key] === flow else { return }
        let room = Self.sendLimit - flow.buffer.count
        guard room > 0, flow.finSeq == nil else {
            flow.socket.reading = false
            return
        }
        let n = read(flow.socket.fd, &scratch, min(room, scratch.count))
        if n > 0 {
            flow.buffer.append(contentsOf: scratch[0..<n])
        } else if n == 0 {
            flow.finSeq = flow.sndUna &+ UInt32(flow.buffer.count)
        } else if errno != EAGAIN && errno != EINTR {
            send(flow, seq: flow.sndNext, flags: Self.rst | Self.ack)
            return remove(flow, reset: true)
        }
        pump(flow)
        closeIfDone(flow)
    }

    /// Sends the guest what its window takes, then the FIN once the host socket is done, and reads
    /// more from the host while there is room.
    private func pump(_ flow: TCPFlow) {
        guard flow.state == .established else { return }
        while device.hasRoom {
            let inFlight = Int(Int32(bitPattern: flow.sndNext &- flow.sndUna))
            let unsent = flow.buffer.count - inFlight
            if unsent <= 0 {
                if let fin = flow.finSeq, flow.sndNext == fin {
                    if inFlight == 0 { flow.lastProgress = .now }
                    send(flow, seq: fin, flags: Self.fin | Self.ack)
                    flow.sndNext = fin &+ 1
                    if Int32(bitPattern: flow.sndNext &- flow.sndMax) > 0 { flow.sndMax = flow.sndNext }
                }
                break
            }
            let n = min(unsent, Int(flow.guestWindow) - inFlight, flow.mss)
            if n <= 0 { break }
            if inFlight == 0 { flow.lastProgress = .now }
            flow.buffer.withUnsafeBytes { bytes in
                send(flow, seq: flow.sndNext, flags: Self.ack | Self.psh,
                     payload: UnsafeRawBufferPointer(rebasing: bytes[inFlight..<(inFlight + n)]))
            }
            flow.sndNext &+= UInt32(n)
            if Int32(bitPattern: flow.sndNext &- flow.sndMax) > 0 { flow.sndMax = flow.sndNext }
        }
        flow.socket.reading = flow.finSeq == nil && flow.buffer.count < Self.sendLimit
    }

    /// The virtio queue has room again: lets every connection send.
    func resume() {
        for flow in Array(tcp.values) where flow.unsent > 0 || flow.finSeq == flow.sndNext {
            guard device.hasRoom else { return }
            pump(flow)
        }
    }

    private func closeIfDone(_ flow: TCPFlow) {
        if flow.guestFinished && flow.finAcked { remove(flow, reset: false) }
    }

    private func remove(_ flow: TCPFlow, reset: Bool) {
        flow.socket?.close(reset: reset)
        if tcp[flow.key] === flow { tcp[flow.key] = nil }
    }

    /// Sends what the guest has not acknowledged in time again, and probes a closed window.
    func tcpTick(_ now: ContinuousClock.Instant) {
        for flow in Array(tcp.values) {
            let timeout = Duration.milliseconds(250 << min(max(flow.retries, flow.probes), 4))
            guard now - flow.lastProgress > timeout else { continue }
            switch flow.state {
            case .connecting:
                continue  // the host's connect times out by itself
            case .synReceived:
                sendSynAck(flow)
            case .established:
                if flow.guestWindow == 0 && flow.buffer.count > 0 {
                    // Zero window probe: the oldest byte again, past the window; the guest answers
                    // with its window. A guest that does not read for a long time is no reason to
                    // give up, so probes do not count as retries.
                    // The guest drops it if it has no room, so the next send starts at the same byte;
                    // if it took it, its ACK moves `sndNext` on.
                    flow.buffer.withUnsafeBytes { bytes in
                        send(flow, seq: flow.sndUna, flags: Self.ack, payload: UnsafeRawBufferPointer(rebasing: bytes[0..<1]))
                    }
                    flow.sndNext = flow.sndUna
                    if Int32(bitPattern: flow.sndUna &+ 1 &- flow.sndMax) > 0 { flow.sndMax = flow.sndUna &+ 1 }
                    flow.lastProgress = now
                    flow.probes += 1
                    continue
                }
                guard flow.sndMax != flow.sndUna else { continue }
                flow.sndNext = flow.sndUna
                flow.lastProgress = now
                pump(flow)
            }
            flow.retries += 1
            if flow.retries > 10 {  // about 30 s without an answer: the guest is gone
                send(flow, seq: flow.sndNext, flags: Self.rst | Self.ack)
                remove(flow, reset: true)
            }
        }
    }

    // MARK: To the guest

    /// A segment on `flow`, acknowledging what we have and advertising the room in its socket.
    private func send(_ flow: TCPFlow, seq: UInt32, flags: UInt8, options: [UInt8] = [],
                      payload: UnsafeRawBufferPointer = UnsafeRawBufferPointer(start: nil, count: 0)) {
        var room = Self.socketBuffer
        if flow.state != .connecting {
            var queued: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(flow.socket.fd, SOL_SOCKET, SO_NWRITE, &queued, &length)
            room = max(0, Self.socketBuffer - queued)
        }
        if flow.guestFinished { room = 0 }
        // Little room: the write source fires once half the buffer is free (SO_SNDLOWAT), and
        // `hostWritable` sends the window update. Without it the guest would wait on its probes.
        if flow.state == .established && !flow.guestFinished && room < Self.socketBuffer / 2 { flow.socket.writing = true }
        let scale = flags & Self.syn != 0 ? 0 : flow.ourScale
        send(flow.key, seq: seq, ack: flow.rcvNext, flags: flags, window: UInt16(min(Int(room) >> Int(scale), 65535)),
             options: options, payload: payload)
    }

    private func send(_ key: FlowKey, seq: UInt32, ack: UInt32, flags: UInt8, window: UInt16, options: [UInt8] = [],
                      payload: UnsafeRawBufferPointer = UnsafeRawBufferPointer(start: nil, count: 0)) {
        var h: [UInt8] = []
        h.reserveCapacity(20 + options.count)
        h.be16(key.remotePort); h.be16(key.guestPort); h.be32(seq); h.be32(ack)
        h.append(UInt8((20 + options.count) / 4) << 4); h.append(flags); h.be16(window)
        h.be16(0); h.be16(0)  // checksum, urgent pointer
        h += options
        device.send(ipFrame(protocol: 6, from: key.remote, transport: h, payload: payload))
    }
}
