import Foundation
import dnssd

/// Answers the guest's DNS queries with macOS's own resolver (mDNSResponder, through
/// `DNSServiceQueryRecord`), so the guest gets what any Mac app gets: the per-domain servers a VPN
/// adds (split DNS, e.g. a company's intranet names), `.local` names over multicast DNS, and the
/// servers of the network the Mac is on now, not the one it was on at boot. CNAMEs come back as
/// intermediate records, so the reply carries the whole chain as a recursive server's would.
/// Everything runs on the network queue. Queries it cannot represent (more than one question, an
/// opcode other than QUERY) go to the first nameserver of /etc/resolv.conf as before, and so does
/// DNS over TCP, which a client uses after a reply too large for UDP came back truncated.
final class HostDNS {
    private let queue: DispatchQueue
    private var pending: [ObjectIdentifier: Lookup] = [:]
    /// A query unanswered for this long gets SERVFAIL; the client then retries or gives up.
    static let timeout: Duration = .seconds(5)
    static let maxPending = 256

    init(queue: DispatchQueue) { self.queue = queue }

    /// Starts resolving `query`, a DNS message from the guest; `reply` gets the response on the
    /// queue. False when the query is not one this handles.
    func resolve(_ query: UnsafeRawBufferPointer, reply: @escaping ([UInt8]) -> Void) -> Bool {
        guard let question = Question(query), pending.count < Self.maxPending else { return false }
        let lookup = Lookup(question: question, queue: queue, reply: reply)
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

    private func finish(_ lookup: Lookup) {
        guard pending.removeValue(forKey: ObjectIdentifier(lookup)) != nil else { return }
        lookup.timer?.cancel()
        if let ref = lookup.ref { DNSServiceRefDeallocate(ref) }
        lookup.reply(lookup.response())
    }

    /// Every lookup ends (the device was reset); no replies are sent.
    func reset() {
        for lookup in pending.values {
            lookup.timer?.cancel()
            if let ref = lookup.ref { DNSServiceRefDeallocate(ref) }
        }
        pending.removeAll()
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
        let queue: DispatchQueue
        let reply: ([UInt8]) -> Void
        var ref: DNSServiceRef?
        var timer: DispatchSourceTimer?
        var finish: () -> Void = {}
        private var records: [(name: String, type: UInt16, qclass: UInt16, ttl: UInt32, rdata: Data)] = []
        private var rcode: UInt8 = 2  // SERVFAIL until something answers
        private var done = false

        init(question: Question, queue: DispatchQueue, reply: @escaping ([UInt8]) -> Void) {
            self.question = question
            self.queue = queue
            self.reply = reply
        }

        func arm(_ after: Duration) {
            timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(Int(after.components.seconds) * 1000 + Int(after.components.attoseconds / 1_000_000_000_000_000)))
            t.setEventHandler { [weak self] in self?.end() }
            t.resume()
            timer = t
        }

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
        /// addresses lead nowhere from the guest and are left out.
        static func forGuest(type: UInt16, _ rdata: Data) -> Data? {
            switch (type, rdata.count) {
            case (1, 4):
                if rdata == Data([127, 0, 0, 1]) { return withUnsafeBytes(of: UserNet.host.bigEndian) { Data($0) } }
                return rdata.first == 127 ? nil : rdata
            case (28, 16):
                if rdata == Data(repeating: 0, count: 15) + [1] { return nil }
                return rdata[rdata.startIndex] == 0xfe && rdata[rdata.startIndex + 1] & 0xc0 == 0x80 ? nil : rdata
            default:
                return rdata
            }
        }

        /// The reply: header, the question as asked, the records found; truncated (TC) when it
        /// would not fit the client's UDP limit, so the client asks again over TCP.
        func response() -> [UInt8] {
            var answers: [[UInt8]] = []
            for record in records {
                var r = encodeName(record.name)
                r.be16(record.type)
                r.be16(record.qclass)
                r.be32(record.ttl)
                r.be16(UInt16(record.rdata.count))
                r.append(contentsOf: record.rdata)
                answers.append(r)
            }
            var kept = answers
            var truncated = false
            while 12 + question.wire.count + kept.reduce(0, { $0 + $1.count }) > question.udpLimit, !kept.isEmpty {
                kept.removeLast()
                truncated = true
            }
            var m: [UInt8] = []
            m.be16(question.id)
            // QR, recursion desired as asked, recursion available, TC when cut.
            var flags: UInt16 = 0x8080 | (question.recursionDesired ? 0x0100 : 0) | UInt16(rcode)
            if truncated { flags |= 0x0200 }
            m.be16(flags)
            m.be16(1)
            m.be16(UInt16(kept.count))
            m.be16(0)
            m.be16(0)
            m.append(contentsOf: question.wire)
            for answer in kept { m.append(contentsOf: answer) }
            return m
        }

        private func encodeName(_ name: String) -> [UInt8] {
            var out: [UInt8] = []
            for label in name.split(separator: ".") {
                let bytes = Array(label.utf8.prefix(63))
                out.append(UInt8(bytes.count))
                out.append(contentsOf: bytes)
            }
            out.append(0)
            return out
        }
    }
}
