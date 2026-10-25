import Foundation

/// dmx's user space NAT behind `VirtioNet` (design in docs/network.md). The guest's Ethernet
/// frames end here: ARP is answered, and each TCP, UDP or ICMP echo flow is carried by an ordinary
/// socket of the dmx process, the way passt and slirp do it. dmx needs no root, no network
/// entitlement and no host interface, and the guest's traffic leaves as dmx's own (VPNs, the
/// firewall and proxies apply as to any app). IPv4 and IPv6. All of it runs on `queue`.
///
/// Addresses, as the guest sees them (static, set by guest/init):
/// - 192.168.127.2, fd64:646d:7800::2: the guest.
/// - 192.168.127.1, fd64:646d:7800::1: the gateway. DNS on port 53 is answered by macOS's resolver
///   (HostDNS); DNS over TCP goes to the host's DNS server (from /etc/resolv.conf).
/// - 192.168.127.254, fd64:646d:7800::254: the host itself; connections go to the host's
///   127.0.0.1 and ::1.
/// Everything else is the outside world, reached from the host's sockets. The IPv6 prefix is a
/// unique local one, so the guest's resolvers (RFC 6724) keep IPv4 first for names with both and
/// use IPv6 for names that have only that.
final class UserNet: @unchecked Sendable {
    static let guest = IPAddress(v4: 0xc0a8_7f02)
    static let gateway = IPAddress(v4: 0xc0a8_7f01)
    static let host = IPAddress(v4: 0xc0a8_7ffe)
    static let subnet: UInt32 = 0xc0a8_7f00   // /24
    static let prefix6: UInt64 = 0xfd64_646d_7800_0000  // /64
    static let guest6 = IPAddress(high: prefix6, low: 2)
    static let gateway6 = IPAddress(high: prefix6, low: 1)
    static let host6 = IPAddress(high: prefix6, low: 0x254)
    static let guestMAC: [UInt8] = [0x02, 0x64, 0x6d, 0x78, 0x00, 0x02]  // locally administered, "dmx"
    static let gatewayMAC: [UInt8] = [0x02, 0x64, 0x6d, 0x78, 0x00, 0x01]
    /// At most this many flows, so a guest cannot run dmx out of descriptors.
    static let maxTCP = 2048
    static let maxUDP = 512
    static let udpIdle: Duration = .seconds(60)
    static let dnsIdle: Duration = .seconds(10)
    static let icmpIdle: Duration = .seconds(30)

    let queue: DispatchQueue
    unowned let device: VirtioNet
    var tcp: [FlowKey: TCPFlow] = [:]
    private var udp: [FlowKey: UDPFlow] = [:]
    /// Echo sockets by address family.
    private var icmp: [Int32: (socket: NetSocket, lastUsed: ContinuousClock.Instant)] = [:]
    private var timer: DispatchSourceTimer?
    /// The host's DNS server, read when the device is created (each boot), for DNS over TCP and
    /// queries `dns` does not take.
    private let resolver: HostEndpoint?
    /// UDP queries to the gateway, answered by macOS's resolver.
    private lazy var dns = HostDNS(queue: queue)
    /// Scratch space for what is read from host sockets.
    var scratch = [UInt8](repeating: 0, count: 65536)

    struct FlowKey: Hashable {
        let guestPort: UInt16
        let remote: IPAddress  // as the guest addressed it
        let remotePort: UInt16
    }

    private final class UDPFlow {
        let socket: NetSocket
        let idle: Duration
        var lastUsed = ContinuousClock.now
        init(socket: NetSocket, idle: Duration) { self.socket = socket; self.idle = idle }
    }

    init(queue: DispatchQueue, device: VirtioNet) {
        self.queue = queue
        self.device = device
        resolver = Self.hostResolver()
        // Every flow is a descriptor; macOS starts processes with a soft limit of 256.
        var limit = rlimit()
        if getrlimit(RLIMIT_NOFILE, &limit) == 0 {
            let want = min(limit.rlim_max, rlim_t(OPEN_MAX))
            if limit.rlim_cur < want {
                limit.rlim_cur = want
                setrlimit(RLIMIT_NOFILE, &limit)
            }
        }
    }

    /// The first usable `nameserver` in /etc/resolv.conf, which macOS keeps current.
    static func hostResolver() -> HostEndpoint? {
        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count >= 2, fields[0] == "nameserver", let endpoint = HostEndpoint(String(fields[1]), port: 53) {
                return endpoint
            }
        }
        return nil
    }

    /// The device was reset or the VM stopped: every flow ends.
    func reset() {
        for flow in tcp.values { flow.socket.close(reset: true) }
        tcp.removeAll()
        for flow in udp.values { flow.socket.close() }
        udp.removeAll()
        for echo in icmp.values { echo.socket.close() }
        icmp.removeAll()
        dns.reset()
        timer?.cancel()
        timer = nil
    }

    /// Where a guest flow to `address:port` goes on the host, or nil if nowhere.
    func endpoint(for address: IPAddress, port: UInt16) -> HostEndpoint? {
        switch address {
        case Self.host: return .v4(0x7f00_0001, port)
        case Self.host6: return .v6(.loopback6, port)
        case Self.gateway, Self.gateway6: return port == 53 ? resolver : nil
        default:
            if address.isV4 {
                // The guest's own subnet, "this network", loopback, multicast and broadcast stay inside.
                let a = address.v4
                if a & 0xffff_ff00 == Self.subnet || a >> 24 == 0 || a >> 24 == 127 || a >= 0xe000_0000 { return nil }
                return .v4(a, port)
            }
            // The guest's own prefix, unspecified, loopback and IPv4-compatible (::/64), link-local
            // and multicast stay inside.
            if address.high == Self.prefix6 || address.high == 0 || address.high >> 54 == 0x3fa || address.high >> 56 == 0xff {
                return nil
            }
            return .v6(address, port)
        }
    }

    /// Why a flow to `address` that `endpoint` does not carry fails: the gateway has no such port;
    /// other addresses (the guest's own network, loopback, multicast, reserved) lead nowhere.
    func nowhere(_ address: IPAddress) -> Int32 {
        address == Self.gateway || address == Self.gateway6 ? ECONNREFUSED : EHOSTUNREACH
    }

    /// A host address as the guest should see it: the host's loopback is the gateway's host address.
    static func fromHost(_ address: IPAddress) -> IPAddress {
        switch address {
        case IPAddress(v4: 0x7f00_0001): host
        case .loopback6: host6
        default: address
        }
    }

    // MARK: From the guest

    /// One Ethernet frame the guest sent, without its virtio-net header.
    func receive(_ frame: UnsafeRawBufferPointer) {
        guard frame.count >= 14 else { return }
        let payload = UnsafeRawBufferPointer(rebasing: frame[14...])
        switch frame.u16(12) {
        case 0x0806: arp(payload)
        case 0x0800: ipv4(payload)
        case 0x86dd: ipv6(payload)
        default: break
        }
    }

    private func arp(_ p: UnsafeRawBufferPointer) {
        // Ethernet/IPv4 request for the gateway or the host address: both are us.
        guard p.count >= 28, p.u16(0) == 1, p.u16(2) == 0x0800, p[4] == 6, p[5] == 4, p.u16(6) == 1 else { return }
        let target = p.u32(24)
        guard target == Self.gateway.v4 || target == Self.host.v4 else { return }
        let senderMAC = Array(p[8..<14])
        var f = senderMAC + Self.gatewayMAC
        f.be16(0x0806)
        f.be16(1); f.be16(0x0800); f.append(6); f.append(4); f.be16(2)
        f += Self.gatewayMAC; f.be32(target)
        f += senderMAC; f += p[14..<18]
        device.send(f)
    }

    private func ipv4(_ p: UnsafeRawBufferPointer) {
        guard p.count >= 20, p[0] >> 4 == 4 else { return }
        let headerLength = Int(p[0] & 0xf) * 4
        let total = Int(p.u16(2))
        guard headerLength >= 20, total >= headerLength, total <= p.count,
              p.u16(6) & 0x3fff == 0,  // fragments: the MTU is 64 KB, so the guest has no reason to send any
              p.u32(12) == Self.guest.v4 else { return }
        let destination = IPAddress(v4: p.u32(16))
        let payload = UnsafeRawBufferPointer(rebasing: p[headerLength..<total])
        switch p[9] {
        case 1: echo(payload, to: destination)
        case 6: tcpSegment(payload, to: destination)
        case 17: udp(payload, to: destination)
        default: break
        }
    }

    private func ipv6(_ p: UnsafeRawBufferPointer) {
        guard p.count >= 40, p[0] >> 4 == 6 else { return }
        let total = 40 + Int(p.u16(4))
        guard total <= p.count else { return }
        let source = IPAddress(p, at: 8), destination = IPAddress(p, at: 24)
        // ::/64 (unspecified, loopback, IPv4-mapped) is never a destination on the wire.
        guard destination.high != 0 else { return }
        // Extension headers the guest puts first: hop-by-hop (MLD's router alert), routing,
        // destination options. Fragments (44) it has no reason to send at this MTU.
        var next = p[6], offset = 40
        while next == 0 || next == 43 || next == 60 {
            guard offset + 8 <= total else { return }
            next = p[offset]
            offset += (Int(p[offset + 1]) + 1) * 8
        }
        guard offset <= total else { return }
        let payload = UnsafeRawBufferPointer(rebasing: p[offset..<total])
        if next == 58, payload.count >= 4, (130...143).contains(payload[0]) {
            // Neighbor discovery and multicast listener messages: only neighbor solicitations
            // for the gateway's addresses get an answer.
            if payload[0] == 135 && p[7] == 255 { neighborSolicitation(payload, from: source) }
            return
        }
        guard source == Self.guest6 else { return }
        switch next {
        case 58: echo(payload, to: destination)
        case 6: tcpSegment(payload, to: destination)
        case 17: udp(payload, to: destination)
        default: break
        }
    }

    /// IPv6's ARP: the gateway and host addresses are both the gateway's MAC (RFC 4861 7.2.4).
    /// No router advertisements; guest/init sets the address and route itself.
    private func neighborSolicitation(_ p: UnsafeRawBufferPointer, from source: IPAddress) {
        guard p.count >= 24, p[1] == 0, source.high != 0 else { return }  // not duplicate address detection
        let target = IPAddress(p, at: 8)
        guard target == Self.gateway6 || target == Self.host6 else { return }
        var m: [UInt8] = [136, 0, 0, 0]
        m.be32(0xe000_0000)  // router, solicited, override
        m += target.bytes
        m += [2, 1] + Self.gatewayMAC  // target link-layer address
        device.send(ipFrame(protocol: 58, from: target, to: source, hopLimit: 255, transport: m,
                            payload: UnsafeRawBufferPointer(start: nil, count: 0)))
    }

    // MARK: ICMP echo

    /// Echo requests go out through an unprivileged ICMP socket (`SOCK_DGRAM`, `IPPROTO_ICMP` or
    /// `IPPROTO_ICMPV6`), which keeps the identifier and sequence; the gateway answers its own.
    private func echo(_ p: UnsafeRawBufferPointer, to destination: IPAddress) {
        let v4 = destination.isV4
        guard p.count >= 8, p[0] == (v4 ? 8 : 128), p[1] == 0 else { return }  // echo request only
        var message = Array(p)
        message[2] = 0; message[3] = 0
        if destination == Self.gateway || destination == Self.gateway6 {
            message[0] = v4 ? 0 : 129
            device.send(ipFrame(protocol: v4 ? 1 : 58, from: destination, transport: message, payload: UnsafeRawBufferPointer(start: nil, count: 0)))
            return
        }
        guard let endpoint = endpoint(for: destination, port: 0) else { return }
        let family = endpoint.family
        if icmp[family] == nil {
            let fd = socket(family, SOCK_DGRAM, v4 ? IPPROTO_ICMP : IPPROTO_ICMPV6)
            guard fd >= 0 else { return }
            let socket = NetSocket(fd: fd, queue: queue, onRead: { [unowned self] in self.echoReply(family) })
            socket.reading = true
            icmp[family] = (socket, .now)
            startTimer()
        }
        if v4 {
            // The kernel fills in ICMPv6 checksums, not ICMP ones.
            let sum = message.withUnsafeBytes { checksum($0) }
            message[2] = UInt8(sum >> 8); message[3] = UInt8(sum & 0xff)
        }
        icmp[family]!.lastUsed = .now
        _ = endpoint.withSockaddr { address, length in sendto(icmp[family]!.socket.fd, message, message.count, 0, address, length) }
    }

    private func echoReply(_ family: Int32) {
        guard let fd = icmp[family]?.socket.fd else { return }
        while true {
            var from = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &scratch, scratch.count, 0, $0, &length) }
            }
            guard n > 0 else { return }
            guard let address = IPAddress(from) else { continue }
            let source = Self.fromHost(address)
            scratch.withUnsafeBytes { raw in
                var p = UnsafeRawBufferPointer(rebasing: raw[..<n])
                // macOS hands back the IPv4 header too, not the IPv6 one.
                if family == AF_INET && p[0] >> 4 == 4 {
                    let headerLength = Int(p[0] & 0xf) * 4
                    guard p.count >= headerLength + 8 else { return }
                    p = UnsafeRawBufferPointer(rebasing: p[headerLength...])
                }
                // Replies only: an ICMPv6 socket also sees its own requests to the host's loopback.
                guard p.count >= 8, p[0] == (family == AF_INET ? 0 : 129) else { return }
                var message = Array(p)
                message[2] = 0; message[3] = 0
                device.send(ipFrame(protocol: family == AF_INET ? 1 : 58, from: source, transport: message, payload: UnsafeRawBufferPointer(start: nil, count: 0)))
            }
        }
    }

    // MARK: UDP

    private func udp(_ p: UnsafeRawBufferPointer, to destination: IPAddress) {
        guard p.count >= 8 else { return }
        let length = Int(p.u16(4))
        guard length >= 8, length <= p.count else { return }
        let key = FlowKey(guestPort: p.u16(0), remote: destination, remotePort: p.u16(2))
        let gateway = destination == Self.gateway || destination == Self.gateway6
        if gateway, key.remotePort == 53,
           let answer = LocalDNS.answer(UnsafeRawBufferPointer(rebasing: p[8..<length])) {
            var header: [UInt8] = []
            header.be16(53); header.be16(key.guestPort); header.be16(UInt16(8 + answer.count)); header.be16(0)
            answer.withUnsafeBytes { device.send(ipFrame(protocol: 17, from: destination, transport: header, payload: $0)) }
            return
        }
        if gateway, key.remotePort == 53,
           dns.resolve(UnsafeRawBufferPointer(rebasing: p[8..<length]), reply: { [weak self] answer in
               guard let self else { return }
               var header: [UInt8] = []
               header.be16(53); header.be16(key.guestPort); header.be16(UInt16(8 + answer.count)); header.be16(0)
               answer.withUnsafeBytes { self.device.send(self.ipFrame(protocol: 17, from: destination, transport: header, payload: $0)) }
           }) {
            return
        }
        let flow: UDPFlow
        if let existing = udp[key] {
            flow = existing
        } else {
            guard let endpoint = endpoint(for: destination, port: key.remotePort) else {
                unreachable(key, protocol: 17, error: nowhere(destination), quoting: Array(p[0..<8]))
                return
            }
            // Full: the least recently used flow goes (each DNS query comes from a new port).
            if udp.count >= Self.maxUDP, let oldest = udp.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                oldest.value.socket.close()
                udp[oldest.key] = nil
            }
            let fd = socket(endpoint.family, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return }
            guard endpoint.withSockaddr({ connect(fd, $0, $1) }) == 0 else {
                let failure = errno
                close(fd)
                unreachable(key, protocol: 17, error: failure, quoting: Array(p[0..<8]))
                return
            }
            let socket = NetSocket(fd: fd, queue: queue, onRead: { [unowned self] in self.udpReply(key) })
            socket.reading = true
            flow = UDPFlow(socket: socket, idle: key.remotePort == 53 ? Self.dnsIdle : Self.udpIdle)
            udp[key] = flow
            startTimer()
        }
        flow.lastUsed = .now
        if Darwin.send(flow.socket.fd, p.baseAddress! + 8, length - 8, 0) < 0 {
            unreachable(key, protocol: 17, error: errno, quoting: Array(p[0..<8]))
        }
    }

    private func udpReply(_ key: FlowKey) {
        guard let flow = udp[key] else { return }
        while true {
            let n = recv(flow.socket.fd, &scratch, scratch.count, 0)
            guard n >= 0 else {
                // An ICMP error the host received for this flow (a closed port answers with one).
                var head: [UInt8] = []
                head.be16(key.guestPort); head.be16(key.remotePort); head.be16(8); head.be16(0)
                unreachable(key, protocol: 17, error: errno, quoting: head)
                return
            }
            guard n <= VirtioNet.mtu - (key.remote.isV4 ? 28 : 48) else { continue }
            flow.lastUsed = .now
            var header: [UInt8] = []
            header.be16(key.remotePort); header.be16(key.guestPort); header.be16(UInt16(8 + n)); header.be16(0)
            scratch.withUnsafeBytes { raw in
                device.send(ipFrame(protocol: 17, from: key.remote, transport: header, payload: UnsafeRawBufferPointer(rebasing: raw[..<n])))
            }
        }
    }

    // MARK: ICMP errors

    /// Tells the guest that a flow's destination cannot be reached, as a router or the far host
    /// would: an ICMP destination unreachable quoting the start of the guest's packet, which the
    /// guest matches to the socket, so a connect fails with "network unreachable" or "no route
    /// to host" at once, and a UDP client learns that nothing listens. False for errors that are
    /// not about reaching the destination; the caller answers those itself.
    @discardableResult
    func unreachable(_ key: FlowKey, protocol proto: UInt8, error: Int32, quoting head: [UInt8]) -> Bool {
        let v4 = key.remote.isV4
        let codes: (v4: UInt8, v6: UInt8)
        switch error {
        case ENETUNREACH: codes = (0, 0)                         // network unreachable, no route
        case EHOSTUNREACH, EHOSTDOWN, ETIMEDOUT: codes = (1, 3)  // host, address unreachable
        case ECONNREFUSED where proto == 17: codes = (3, 4)      // port unreachable
        case EACCES, EPERM: codes = (13, 1)                      // prohibited: a firewall on the Mac
        default: return false
        }
        var m: [UInt8] = [v4 ? 3 : 1, v4 ? codes.v4 : codes.v6, 0, 0, 0, 0, 0, 0]
        if v4 {
            var ip: [UInt8] = [0x45, 0]
            ip.be16(UInt16(20 + head.count)); ip.be16(0); ip.be16(0x4000)
            ip.append(64); ip.append(proto); ip.be16(0); ip.be32(Self.guest.v4); ip.be32(key.remote.v4)
            let sum = ip.withUnsafeBytes { checksum($0) }
            ip[10] = UInt8(sum >> 8); ip[11] = UInt8(sum & 0xff)
            m += ip
        } else {
            m.be32(0x6000_0000); m.be16(UInt16(head.count)); m.append(proto); m.append(64)
            m += Self.guest6.bytes; m += key.remote.bytes
        }
        m += head
        // A closed port answers from the far host; the rest comes from the gateway, as from a router.
        let source = error == ECONNREFUSED ? key.remote : (v4 ? Self.gateway : Self.gateway6)
        device.send(ipFrame(protocol: v4 ? 1 : 58, from: source, transport: m, payload: UnsafeRawBufferPointer(start: nil, count: 0)))
        return true
    }

    // MARK: Timer

    /// Runs `tick` four times a second while any flow exists.
    func startTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(50))
        source.setEventHandler { [unowned self] in self.tick() }
        timer = source
        source.resume()
    }

    private func tick() {
        let now = ContinuousClock.now
        for (key, flow) in udp where now - flow.lastUsed > flow.idle {
            flow.socket.close()
            udp[key] = nil
        }
        for (family, echo) in icmp where now - echo.lastUsed > Self.icmpIdle {
            echo.socket.close()
            icmp[family] = nil
        }
        tcpTick(now)
        if udp.isEmpty && tcp.isEmpty && icmp.isEmpty {
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: To the guest

    /// An Ethernet frame carrying an IP packet from `source` to the guest's address of the same
    /// family (or `destination`). `transport` is the TCP, UDP or ICMP header with a zero checksum;
    /// the checksum is filled in unless the guest lets us skip it (ICMP always gets one).
    func ipFrame(protocol proto: UInt8, from source: IPAddress, to destination: IPAddress? = nil, hopLimit: UInt8 = 64,
                 transport: [UInt8], payload: UnsafeRawBufferPointer) -> [UInt8] {
        let v4 = source.isV4
        let destination = destination ?? (v4 ? Self.guest : Self.guest6)
        let upper = transport.count + payload.count
        let start = 14 + (v4 ? 20 : 40)
        var f = [UInt8]()
        f.reserveCapacity(start + upper)
        f += Self.guestMAC; f += Self.gatewayMAC
        if v4 {
            f.be16(0x0800)
            f.append(0x45); f.append(0); f.be16(UInt16(20 + upper)); f.be16(0); f.be16(0x4000)  // don't fragment
            f.append(hopLimit); f.append(proto); f.be16(0); f.be32(source.v4); f.be32(destination.v4)
            let ipSum = f.withUnsafeBytes { checksum(UnsafeRawBufferPointer(rebasing: $0[14..<34])) }
            f[24] = UInt8(ipSum >> 8); f[25] = UInt8(ipSum & 0xff)
        } else {
            f.be16(0x86dd)
            f.be32(0x6000_0000); f.be16(UInt16(upper)); f.append(proto); f.append(hopLimit)
            f += source.bytes; f += destination.bytes
        }
        f += transport
        if payload.count > 0 { f.append(contentsOf: payload) }
        let offset: Int? = switch proto {
        case 1, 58: 2
        case 6 where !device.checksumsOptional: 16
        case 17 where !device.checksumsOptional || !v4: 6  // IPv6 forbids an empty UDP checksum
        default: nil
        }
        if let offset {
            // All but ICMP for IPv4 sum a pseudo header: addresses, protocol, length.
            let pseudo: UInt64 = proto == 1 ? 0 : source.wordSum + destination.wordSum + UInt64(proto) + UInt64(upper)
            var sum = f.withUnsafeBytes { checksum(UnsafeRawBufferPointer(rebasing: $0[start...]), adding: pseudo) }
            if proto == 17 && sum == 0 { sum = 0xffff }
            f[start + offset] = UInt8(sum >> 8); f[start + offset + 1] = UInt8(sum & 0xff)
        }
        return f
    }
}

/// An IPv4 or IPv6 address, as the guest sends it. IPv4 is held IPv4-mapped (::ffff:a.b.c.d), so
/// flows of both families share one key type.
struct IPAddress: Hashable {
    let high: UInt64
    let low: UInt64

    static let loopback6 = IPAddress(high: 0, low: 1)

    init(high: UInt64, low: UInt64) { self.high = high; self.low = low }
    init(v4: UInt32) { self.init(high: 0, low: 0xffff_0000_0000 | UInt64(v4)) }
    /// 16 bytes of an IPv6 address at `offset`.
    init(_ p: UnsafeRawBufferPointer, at offset: Int) {
        self.init(high: UInt64(p.u32(offset)) << 32 | UInt64(p.u32(offset + 4)),
                  low: UInt64(p.u32(offset + 8)) << 32 | UInt64(p.u32(offset + 12)))
    }
    /// The address of an AF_INET or AF_INET6 socket address.
    init?(_ storage: sockaddr_storage) {
        var s = storage
        switch Int32(storage.ss_family) {
        case AF_INET:
            let a = withUnsafeBytes(of: &s) { $0.load(as: sockaddr_in.self) }
            self.init(v4: UInt32(bigEndian: a.sin_addr.s_addr))
        case AF_INET6:
            var a = withUnsafeBytes(of: &s) { $0.load(as: sockaddr_in6.self) }
            self = withUnsafeBytes(of: &a.sin6_addr) { IPAddress($0, at: 0) }
        default:
            return nil
        }
    }

    var isV4: Bool { high == 0 && low >> 32 == 0xffff }
    var v4: UInt32 { UInt32(truncatingIfNeeded: low) }
    /// The 16 bytes of an IPv6 address.
    var bytes: [UInt8] {
        var b: [UInt8] = []
        b.be32(UInt32(high >> 32)); b.be32(UInt32(truncatingIfNeeded: high))
        b.be32(UInt32(low >> 32)); b.be32(UInt32(truncatingIfNeeded: low))
        return b
    }
    /// The sum of its 16-bit words, as a checksum's pseudo header takes it (4 bytes for IPv4).
    var wordSum: UInt64 {
        let words = isV4 ? [low & 0xffff_ffff] : [high >> 32, high & 0xffff_ffff, low >> 32, low & 0xffff_ffff]
        return words.reduce(0) { $0 + ($1 >> 16) + ($1 & 0xffff) }
    }
}

/// The Internet checksum (RFC 1071) of `bytes`, plus a partial sum already taken.
func checksum(_ bytes: UnsafeRawBufferPointer, adding initial: UInt64 = 0) -> UInt16 {
    var sum = initial
    var i = 0
    let n = bytes.count
    while i + 8 <= n {
        let word = UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: i, as: UInt64.self))
        sum = sum &+ (word >> 32) &+ (word & 0xffff_ffff)
        i += 8
    }
    while i + 1 < n { sum &+= UInt64(bytes[i]) << 8 | UInt64(bytes[i + 1]); i += 2 }
    if i < n { sum &+= UInt64(bytes[i]) << 8 }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return ~UInt16(sum)
}

/// A host socket address, IPv4 or IPv6.
struct HostEndpoint {
    private var storage = sockaddr_storage()
    let family: Int32

    static func v4(_ address: UInt32, _ port: UInt16) -> HostEndpoint {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = address.bigEndian
        var e = HostEndpoint(family: AF_INET)
        withUnsafeBytes(of: a) { src in withUnsafeMutableBytes(of: &e.storage) { $0.copyMemory(from: src) } }
        return e
    }

    static func v6(_ address: IPAddress, _ port: UInt16) -> HostEndpoint {
        var a = sockaddr_in6()
        a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        a.sin6_family = sa_family_t(AF_INET6)
        a.sin6_port = port.bigEndian
        address.bytes.withUnsafeBytes { src in withUnsafeMutableBytes(of: &a.sin6_addr) { $0.copyMemory(from: src) } }
        var e = HostEndpoint(family: AF_INET6)
        withUnsafeBytes(of: a) { src in withUnsafeMutableBytes(of: &e.storage) { $0.copyMemory(from: src) } }
        return e
    }

    private init(family: Int32) { self.family = family }

    /// A numeric IPv4 or IPv6 address.
    init?(_ text: String, port: UInt16) {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            self = .v4(UInt32(bigEndian: v4.s_addr), port)
        } else if inet_pton(AF_INET6, text, &v6) == 1 {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = port.bigEndian
            a.sin6_addr = v6
            self.init(family: AF_INET6)
            withUnsafeBytes(of: a) { src in withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: src) } }
        } else {
            return nil
        }
    }

    func withSockaddr<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
        return withUnsafeBytes(of: storage) { body($0.baseAddress!.assumingMemoryBound(to: sockaddr.self), length) }
    }
}

/// A non-blocking host socket with a read and a write dispatch source on the net queue. The
/// descriptor is closed when both sources have been cancelled.
final class NetSocket {
    let fd: Int32
    private let readSource: DispatchSourceRead
    private var writeSource: DispatchSourceWrite?
    private var pending = 1
    private var closed = false

    init(fd: Int32, queue: DispatchQueue, onRead: @escaping () -> Void, onWrite: (() -> Void)? = nil) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler(handler: onRead)
        if let onWrite {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler(handler: onWrite)
            writeSource = source
            pending += 1
        }
        var sources: [DispatchSourceProtocol] = [readSource]
        if let writeSource { sources.append(writeSource) }
        for source in sources {
            // Holds the socket until the descriptor is closed.
            source.setCancelHandler { [self] in
                self.pending -= 1
                if self.pending == 0 { Darwin.close(self.fd) }
            }
        }
    }

    /// Whether the read source fires. Sources start off.
    var reading = false {
        didSet { if !closed && reading != oldValue { reading ? readSource.resume() : readSource.suspend() } }
    }

    var writing = false {
        didSet { if !closed && writing != oldValue, let w = writeSource { writing ? w.resume() : w.suspend() } }
    }

    /// Cancels both sources, which closes the descriptor. `reset` makes TCP send RST, not FIN.
    func close(reset: Bool = false) {
        guard !closed else { return }
        closed = true
        if reset {
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        }
        // A suspended source must be resumed before it is cancelled.
        if !reading { readSource.resume() }
        readSource.cancel()
        if let w = writeSource {
            if !writing { w.resume() }
            w.cancel()
        }
    }
}

extension UnsafeRawBufferPointer {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) << 8 | UInt16(self[offset + 1]) }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) << 16 | UInt32(u16(offset + 2)) }
}

extension Array where Element == UInt8 {
    mutating func be16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xff)) }
    mutating func be32(_ v: UInt32) { be16(UInt16(v >> 16)); be16(UInt16(v & 0xffff)) }
}
