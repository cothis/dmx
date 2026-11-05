import Foundation

/// Names the gateway's DNS answers itself instead of asking the host's resolver: Docker
/// Desktop's `host.docker.internal` (the Mac, whose 127.0.0.1 and ::1 are 192.168.127.254 and
/// fd64:646d:7800::254 to the guest) and `gateway.docker.internal`, plus dmx's own `host.dmx.internal`. Containers resolve them
/// through the gateway like any name: directly on the default bridge, through dockerd's embedded
/// DNS on other networks. The guest's /etc/hosts has them too, for dockerd itself.
enum LocalDNS {
    static let names: [String: (v4: IPAddress, v6: IPAddress)] = [
        "host.docker.internal": (UserNet.host, UserNet.host6),
        "gateway.docker.internal": (UserNet.gateway, UserNet.gateway6),
        "host.dmx.internal": (UserNet.host, UserNet.host6),
    ]
    static let ttl: UInt32 = 60

    /// The reply to a query for one of `names`, or nil to forward the query. A and AAAA queries get
    /// the address; any other type for these names gets an empty answer.
    static func answer(_ query: UnsafeRawBufferPointer) -> [UInt8]? {
        // Header: id, flags, then counts. One question, a standard query, not a response.
        guard query.count >= 17, query[2] & 0xf8 == 0, query.u16(4) == 1 else { return nil }
        var offset = 12
        var labels: [String] = []
        while true {
            guard offset < query.count else { return nil }
            let length = Int(query[offset])
            offset += 1
            if length == 0 { break }
            guard length < 64, offset + length <= query.count else { return nil }
            labels.append(String(decoding: UnsafeRawBufferPointer(rebasing: query[offset..<offset + length]), as: UTF8.self).lowercased())
            offset += length
        }
        guard offset + 4 <= query.count, let addresses = names[labels.joined(separator: ".")] else { return nil }
        let type = query.u16(offset), qclass = query.u16(offset + 2)
        guard qclass == 1 else { return nil }
        let questionEnd = offset + 4
        let rdata: [UInt8]? = switch type {
        case 1: withUnsafeBytes(of: addresses.v4.v4.bigEndian) { Array($0) }
        case 28: addresses.v6.bytes
        default: nil
        }

        var reply: [UInt8] = []
        reply.be16(query.u16(0))
        // QR, authoritative, recursion desired as asked, recursion available; no error.
        reply.be16(0x8480 | UInt16(query[2] & 0x01) << 8)
        reply.be16(1)
        reply.be16(rdata == nil ? 0 : 1)
        reply.be16(0)
        reply.be16(0)
        reply.append(contentsOf: query[12..<questionEnd])
        if let rdata {
            reply.be16(0xc00c)  // the name in the question
            reply.be16(type)
            reply.be16(1)
            reply.be32(ttl)
            reply.be16(UInt16(rdata.count))
            reply += rdata
        }
        return reply
    }
}

/// One DNS over TCP connection from the guest to the gateway, at the far end of a socket pair
/// whose near end a `TCPFlow` carries. It gets what DNS over UDP gets: a client that retries over
/// TCP after a truncated reply reaches the same resolver, with the same answer to an AAAA query
/// that a network never answers. glibc sends both families' queries on the retry and fails the
/// whole lookup if the connection breaks waiting for one, so a retry to another server was enough
/// to fail a name whose A record was fine. Replies go out in the order of the queries (RFC 7766
/// allows any order, but not every client takes it). At most `maxInFlight` queries wait at once;
/// past that the socket is not read.
final class DNSConnection {
    static let maxInFlight = 16
    /// The largest reply a two-byte length can frame.
    static let maxReply = 65535
    static let maxBuffered = 256 << 10

    private final class Slot { var reply: [UInt8]? }

    private let answer: (UnsafeRawBufferPointer, @escaping ([UInt8]) -> Void) -> Void
    private let finished: (DNSConnection) -> Void
    private var socket: NetSocket!
    private var input: [UInt8] = []
    private var output = ByteQueue()
    private var slots: [Slot] = []
    private var ended = false
    private var closed = false
    private var advancing = false
    private(set) var lastUsed = ContinuousClock.now

    init(fd: Int32, queue: DispatchQueue,
         answer: @escaping (UnsafeRawBufferPointer, @escaping ([UInt8]) -> Void) -> Void,
         finished: @escaping (DNSConnection) -> Void) {
        self.answer = answer
        self.finished = finished
        socket = NetSocket(fd: fd, queue: queue, onRead: { [unowned self] in self.readable() },
                           onWrite: { [unowned self] in self.advance() })
        socket.reading = true
    }

    /// No query is waiting, so closing loses nothing.
    var idle: Bool { slots.isEmpty && output.count == 0 }

    func close() {
        guard !closed else { return }
        closed = true
        socket.close()
        finished(self)
    }

    private func readable() {
        guard !closed else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let n = read(socket.fd, &bytes, bytes.count)
        if n > 0 {
            input.append(contentsOf: bytes[0..<n])
            lastUsed = .now
        } else if n == 0 {
            ended = true
        } else if errno != EAGAIN && errno != EINTR {
            return close()
        }
        advance()
    }

    /// Whether another query may start: it is limited by the queries waiting and by replies the
    /// guest has not read, so a guest that only sends cannot grow what is held here.
    private var hasRoom: Bool { slots.count < Self.maxInFlight && output.count < Self.maxBuffered }

    /// Starts the queries that have arrived and writes the replies that are ready, in order.
    /// A reply can arrive while a query is being started, so this does not nest.
    private func advance() {
        guard !closed, !advancing else { return }
        advancing = true
        defer { advancing = false }
        var progress = true
        while progress {
            progress = false
            if hasRoom, input.count >= 2 {
                let length = Int(input[0]) << 8 | Int(input[1])
                // Shorter than a DNS header there is no id to answer with.
                if length < 12 { return close() }
                if input.count >= 2 + length {
                    let slot = Slot()
                    slots.append(slot)
                    let query = Array(input[2..<2 + length])
                    input.removeFirst(2 + length)
                    query.withUnsafeBytes { bytes in
                        answer(bytes) { [weak self] reply in
                            slot.reply = reply
                            self?.lastUsed = .now
                            self?.advance()
                        }
                    }
                    progress = true
                }
            }
            while let reply = slots.first?.reply {
                slots.removeFirst()
                output.append(contentsOf: [UInt8(reply.count >> 8), UInt8(reply.count & 0xff)])
                output.append(contentsOf: reply)
            }
            if output.count > 0 {
                let n = output.withUnsafeBytes { write(socket.fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    output.removeFirst(n)
                    progress = true
                } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                    return close()
                }
            }
        }
        socket.writing = output.count > 0
        socket.reading = !ended && hasRoom
        if ended && idle && input.count < 2 { close() }
    }

    /// The reply to a query that cannot be resolved: its id, `code` and nothing else.
    static func failure(_ query: UnsafeRawBufferPointer, code: UInt8) -> [UInt8] {
        var m: [UInt8] = []
        m.be16(query.u16(0))
        m.be16(0x8080 | UInt16(query[2] & 0x01) << 8 | UInt16(code))
        for _ in 0..<4 { m.be16(0) }
        return m
    }
}
