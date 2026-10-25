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
