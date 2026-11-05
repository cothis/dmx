import Foundation
import dnssd

/// Answers the guest's DNS queries with macOS's own resolver (mDNSResponder, through
/// `DNSServiceQueryRecord`), so the guest gets what any Mac app gets: the per-domain servers a VPN
/// adds (split DNS, e.g. a company's intranet names), `.local` names over multicast DNS, and the
/// servers of the network the Mac is on now, not the one it was on at boot. CNAMEs come back as
/// intermediate records, so the reply carries the whole chain as a recursive server's would.
/// Everything runs on the network queue. UDP queries it cannot represent (more than one question,
/// an opcode other than QUERY) go to the first nameserver of /etc/resolv.conf as before. DNS over
/// TCP, which a client uses after a reply too large for UDP came back truncated, gets the same
/// answers as UDP (`DNSConnection`): a retry must not ask a different server a different way.
///
/// Some networks never answer AAAA queries. Mac apps do not notice, but musl fails a whole name
/// lookup when either family's query fails (glibc needs only one), so a static uv in a container
/// could not resolve a name whose A record was fine. Once a name's A lookup has found an address,
/// its AAAA lookup waits only `aaaaGrace` longer and then reports no AAAA records. The guest
/// prefers IPv4 for names with both families, so a late AAAA costs it nothing.
///
/// An AAAA query with no A query beside it (`AF_INET6`) has no such answer to end its wait, and would
/// fail after `timeout` on a name that exists. So it starts an A lookup of its own. When that finds an
/// address the AAAA waits `loneAAAAGrace` longer and then reports no AAAA records. This client asked
/// for IPv6 alone, so a real AAAA that comes late is its only answer: hence the longer wait.
final class HostDNS {
    private let queue: DispatchQueue
    private var pending: [ObjectIdentifier: Lookup] = [:]
    private var addresses = RecentAddresses()
    /// A query unanswered for this long gets SERVFAIL; the client then retries or gives up.
    static let timeout: Duration = .seconds(5)
    /// How long an AAAA lookup waits once the name is known to have an IPv4 address.
    static let aaaaGrace: Duration = .milliseconds(300)
    /// The same, for an AAAA query with no A query beside it.
    static let loneAAAAGrace: Duration = .seconds(1)
    static let maxPending = 256

    init(queue: DispatchQueue) { self.queue = queue }

    /// Starts resolving `query`, a DNS message from the guest; `reply` gets the response on the
    /// queue. `limit` is the largest reply to send, by default what the client takes over UDP.
    /// False when the query is not one this handles.
    func resolve(_ query: UnsafeRawBufferPointer, limit: Int? = nil, reply: @escaping ([UInt8]) -> Void) -> Bool {
        guard let question = Question(query), pending.count < Self.maxPending else { return false }
        let lookup = Lookup(question: question, limit: limit ?? question.udpLimit, queue: queue, reply: reply)
        // A client that asks for AAAA after its A query was answered (or whose queries the
        // answer overtook) gets the same bound as one with both in flight.
        let addressKnown = question.isAAAA && addresses.contains(question.key, now: .now)
        guard start(lookup) else { return false }
        if addressKnown {
            lookup.addressFound(grace: Self.aaaaGrace)
        } else if question.isAAAA, !pending.values.contains(where: { $0.question.isA && $0.question.key == question.key }) {
            lookForAddress(of: question)
        }
        return true
    }

    private func start(_ lookup: Lookup) -> Bool {
        let question = lookup.question
        var ref: DNSServiceRef?
        let flags = DNSServiceFlags(kDNSServiceFlagsReturnIntermediates)
        let context = Unmanaged.passUnretained(lookup).toOpaque()
        let error = DNSServiceQueryRecord(&ref, flags, 0, question.name, question.type, question.qclass, { _, flags, _, error, name, type, qclass, length, data, ttl, context in
            guard let context else { return }
            let lookup = Unmanaged<Lookup>.fromOpaque(context).takeUnretainedValue()
            lookup.received(flags: flags, error: error, name: name.map { String(cString: $0) }, type: type, qclass: qclass,
                            rdata: data.map { Data(bytes: $0, count: Int(length)) } ?? Data(), ttl: ttl)
        }, context)
        guard error == kDNSServiceErr_NoError, let ref else { return false }
        lookup.ref = ref
        lookup.finish = { [weak self, unowned lookup] in self?.finish(lookup) }
        pending[ObjectIdentifier(lookup)] = lookup
        DNSServiceSetDispatchQueue(ref, queue)
        lookup.arm(Self.timeout)
        return true
    }

    /// An A lookup no client asked for, on behalf of an AAAA query with none beside it. Nothing
    /// depends on it starting: without it the AAAA ends as it would have.
    private func lookForAddress(of question: Question) {
        guard pending.count < Self.maxPending, let address = question.addressQuestion else { return }
        _ = start(Lookup(question: address, isOwn: true, queue: queue, reply: { _ in }))
    }

    private func finish(_ lookup: Lookup) {
        guard pending.removeValue(forKey: ObjectIdentifier(lookup)) != nil else { return }
        lookup.timer?.cancel()
        if let ref = lookup.ref { DNSServiceRefDeallocate(ref) }
        let key = lookup.question.key
        if lookup.question.isA, lookup.hasIPv4Address {
            // Only a client's own A query says what it will do next.
            if !lookup.isOwn { addresses.note(key, now: .now) }
            for other in pending.values where other.question.isAAAA && other.question.key == key {
                other.addressFound(grace: lookup.isOwn ? Self.loneAAAAGrace : Self.aaaaGrace)
            }
        }
        // The last AAAA for a name has its answer: its own A lookup has no one left to tell.
        if lookup.question.isAAAA, !pending.values.contains(where: { $0.question.isAAAA && $0.question.key == key }) {
            for other in Array(pending.values) where other.isOwn && other.question.key == key { other.stop() }
        }
        lookup.reply(lookup.response())
    }

    /// Every lookup ends (the device was reset); no replies are sent.
    func reset() {
        for lookup in pending.values {
            lookup.timer?.cancel()
            if let ref = lookup.ref { DNSServiceRefDeallocate(ref) }
        }
        pending.removeAll()
        addresses = RecentAddresses()
    }

    /// Names whose A lookup found an address a moment ago, for AAAA queries that arrive after it.
    struct RecentAddresses {
        private var found: [String: ContinuousClock.Instant] = [:]
        static let horizon: Duration = HostDNS.timeout
        static let capacity = HostDNS.maxPending

        mutating func note(_ key: String, now: ContinuousClock.Instant) {
            if found[key] == nil, found.count >= Self.capacity {
                found = found.filter { now - $0.value < Self.horizon }
                if found.count >= Self.capacity, let oldest = found.min(by: { $0.value < $1.value })?.key {
                    found[oldest] = nil
                }
            }
            found[key] = now
        }

        func contains(_ key: String, now: ContinuousClock.Instant) -> Bool {
            guard let when = found[key] else { return false }
            return now - when < Self.horizon
        }

        var count: Int { found.count }
    }

    /// The one question of a standard query, as the message carried it.
    struct Question {
        let id: UInt16
        let recursionDesired: Bool
        let name: String
        let type: UInt16
        let qclass: UInt16
        /// The question section as sent, echoed in the reply.
        let wire: [UInt8]
        /// The largest UDP reply the client takes: 512, or what its EDNS OPT record says.
        let udpLimit: Int

        var isA: Bool { type == 1 && qclass == 1 }
        var isAAAA: Bool { type == 28 && qclass == 1 }
        /// DNS names compare without regard to case.
        var key: String { name.lowercased() }
        /// The same name's A question.
        var addressQuestion: Question? {
            var message: [UInt8] = [0, 0, 0x01, 0, 0, 1, 0, 0, 0, 0, 0, 0] + wire
            message[message.count - 4] = 0
            message[message.count - 3] = 1
            return message.withUnsafeBytes { Question($0) }
        }

        init?(_ m: UnsafeRawBufferPointer) {
            guard m.count >= 17, m[2] & 0xf8 == 0, m.u16(4) == 1, m.u16(6) == 0, m.u16(8) == 0 else { return nil }
            var offset = 12
            var labels: [String] = []
            while true {
                guard offset < m.count else { return nil }
                let length = Int(m[offset])
                offset += 1
                if length == 0 { break }
                guard length < 64, offset + length <= m.count else { return nil }
                labels.append(String(decoding: UnsafeRawBufferPointer(rebasing: m[offset..<offset + length]), as: UTF8.self))
                offset += length
            }
            guard offset + 4 <= m.count, !labels.isEmpty else { return nil }
            id = m.u16(0)
            recursionDesired = m[2] & 0x01 != 0
            name = labels.joined(separator: ".") + "."
            type = m.u16(offset)
            qclass = m.u16(offset + 2)
            wire = Array(m[12..<offset + 4])
            // An OPT record (root name, type 41) in the additional section gives the client's limit.
            var limit = 512
            let rest = offset + 4
            if m.u16(10) >= 1, rest + 11 <= m.count, m[rest] == 0, m.u16(rest + 1) == 41 {
                limit = min(max(Int(m.u16(rest + 3)), 512), 4096)
            }
            udpLimit = limit
        }
    }

    final class Lookup {
        let question: Question
        let limit: Int
        /// Started here on behalf of an AAAA query; no client waits for its reply.
        let isOwn: Bool
        let queue: DispatchQueue
        let reply: ([UInt8]) -> Void
        var ref: DNSServiceRef?
        var timer: DispatchSourceTimer?
        var finish: () -> Void = {}
        private var records: [(name: String, type: UInt16, qclass: UInt16, ttl: UInt32, rdata: Data)] = []
        private var rcode: UInt8 = 2  // SERVFAIL until something answers
        private var done = false
        private var deadline = ContinuousClock.now
        /// The name's A lookup found an address, so having no AAAA answer is not a failure.
        private var addressKnown = false

        init(question: Question, limit: Int? = nil, isOwn: Bool = false, queue: DispatchQueue, reply: @escaping ([UInt8]) -> Void) {
            self.question = question
            self.limit = limit ?? question.udpLimit
            self.isOwn = isOwn
            self.queue = queue
            self.reply = reply
        }

        func arm(_ after: Duration) {
            timer?.cancel()
            deadline = .now + after
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(Int(after.components.seconds) * 1000 + Int(after.components.attoseconds / 1_000_000_000_000_000)))
            t.setEventHandler { [weak self] in self?.end() }
            t.resume()
            timer = t
        }

        /// For an AAAA lookup: the name has an IPv4 address. Ends the wait at `grace` from now,
        /// never later than it would have ended.
        func addressFound(grace: Duration) {
            addressKnown = true
            if .now + grace < deadline { arm(grace) }
        }

        var hasIPv4Address: Bool { records.contains { $0.type == 1 } }

        func stop() { end() }

        private func end() {
            guard !done else { return }
            done = true
            finish()
        }

        func received(flags: DNSServiceFlags, error: DNSServiceErrorType, name: String?, type: UInt16, qclass: UInt16, rdata: Data, ttl: UInt32) {
            guard !done, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 else { return }
            let more = flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) != 0
            switch Int(error) {
            case kDNSServiceErr_NoError:
                rcode = 0
                if let rdata = Self.forGuest(type: type, rdata) { records.append((name ?? question.name, type, qclass, ttl, rdata)) }
                // A CNAME for another type: the record it leads to, or word that there is none,
                // is still to come. It can take as long as any lookup (a target not cached on a
                // slow network); a shorter wait answered with the CNAME alone and no address.
                if type == 5 && question.type != 5 && !more { return }
            case kDNSServiceErr_NoSuchRecord:
                // The name has no such record, or does not exist: mDNSResponder reports both this
                // way, so the reply is an empty NOERROR rather than NXDOMAIN.
                rcode = 0
            case kDNSServiceErr_NoSuchName:
                rcode = records.isEmpty ? 3 : 0  // NXDOMAIN, unless a CNAME led here
            default:
                rcode = records.isEmpty ? 2 : 0
            }
            if !more { end() }
        }

        /// An address as the guest can use it: the Mac's loopback (mDNSResponder answers the Mac's
        /// own `.local` name with it) is the gateway's host address; other loopback and link-local
        /// addresses lead nowhere from the guest and are left out, and so are IPv6 addresses the
        /// Mac has no route to (as Docker Desktop leaves out AAAA records on a Mac without IPv6),
        /// so programs that try addresses in order do not start with one that cannot work.
        static func forGuest(type: UInt16, _ rdata: Data) -> Data? {
            switch (type, rdata.count) {
            case (1, 4):
                if rdata == Data([127, 0, 0, 1]) { return withUnsafeBytes(of: UserNet.host.v4.bigEndian) { Data($0) } }
                return rdata.first == 127 ? nil : rdata
            case (28, 16):
                if rdata == Data(repeating: 0, count: 15) + [1] { return Data(UserNet.host6.bytes) }
                if rdata[rdata.startIndex] == 0xfe && rdata[rdata.startIndex + 1] & 0xc0 == 0x80 { return nil }
                return routable(rdata) ? rdata : nil
            default:
                return rdata
            }
        }

        /// Whether the Mac has a route to an IPv6 address: connecting a UDP socket looks the
        /// route up and sends nothing.
        static func routable(_ address: Data) -> Bool {
            let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            let endpoint = address.withUnsafeBytes { HostEndpoint.v6(IPAddress($0, at: 0), 53) }
            return endpoint.withSockaddr { connect(fd, $0, $1) } == 0
        }

        /// The reply: header, the question as asked, the records found; truncated (TC) when it
        /// would not fit `limit`, so the client asks again over TCP. Names are compressed as any
        /// resolver's are: uncompressed, a CNAME and eight addresses (an S3 bucket's name) exceed
        /// 512 bytes, where compressed they take about 200.
        func response() -> [UInt8] {
            var m: [UInt8] = []
            m.be16(question.id)
            // QR, recursion desired as asked, recursion available, TC when cut.
            let code = rcode == 2 && addressKnown ? 0 : rcode
            var flags: UInt16 = 0x8080 | (question.recursionDesired ? 0x0100 : 0) | UInt16(code)
            m.be16(flags)
            m.be16(1)
            m.be16(0)
            m.be16(0)
            m.be16(0)
            var names = NameCompression()
            m.append(contentsOf: question.wire)
            names.note(NameCompression.labels(wire: question.wire) ?? [], at: 12)
            var kept: UInt16 = 0
            for record in records {
                let start = m.count
                names.append(NameCompression.labels(record.name), to: &m)
                m.be16(record.type)
                m.be16(record.qclass)
                m.be32(record.ttl)
                let length = m.count
                m.be16(0)
                // Only a CNAME's data is known here to be a name.
                if record.type == 5, let target = NameCompression.labels(wire: Array(record.rdata)) {
                    names.append(target, to: &m)
                } else {
                    m.append(contentsOf: record.rdata)
                }
                let rdlength = UInt16(m.count - length - 2)
                m[length] = UInt8(rdlength >> 8)
                m[length + 1] = UInt8(rdlength & 0xff)
                if m.count > limit {
                    m.removeLast(m.count - start)
                    flags |= 0x0200
                    m[2] = UInt8(flags >> 8)
                    break
                }
                kept += 1
            }
            m[6] = UInt8(kept >> 8)
            m[7] = UInt8(kept & 0xff)
            return m
        }
    }
}

/// Writes names into a DNS message, pointing at an earlier copy of a name's tail where there is one.
struct NameCompression {
    private var offsets: [[[UInt8]]: Int] = [:]

    /// The labels of a name in text form.
    static func labels(_ name: String) -> [[UInt8]] {
        name.split(separator: ".").map { Array($0.utf8.prefix(63)) }
    }

    /// The labels of an uncompressed name that starts `wire`, or nil if it is not one.
    static func labels(wire: [UInt8]) -> [[UInt8]]? {
        var labels: [[UInt8]] = []
        var offset = 0
        while offset < wire.count {
            let length = Int(wire[offset])
            offset += 1
            if length == 0 { return labels }
            guard length < 64, offset + length <= wire.count else { return nil }
            labels.append(Array(wire[offset..<offset + length]))
            offset += length
        }
        return nil
    }

    /// Names compare without regard to case, and a pointer may lead to any case of the same name.
    private static func key(_ labels: ArraySlice<[UInt8]>) -> [[UInt8]] {
        labels.map { $0.map { (65...90).contains($0) ? $0 + 32 : $0 } }
    }

    /// A name with these labels is in the message at `offset`, so its tails can be pointed at.
    mutating func note(_ labels: [[UInt8]], at offset: Int) {
        var at = offset
        for i in labels.indices {
            guard at < 0x4000 else { return }  // a pointer has 14 bits
            let key = Self.key(labels[i...])
            if offsets[key] == nil { offsets[key] = at }
            at += 1 + labels[i].count
        }
    }

    mutating func append(_ labels: [[UInt8]], to message: inout [UInt8]) {
        for i in labels.indices {
            if let offset = offsets[Self.key(labels[i...])] {
                message.be16(0xc000 | UInt16(offset))
                return
            }
            if message.count < 0x4000 { offsets[Self.key(labels[i...])] = message.count }
            message.append(UInt8(labels[i].count))
            message.append(contentsOf: labels[i])
        }
        message.append(0)
    }
}
