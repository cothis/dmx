import Foundation
import Network
import Security

/// What `dmx names ls` shows.
public struct NamesStatus: Codable, Sendable {
    public var enabled: Bool
    public var settings: LocalNames.Settings?
    public var names: [LocalNames.Entry]
    /// `dns`, `http` and `https`: `listening`, `yielded` (a container publishes the port) or an error.
    public var listeners: [String: String]
}

/// The daemon's side of local names: DNS on 127.0.0.1, HTTP and HTTPS on every interface (macOS
/// lets a user listen on ports below 1024 only on the wildcard address) taking connections that
/// arrive on 127.0.0.1 only, and the table of names from Docker's container listing.
@MainActor
final class NamesService {
    private let paths: Paths
    private var settings: LocalNames.Settings?
    private var authority: NameAuthority?
    private var leafKey: P256Key?
    private(set) var entries: [LocalNames.Entry] = []
    private var dns: Held?
    private var http: Held?
    private var https: Held?
    private var state: [String: String] = [:]
    /// TLS listeners on 127.0.0.1 by server name, each with that name's leaf.
    private var tls: [String: TLSBackend] = [:]
    /// Their ports, once listening: guarded from the guest like the web ports.
    private var tlsPorts: [String: UInt16] = [:]
    private var agent: (@MainActor () async throws -> AgentClient)?
    private var using: (@MainActor (Bool) -> Void)?
    /// Whether a `dmx port` or Docker forward listens on a TCP host port.
    private var forwarded: (@MainActor (Int) -> Bool)?
    /// Listening again after a failure: a forward that just stopped closes its socket a moment later.
    private var retry: Task<Void, Never>?
    private var retryDelay = Duration.milliseconds(250)
    /// Connections open, and the malloc trim after a burst (as PortForwards does).
    private var open = 0
    private var trim: Task<Void, Never>?

    init(paths: Paths) { self.paths = paths }

    var enabled: Bool { settings != nil }

    func start(agent: @escaping @MainActor () async throws -> AgentClient, using: @escaping @MainActor (Bool) -> Void,
               forwarded: @escaping @MainActor (Int) -> Bool) {
        self.agent = agent
        self.using = using
        self.forwarded = forwarded
        load()
    }

    /// Reads names.json again (`dmx names setup` or `remove`) and listens as it says.
    func reload() {
        stop()
        load()
    }

    private func load() {
        settings = LocalNames.settings(paths)
        guard let settings else { return }
        do {
            authority = try NameAuthority.load(LocalNames.directory(paths))
            if authority == nil { state["https"] = "no CA in \(LocalNames.directory(paths).path); run `dmx names setup`" }
            leafKey = try P256Key.generate()
        } catch {
            state["https"] = (error as? DMXError)?.message ?? "\(error)"
        }
        do {
            dns = try Self.listenDNS(settings.dnsPort)
            state["dns"] = "listening"
        } catch {
            state["dns"] = (error as? DMXError)?.message ?? "\(error)"
            log("names: dns: \(state["dns"]!)")
        }
        listenWeb()
        log("names: on (dns 127.0.0.1:\(settings.dnsPort), http \(settings.httpPort), https \(settings.httpsPort))")
    }

    func stop() {
        for held in [dns, http, https] { held?.release() }
        dns = nil; http = nil; https = nil
        retry?.cancel()
        retry = nil
        for backend in tls.values { backend.listener.cancel() }
        tls = [:]
        tlsPorts = [:]
        state = [:]
        settings = nil
        syncGuestGuard()
    }

    /// A container started, stopped, was renamed or changed networks: until the next listing the
    /// table may send a name to an address another container has taken. Connections wait for it.
    private var staleSince: ContinuousClock.Instant?

    /// A forward stopped listening: take back a port names gave up to it.
    func portsReleased() {
        guard enabled else { return }
        listenWeb()
    }

    func markStale() {
        guard enabled, staleSince == nil else { return }
        staleSince = .now
    }

    /// The running containers changed. Ports given up to a container are taken back once no
    /// forward holds them.
    func update(_ containers: [[String: Any]]) {
        staleSince = nil
        guard enabled else { return }
        let new = LocalNames.entries(containers)
        if new != entries {
            entries = new
            log("names: \(entries.isEmpty ? "none" : entries.map(\.name).joined(separator: ", "))")
            // A name's TLS listener goes with its container.
            let live = Set(entries.map(\.name))
            for (name, backend) in tls where !live.contains(name) {
                backend.listener.cancel()
                tls[name] = nil
                tlsPorts[name] = nil
            }
            syncGuestGuard()
        }
        listenWeb()
    }

    /// A forward is about to listen on TCP `port`: a container's `-p 80:80` wins over names.
    func yield(_ port: Int) {
        guard let settings else { return }
        if port == settings.httpPort, let held = http {
            held.release(); http = nil
            state["http"] = "yielded: a forward listens on port \(port)"
            log("names: http port \(port) given up to a forward")
        }
        if port == settings.httpsPort, let held = https {
            held.release(); https = nil
            state["https"] = "yielded: a forward listens on port \(port)"
            log("names: https port \(port) given up to a forward")
        }
        syncGuestGuard()
        // The forward may fail to listen after all (the port is taken); look again shortly.
        if retry == nil {
            retry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.retry = nil
                self.listenWeb()
            }
        }
    }

    /// The ports names listens on now, which the guest must not reach through the host gateway
    /// (see GuestHostPorts).
    private func syncGuestGuard() {
        guard let settings else { return GuestHostPorts.shared.set([]) }
        // The TLS listeners on 127.0.0.1 too: reached directly, they serve their name's container.
        var held = Set(tlsPorts.values)
        if http != nil { held.insert(UInt16(settings.httpPort)) }
        if https != nil { held.insert(UInt16(settings.httpsPort)) }
        GuestHostPorts.shared.set(held)
    }

    func status() -> NamesStatus {
        NamesStatus(enabled: enabled, settings: settings, names: entries, listeners: state)
    }

    // MARK: Listening

    private func listenWeb() {
        guard let settings else { return }
        if http == nil, !(forwarded?(settings.httpPort) ?? false) {
            do {
                http = try listenTCP(settings.httpPort) { [unowned self] fd in Task { await serveHTTP(fd, tlsName: nil) } }
                state["http"] = "listening"
            } catch {
                state["http"] = (error as? DMXError)?.message ?? "\(error)"
            }
        } else if http == nil {
            state["http"] = "yielded: a forward listens on port \(settings.httpPort)"
        }
        if https == nil, authority != nil, !(forwarded?(settings.httpsPort) ?? false) {
            do {
                https = try listenTCP(settings.httpsPort) { [unowned self] fd in Task { await serveTLS(fd) } }
                state["https"] = "listening"
            } catch {
                state["https"] = (error as? DMXError)?.message ?? "\(error)"
            }
        } else if https == nil, authority != nil {
            state["https"] = "yielded: a forward listens on port \(settings.httpsPort)"
        }
        syncGuestGuard()
        let failed = (http == nil && !(forwarded?(settings.httpPort) ?? false))
            || (https == nil && authority != nil && !(forwarded?(settings.httpsPort) ?? false))
        if !failed {
            retryDelay = .milliseconds(250)
        } else if retry == nil {
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, .seconds(30))
            retry = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.retry = nil
                self.listenWeb()
            }
        }
    }

    /// A TCP listener on 0.0.0.0:`port` that hands on connections made to 127.0.0.1 and closes
    /// the others.
    private func listenTCP(_ port: Int, _ accepted: @escaping @MainActor (Int32) -> Void) throws -> Held {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DMXError("names_error", "socket: \(String(cString: strerror(errno)))", hint: "see `dmx names status`; `dmx doctor` checks the descriptors") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        let bound = HostEndpoint.v4(0, UInt16(port)).withSockaddr { bind(fd, $0, $1) } == 0 && listen(fd, 128) == 0
        guard bound else {
            let code = errno
            Darwin.close(fd)
            throw DMXError(code == EADDRINUSE ? "port_in_use" : "names_error",
                           "cannot listen on port \(port): \(String(cString: strerror(code)))",
                           hint: "find the owner with `lsof -nP -iTCP:\(port) -sTCP:LISTEN`")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                while true {
                    let client = Darwin.accept(fd, nil, nil)
                    guard client >= 0 else { return }
                    _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                    var on: Int32 = 1
                    _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                    guard Self.arrivedOnLoopback(client) else { Darwin.close(client); continue }
                    _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                    accepted(client)
                }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return Held(source: source, fd: fd)
    }

    /// Whether the connection was made to 127.0.0.0/8, so other machines get nothing.
    nonisolated static func arrivedOnLoopback(_ fd: Int32) -> Bool {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) == 0 }
        }
        return ok && address.sin_family == sa_family_t(AF_INET) && UInt32(bigEndian: address.sin_addr.s_addr) >> 24 == 127
    }

    nonisolated private static func listenDNS(_ port: Int) throws -> Held {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw DMXError("names_error", "socket: \(String(cString: strerror(errno)))", hint: "see `dmx names status`; `dmx doctor` checks the descriptors") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard HostEndpoint.v4(0x7f00_0001, UInt16(port)).withSockaddr({ bind(fd, $0, $1) }) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw DMXError("port_in_use", "cannot listen on 127.0.0.1:\(port)/udp: \(String(cString: strerror(code)))",
                           hint: "run `dmx names setup --dns-port <port>` with a free port")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 1500)
            while true {
                var peer = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = withUnsafeMutablePointer(to: &peer) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
                }
                guard n > 0 else { return }
                guard let reply = LocalNames.dnsAnswer(Array(buffer[..<n])) else { continue }
                _ = withUnsafePointer(to: &peer) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, reply, reply.count, 0, $0, length) }
                }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return Held(source: source, fd: fd)
    }

    // MARK: Connections

    /// Reads a request head (or, with `tlsName`, takes the name TLS was for), then connects the
    /// client to the container the name leads to. A name with no running container gets a 404
    /// listing the names there are.
    private func serveHTTP(_ fd: Int32, tlsName: String?) async {
        open += 1
        defer {
            Darwin.close(fd)
            open -= 1
            if open == 0 { trimSoon() }
        }
        guard let (prefix, head) = await Self.readHead(fd, parse: LocalNames.requestHost) else { return }
        guard case .host(let header) = head else { return }
        // A table an event made stale is not used: wait for the listing, briefly.
        let waitUntil = ContinuousClock.now + .seconds(3)
        while staleSince != nil, ContinuousClock.now < waitUntil { try? await Task.sleep(for: .milliseconds(50)) }
        if staleSince != nil {
            Self.write(fd, LocalNames.httpReply("503 Service Unavailable", "dmx: the containers changed and their list is not read yet; try again"))
            return
        }
        let host = tlsName ?? header
        guard let host, let entry = entries.first(where: { $0.name == host }) else {
            let known = entries.isEmpty ? "no container is running" : "names: " + entries.map(\.name).joined(separator: ", ")
            Self.write(fd, LocalNames.httpReply("404 Not Found", "dmx: no running container answers to \(host ?? "this address"); \(known)"))
            return
        }
        guard let agent else { return }
        using?(true)
        defer { using?(false) }
        let stream: FrameConnection
        do {
            stream = try await agent().connect(port: entry.port, host: entry.address)
        } catch {
            let message = (error as? DMXError)?.message ?? "\(error)"
            Self.write(fd, LocalNames.httpReply("502 Bad Gateway",
                "dmx: \(entry.container) does not answer on port \(entry.port) (\(message)); set the container label \(LocalNames.portLabel) to its web port"))
            return
        }
        defer { stream.close() }
        guard Self.write(stream.fd, prefix) else { return }
        await splice(fd, stream.fd)
    }

    /// malloc keeps what a burst of connections emptied; give it back once they are quiet, and
    /// again after Network.framework let go of the TLS connections (it holds them for a minute
    /// or two: 200 connections left 7 MB of free pages until then).
    private func trimSoon() {
        trim?.cancel()
        trim = Task {
            for wait in [2, 150] {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, open == 0 else { return }
                malloc_zone_pressure_relief(nil, 0)
            }
        }
    }

    /// Takes the TLS server name from the ClientHello and hands the connection, bytes read
    /// included, to that name's TLS listener on 127.0.0.1.
    private func serveTLS(_ fd: Int32) async {
        defer { Darwin.close(fd) }
        guard let (prefix, head) = await Self.readHead(fd, parse: LocalNames.serverName),
              case .host(let sni) = head, let name = sni,
              name.hasSuffix(".\(LocalNames.domain)"), LocalNames.dnsName(String(name.dropLast(LocalNames.domain.count + 1))) == name,
              // A listener and a leaf only for the names of running containers: any page or
              // program on this Mac can send any server name, and each would cost a listener.
              entries.contains(where: { $0.name == name })
        else { return }
        let port: UInt16
        do {
            port = try await backend(name)
        } catch {
            log("names: tls \(name): \((error as? DMXError)?.message ?? "\(error)")")
            return
        }
        let inner = socket(AF_INET, SOCK_STREAM, 0)
        guard inner >= 0 else { return }
        defer { Darwin.close(inner) }
        var on: Int32 = 1
        _ = setsockopt(inner, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard HostEndpoint.v4(0x7f00_0001, port).withSockaddr({ connect(inner, $0, $1) }) == 0,
              Self.write(inner, prefix) else { return }
        await splice(fd, inner)
    }

    /// The port of `name`'s TLS listener, made on first use.
    private func backend(_ name: String) async throws -> UInt16 {
        if let existing = tls[name] { return try await existing.port.value }
        guard let authority, let leafKey else {
            throw DMXError("names_error", "no CA for HTTPS names", hint: "run `dmx names setup`")
        }
        let identity = try authority.identity(name, leafKey: leafKey)
        let backend = try TLSBackend(identity: identity) { [unowned self] plain in
            Task { @MainActor in await serveHTTP(plain, tlsName: name) }
        }
        tls[name] = backend
        do {
            let port = try await backend.port.value
            if tls[name] === backend {
                tlsPorts[name] = port
                syncGuestGuard()
            }
            return port
        } catch {
            tls[name] = nil
            throw error
        }
    }

    /// Reads until `parse` is satisfied, at most 64 KiB and 10 s.
    nonisolated static func readHead(_ fd: Int32, parse: @escaping @Sendable ([UInt8]) -> LocalNames.Head) async -> ([UInt8], LocalNames.Head)? {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                var bytes: [UInt8] = []
                var buffer = [UInt8](repeating: 0, count: 16384)
                let deadline = Date().addingTimeInterval(10)
                while bytes.count < 65536 {
                    var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let wait = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
                    guard wait > 0, poll(&ready, 1, wait) > 0 else { break }
                    let n = read(fd, &buffer, buffer.count)
                    guard n > 0 else { break }
                    bytes += buffer[..<n]
                    let head = parse(bytes)
                    if head != .incomplete { return continuation.resume(returning: (bytes, head)) }
                }
                continuation.resume(returning: nil)
            }
        }
    }

    @discardableResult
    nonisolated static func write(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }
}

/// A listening socket and its dispatch source.
struct Held {
    let source: DispatchSourceRead
    let fd: Int32

    /// Gives the port up now: the descriptor becomes an unbound socket at once (dup2 is atomic),
    /// so a forward can listen on the port right after, while the source's cancel handler
    /// still owns the descriptor number and closes it later.
    func release() {
        let dummy = socket(AF_INET, SOCK_DGRAM, 0)
        if dummy >= 0 {
            _ = dup2(dummy, fd)
            Darwin.close(dummy)
        }
        source.cancel()
    }
}

/// A TLS listener on 127.0.0.1 with one identity. Each connection's plaintext comes out of one
/// end of a socketpair, handed to `accepted`.
final class TLSBackend: @unchecked Sendable {
    let listener: NWListener
    let port: Task<UInt16, Error>
    private let queue = DispatchQueue(label: "dmx.names.tls")

    init(identity: SecIdentity, accepted: @escaping @Sendable (Int32) -> Void) throws {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        guard let local = sec_identity_create(identity) else {
            throw DMXError("names_error", "cannot use the TLS identity", hint: "run `dmx names remove`, then `dmx names setup` to make a new CA")
        }
        sec_protocol_options_set_local_identity(sec, local)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        // The containers speak HTTP/1.1; offering only it keeps browsers off HTTP/2.
        sec_protocol_options_add_tls_application_protocol(sec, "http/1.1")
        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let listener = listener, queue = queue
        port = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
                let once = Once()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                    case .failed(let error): once.run { continuation.resume(throwing: DMXError("names_error", "tls listener: \(error)", hint: "see `dmx names status`")) }
                    case .cancelled: once.run { continuation.resume(throwing: DMXError("names_error", "tls listener cancelled", hint: "see `dmx names status`")) }
                    default: break
                    }
                }
                listener.newConnectionHandler = { connection in
                    var pair: [Int32] = [0, 0]
                    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return connection.cancel() }
                    for fd in pair {
                        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                        var on: Int32 = 1
                        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                    }
                    ConnectionPump(connection, fd: pair[0]).start()
                    accepted(pair[1])
                }
                listener.start(queue: queue)
            }
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

/// Copies between an NWConnection and a stream socket until both directions end, then closes
/// the socket and cancels the connection.
private final class ConnectionPump: @unchecked Sendable {
    private let connection: NWConnection
    private let fd: Int32
    /// The connection's callbacks, never blocked.
    private let queue = DispatchQueue(label: "dmx.names.conn")
    /// Blocking writes to the socket, one at a time; the next receive waits for each.
    private let writer = DispatchQueue(label: "dmx.names.conn.write")
    private let lock = NSLock()
    private var ended = 0
    /// Whether the connection got ready, so the two copies run and end() closes the socket.
    private var pumping = false

    init(_ connection: NWConnection, fd: Int32) {
        self.connection = connection
        self.fd = fd
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                lock.withLock { pumping = true }
                receive()
                Thread.detachNewThread { [self] in fromSocket() }
            case .failed:
                // Unblocks the socket side, unless end() closed the descriptor already: its
                // number may belong to another connection by now.
                let never = lock.withLock { () -> Bool in
                    if ended < 2 { shutdown(fd, SHUT_RDWR) }
                    return !pumping
                }
                // A handshake that failed (a client that does not trust the CA, a scan) never
                // started the copies, so nothing else would close the socket or the connection.
                if never { connection.cancel() }
            case .cancelled:
                lock.withLock {
                    if ended < 2 { shutdown(fd, SHUT_RDWR) }
                    if !pumping && ended < 2 { ended = 2; Darwin.close(fd) }
                }
                // The handler holds the pump, which holds the connection.
                connection.stateUpdateHandler = nil
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func end() {
        let both = lock.withLock {
            ended += 1
            if ended == 2 { Darwin.close(fd) }
            return ended == 2
        }
        if both { connection.cancel() }
    }

    /// Connection to socket. The next receive waits until the socket took the last bytes, which
    /// is what holds the sender back when the container reads slowly.
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            writer.async { [self] in
                if let data, !data.isEmpty, !NamesService.write(fd, Array(data)) {
                    shutdown(fd, SHUT_WR)
                    return end()
                }
                if complete || error != nil {
                    shutdown(fd, SHUT_WR)
                    return end()
                }
                receive()
            }
        }
    }

    /// Socket to connection, one send in flight at a time.
    private func fromSocket() {
        let size = 65536
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        let sent = DispatchSemaphore(value: 0)
        let failed = Flag()
        while true {
            let n = readSocket(fd, buffer, size)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            connection.send(content: Data(bytes: buffer, count: n), completion: .contentProcessed { error in
                if error != nil { failed.set() }
                sent.signal()
            })
            sent.wait()
            if failed.isSet { return end() }
        }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        end()
    }
}
