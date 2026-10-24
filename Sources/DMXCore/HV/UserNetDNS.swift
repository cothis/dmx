import Foundation

/// Names the gateway's DNS answers itself instead of asking the host's resolver: Docker
/// Desktop's `host.docker.internal` (the Mac, whose 127.0.0.1 is 192.168.127.254 to the guest)
/// and `gateway.docker.internal`, plus dmx's own `host.dmx.internal`. Containers resolve them
/// through the gateway like any name: directly on the default bridge, through dockerd's embedded
/// DNS on other networks. The guest's /etc/hosts has them too, for dockerd itself.
enum LocalDNS {
    static let names: [String: UInt32] = [
        "host.docker.internal": UserNet.host,
        "gateway.docker.internal": UserNet.gateway,
        "host.dmx.internal": UserNet.host,
    ]
    static let ttl: UInt32 = 60

    /// The reply to a query for one of `names`, or nil to forward the query. An A query gets the
    /// address; any other type for these names gets an empty answer (no IPv6), so resolvers
    /// asking for AAAA alongside do not wait.
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
        guard offset + 4 <= query.count, let address = names[labels.joined(separator: ".")] else { return nil }
        let type = query.u16(offset), qclass = query.u16(offset + 2)
        guard qclass == 1 else { return nil }
        let questionEnd = offset + 4

        var reply: [UInt8] = []
        reply.be16(query.u16(0))
        // QR, authoritative, recursion desired as asked, recursion available; no error.
        reply.be16(0x8480 | UInt16(query[2] & 0x01) << 8)
        reply.be16(1)
        reply.be16(type == 1 ? 1 : 0)
        reply.be16(0)
        reply.be16(0)
        reply.append(contentsOf: query[12..<questionEnd])
        if type == 1 {
            reply.be16(0xc00c)  // the name in the question
            reply.be16(1)
            reply.be16(1)
            reply.be32(ttl)
            reply.be16(4)
            reply.be32(address)
        }
        return reply
    }
}
