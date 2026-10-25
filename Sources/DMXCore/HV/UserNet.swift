import Foundation

/// dmx's user space NAT behind `VirtioNet` (design in docs/network.md). The guest's Ethernet
/// frames end here: ARP is answered, and each TCP, UDP or ICMP echo flow is carried by an ordinary
/// socket of the dmx process, the way passt and slirp do it. dmx needs no root, no network
/// entitlement and no host interface, and the guest's traffic leaves as dmx's own (VPNs, the
/// firewall and proxies apply as to any app). Only IPv4 for now. All of it runs on `queue`.
///
/// Addresses, as the guest sees them (static, set by guest/init):
/// - 192.168.127.2: the guest.
/// - 192.168.127.1: the gateway. DNS on port 53 is answered by macOS's resolver (HostDNS); DNS over
///   TCP goes to the host's DNS server (from /etc/resolv.conf).
/// - 192.168.127.254: the host itself; connections go to the host's 127.0.0.1.
/// Everything else is the outside world, reached from the host's sockets.
final class UserNet: @unchecked Sendable {
    static let guest: UInt32 = 0xc0a8_7f02
    static let gateway: UInt32 = 0xc0a8_7f01
    static let host: UInt32 = 0xc0a8_7ffe
    static let subnet: UInt32 = 0xc0a8_7f00   // /24
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
    private var icmp: (socket: NetSocket, lastUsed: ContinuousClock.Instant)?
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
        let remote: UInt32  // as the guest addressed it
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
        icmp?.socket.close()
        icmp = nil
        dns.reset()
        timer?.cancel()
        timer = nil
    }

    /// Where a guest flow to `address:port` goes on the host, or nil if nowhere.
    func endpoint(for address: UInt32, port: UInt16) -> HostEndpoint? {
        switch address {
        case Self.host: return .v4(0x7f00_0001, port)
        case Self.gateway: return port == 53 ? resolver : nil
        default:
            // The guest's own subnet, "this network", loopback, multicast and broadcast stay inside.
            if address & 0xffff_ff00 == Self.subnet || address >> 24 == 0 || address >> 24 == 127 || address >= 0xe000_0000 {
                return nil
            }
            return .v4(address, port)
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
        default: break  // IPv6 and the rest: not routed
        }
    }

    private func arp(_ p: UnsafeRawBufferPointer) {
        // Ethernet/IPv4 request for the gateway or the host address: both are us.
        guard p.count >= 28, p.u16(0) == 1, p.u16(2) == 0x0800, p[4] == 6, p[5] == 4, p.u16(6) == 1 else { return }
        let target = p.u32(24)
        guard target == Self.gateway || target == Self.host else { return }
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
              p.u32(12) == Self.guest else { return }
        let destination = p.u32(16)
        let payload = UnsafeRawBufferPointer(rebasing: p[headerLength..<total])
        switch p[9] {
        case 1: icmp(payload, to: destination)
        case 6: tcpSegment(payload, to: destination)
        case 17: udp(payload, to: destination)
        default: break
        }
    }

    // MARK: ICMP echo

    /// Echo requests go out through an unprivileged ICMP socket (`SOCK_DGRAM`, `IPPROTO_ICMP`),
    /// which keeps the identifier and sequence; the gateway answers its own.
    private func icmp(_ p: UnsafeRawBufferPointer, to destination: UInt32) {
        guard p.count >= 8, p[0] == 8, p[1] == 0 else { return }  // echo request only
        var message = Array(p)
        message[2] = 0; message[3] = 0
        if destination == Self.gateway {
            message[0] = 0
            device.send(ipv4Frame(protocol: 1, from: Self.gateway, transport: message, payload: UnsafeRawBufferPointer(start: nil, count: 0)))
            return
        }
        guard let endpoint = endpoint(for: destination, port: 0), endpoint.family == AF_INET else { return }
        if icmp == nil {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
            guard fd >= 0 else { return }
            let socket = NetSocket(fd: fd, queue: queue, onRead: { [unowned self] in self.icmpReply() })
            socket.reading = true
            icmp = (socket, .now)
            startTimer()
        }
        let sum = message.withUnsafeBytes { checksum($0) }
        message[2] = UInt8(sum >> 8); message[3] = UInt8(sum & 0xff)
        icmp!.lastUsed = .now
        _ = endpoint.withSockaddr { address, length in sendto(icmp!.socket.fd, message, message.count, 0, address, length) }
    }

    private func icmpReply() {
        guard let fd = icmp?.socket.fd else { return }
        while true {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &scratch, scratch.count, 0, $0, &length) }
            }
            guard n > 0 else { return }
            scratch.withUnsafeBytes { raw in
                var p = UnsafeRawBufferPointer(rebasing: raw[..<n])
                // macOS hands back the IP header too.
                if p[0] >> 4 == 4 {
                    let headerLength = Int(p[0] & 0xf) * 4
                    guard p.count >= headerLength + 8 else { return }
                    p = UnsafeRawBufferPointer(rebasing: p[headerLength...])
                }
                guard p.count >= 8, p[0] == 0 else { return }
                var source = UInt32(bigEndian: from.sin_addr.s_addr)
                if source == 0x7f00_0001 { source = Self.host }
                var message = Array(p)
                message[2] = 0; message[3] = 0
                device.send(ipv4Frame(protocol: 1, from: source, transport: message, payload: UnsafeRawBufferPointer(start: nil, count: 0)))
            }
        }
    }

    // MARK: UDP

    private func udp(_ p: UnsafeRawBufferPointer, to destination: UInt32) {
        guard p.count >= 8 else { return }
        let length = Int(p.u16(4))
        guard length >= 8, length <= p.count else { return }
        let key = FlowKey(guestPort: p.u16(0), remote: destination, remotePort: p.u16(2))
        if destination == Self.gateway, key.remotePort == 53,
           let answer = LocalDNS.answer(UnsafeRawBufferPointer(rebasing: p[8..<length])) {
            var header: [UInt8] = []
            header.be16(53); header.be16(key.guestPort); header.be16(UInt16(8 + answer.count)); header.be16(0)
            answer.withUnsafeBytes { device.send(ipv4Frame(protocol: 17, from: destination, transport: header, payload: $0)) }
            return
        }
        if destination == Self.gateway, key.remotePort == 53,
           dns.resolve(UnsafeRawBufferPointer(rebasing: p[8..<length]), reply: { [weak self] answer in
               guard let self else { return }
               var header: [UInt8] = []
               header.be16(53); header.be16(key.guestPort); header.be16(UInt16(8 + answer.count)); header.be16(0)
               answer.withUnsafeBytes { self.device.send(self.ipv4Frame(protocol: 17, from: destination, transport: header, payload: $0)) }
           }) {
            return
        }
        let flow: UDPFlow
        if let existing = udp[key] {
            flow = existing
        } else {
            guard let endpoint = endpoint(for: destination, port: key.remotePort) else { return }
            // Full: the least recently used flow goes (each DNS query comes from a new port).
            if udp.count >= Self.maxUDP, let oldest = udp.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                oldest.value.socket.close()
                udp[oldest.key] = nil
            }
            let fd = socket(endpoint.family, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return }
            guard endpoint.withSockaddr({ connect(fd, $0, $1) }) == 0 else { close(fd); return }
            let socket = NetSocket(fd: fd, queue: queue, onRead: { [unowned self] in self.udpReply(key) })
            socket.reading = true
            flow = UDPFlow(socket: socket, idle: key.remotePort == 53 ? Self.dnsIdle : Self.udpIdle)
            udp[key] = flow
            startTimer()
        }
        flow.lastUsed = .now
        _ = Darwin.send(flow.socket.fd, p.baseAddress! + 8, length - 8, 0)
    }

    private func udpReply(_ key: FlowKey) {
        guard let flow = udp[key] else { return }
        while true {
            let n = recv(flow.socket.fd, &scratch, scratch.count, 0)
            guard n >= 0 else { return }
            guard n <= VirtioNet.mtu - 28 else { continue }
            flow.lastUsed = .now
            var header: [UInt8] = []
            header.be16(key.remotePort); header.be16(key.guestPort); header.be16(UInt16(8 + n)); header.be16(0)
            scratch.withUnsafeBytes { raw in
                device.send(ipv4Frame(protocol: 17, from: key.remote, transport: header, payload: UnsafeRawBufferPointer(rebasing: raw[..<n])))
            }
        }
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
        if let icmp, now - icmp.lastUsed > Self.icmpIdle {
            icmp.socket.close()
            self.icmp = nil
        }
        tcpTick(now)
        if udp.isEmpty && tcp.isEmpty && icmp == nil {
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: To the guest

    /// An Ethernet frame carrying an IPv4 packet from `source` to the guest. `transport` is the
    /// TCP, UDP or ICMP header with a zero checksum; the checksum is filled in unless the guest
    /// lets us skip it (ICMP always gets one).
    func ipv4Frame(protocol proto: UInt8, from source: UInt32, transport: [UInt8], payload: UnsafeRawBufferPointer) -> [UInt8] {
        let ipLength = 20 + transport.count + payload.count
        var f = [UInt8]()
        f.reserveCapacity(14 + ipLength)
        f += Self.guestMAC; f += Self.gatewayMAC; f.be16(0x0800)
        f.append(0x45); f.append(0); f.be16(UInt16(ipLength)); f.be16(0); f.be16(0x4000)  // don't fragment
        f.append(64); f.append(proto); f.be16(0); f.be32(source); f.be32(Self.guest)
        let ipSum = f.withUnsafeBytes { checksum(UnsafeRawBufferPointer(rebasing: $0[14..<34])) }
        f[24] = UInt8(ipSum >> 8); f[25] = UInt8(ipSum & 0xff)
        f += transport
        if payload.count > 0 { f.append(contentsOf: payload) }
        let offset: Int? = switch proto {
        case 1: 2
        case 6 where !device.checksumsOptional: 16
        case 17 where !device.checksumsOptional: 6
        default: nil
        }
        if let offset {
            // TCP and UDP sum a pseudo header: addresses, protocol, length.
            let pseudo: UInt64 = proto == 1 ? 0 : UInt64(source >> 16) + UInt64(source & 0xffff)
                + UInt64(Self.guest >> 16) + UInt64(Self.guest & 0xffff) + UInt64(proto) + UInt64(ipLength - 20)
            var sum = f.withUnsafeBytes { checksum(UnsafeRawBufferPointer(rebasing: $0[34...]), adding: pseudo) }
            if proto == 17 && sum == 0 { sum = 0xffff }
            f[34 + offset] = UInt8(sum >> 8); f[35 + offset] = UInt8(sum & 0xff)
        }
        return f
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
