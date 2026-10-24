import Foundation

/// The Docker API on the host, `~/.dmx/docker.sock`, served by dockerd in the guest (see
/// docs/docker.md). Each connection boots the VM if needed, starts dockerd the first time after
/// a boot (agent `docker_start`), and is spliced to the guest's /var/run/docker.sock through
/// agent `connect`. An open connection uses the VM like a forwarded port does.
///
/// While dockerd runs, the daemon follows its container events: running containers keep the VM
/// from stopping for being idle (`containers` in `dmx status`), and the TCP ports they publish
/// are forwarded from the host as Docker Desktop does (`PortForwards.setDockerForwards`).
@MainActor
final class DockerBridge {
    static let guestSocket = "/var/run/docker.sock"
    static let guestLog = "/var/lib/dmx/log/dockerd.log"

    private let paths: Paths
    private let ports: PortForwards
    private var source: DispatchSourceRead?
    /// Whether this process bound the socket (standalone), so it removes it on exit.
    private var ownsSocket = false
    private var agent: (@MainActor () async throws -> AgentClient)?
    private var using: (@MainActor (Bool) -> Void)?
    private var changed: (@MainActor () -> Void)?

    /// dockerd has answered since the VM booted.
    private var up = false
    private var starting: Task<Void, Error>?
    private var watcher: Task<Void, Never>?
    /// The events stream, shut down to end the watcher when the VM stops.
    private var events: FrameConnection?
    private var syncing = false, syncAgain = false
    /// Bumped when the VM stops, so work begun for that VM leaves the next one alone.
    private var epoch = 0
    /// Running containers while the daemon follows dockerd; nil before Docker is used after a boot.
    private(set) var containers: Int?
    /// A Docker client connected since the daemon started (or since the last `dmx stop`).
    var used = false

    init(paths: Paths, ports: PortForwards) {
        self.paths = paths
        self.ports = ports
    }

    /// A daemon the CLI started stays up once Docker was used: nothing else would answer on
    /// docker.sock. Under launchd it exits as usual and launchd keeps the socket.
    var keepsDaemon: Bool { ownsSocket && used }

    /// Whether running containers count as using the VM.
    var busy: Bool { (containers ?? 0) > 0 }

    /// Listens on the socket launchd holds for us (`Sockets.Docker` in the plist), or binds it.
    func start(agent: @escaping @MainActor () async throws -> AgentClient, using: @escaping @MainActor (Bool) -> Void,
               changed: @escaping @MainActor () -> Void) {
        self.agent = agent
        self.using = using
        self.changed = changed
        let fd: Int32
        do {
            if let launchd = try launchdSocket("Docker") {
                fd = launchd
            } else {
                fd = try listenUnix(paths.dockerSocket)
                ownsSocket = true
            }
        } catch {
            return log("docker: \((error as? DMXError)?.message ?? "\(error)"); no Docker socket")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [unowned self] in MainActor.assumeIsolated { accept(fd) } }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        self.source = source
    }

    /// Stops listening (the daemon is exiting).
    func stop() {
        source?.cancel()
        source = nil
        if ownsSocket { unlink(paths.dockerSocket.path) }
    }

    /// The VM stopped: dockerd and its containers are gone, and so are their forwards.
    func vmStopped() {
        epoch += 1
        up = false
        starting = nil
        syncing = false
        watcher?.cancel()
        watcher = nil
        if let events { shutdown(events.fd, SHUT_RDWR) }
        events = nil
        ports.setDockerForwards([])
        if containers != nil {
            containers = nil
            changed?()
        }
    }

    // MARK: Clients

    private func accept(_ listener: Int32) {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Task { await forward(fd) }
        }
    }

    private func forward(_ client: Int32) async {
        used = true
        using?(true)
        defer {
            Darwin.close(client)
            using?(false)
        }
        let stream: FrameConnection
        do {
            stream = try await connect()
        } catch {
            let failure = error as? DMXError ?? DMXError("docker_failed", "\(error)")
            log("docker: \(failure.message)")
            refuse(client, failure)
            return
        }
        await splice(client, stream.fd)
        stream.close()
    }

    /// A connection to dockerd, booting the VM and starting dockerd first if needed. If dockerd
    /// went away since it last answered, it is started again.
    private func connect() async throws -> FrameConnection {
        guard let agent else { throw DMXError("daemon_exiting", "the daemon is shutting down") }
        let client = try await agent()
        try await ensureDocker(client)
        do {
            return try await client.connect(path: Self.guestSocket)
        } catch let error as DMXError where error.code == "agent_connect_failed" {
            up = false
            try await ensureDocker(client)
            return try await client.connect(path: Self.guestSocket)
        }
    }

    /// Docker clients print an error reply's `message` ("Error response from daemon: ...").
    private func refuse(_ client: Int32, _ error: DMXError) {
        let body = (try? JSONSerialization.data(withJSONObject: ["message": "dmx: \(error.message)" + (error.hint.map { " (\($0))" } ?? "")])) ?? Data()
        let head = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let reply = Data(head.utf8) + body
        _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }

    // MARK: dockerd

    private func ensureDocker(_ agent: AgentClient) async throws {
        if up { return }
        if let starting { return try await starting.value }
        let epoch = self.epoch
        let task = Task { @MainActor in
            let begun = ContinuousClock.now
            // Its own connection: the first start may take seconds, and the control connection
            // serves the memory controller meanwhile.
            let connection = try await agent.open()
            defer { connection.close() }
            struct Started: Decodable { let started: Bool }
            let result: Started
            do {
                result = try await connection.call("docker_start", NoParams())
            } catch let error as DMXError {
                throw DMXError("docker_failed", error.message, hint: "see the log: `dmx exec -- tail -50 \(Self.guestLog)`")
            }
            guard epoch == self.epoch else { throw DMXError("vm_stopped", "the VM stopped while dockerd started", hint: "retry") }
            log(result.started ? "dockerd up in \(milliseconds(ContinuousClock.now - begun)) ms" : "dockerd answers")
            up = true
            follow(agent)
        }
        starting = task
        defer { if epoch == self.epoch { starting = nil } }
        try await task.value
    }

    /// Follows container starts and deaths until dockerd or the VM goes away: subscribes to
    /// events first, then lists containers, so nothing falls between the two.
    private func follow(_ agent: AgentClient) {
        let epoch = self.epoch
        watcher?.cancel()
        watcher = Task { @MainActor in
            while epoch == self.epoch && !Task.isCancelled {
                do {
                    let stream = try await agent.connect(path: Self.guestSocket)
                    events = stream
                    try await DockerHTTP.send(stream.fd, Self.eventsPath)
                    syncSoon(agent, epoch)
                    // The task already holds self until dockerd or the VM goes away.
                    await DockerHTTP.lines(stream.fd) {
                        DispatchQueue.main.async { MainActor.assumeIsolated { self.syncSoon(agent, epoch) } }
                    }
                    events = nil
                    stream.close()
                } catch {
                    events = nil
                    log("docker: events: \((error as? DMXError)?.message ?? "\(error)")")
                }
                guard epoch == self.epoch, !Task.isCancelled else { return }
                // The stream ended with the VM still up: dockerd restarted or died.
                let probe = try? await agent.connect(path: Self.guestSocket)
                probe?.close()
                if probe == nil {
                    log("docker: dockerd stopped answering")
                    up = false
                    ports.setDockerForwards([])
                    containers = nil
                    changed?()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static let eventsPath = "/events?filters=" + (#"{"type":["container"],"event":["start","die"]}"#
        .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")

    /// Lists the containers again; events coming in meanwhile cause one more listing.
    private func syncSoon(_ agent: AgentClient, _ epoch: Int) {
        guard epoch == self.epoch else { return }
        if syncing { syncAgain = true; return }
        syncing = true
        Task { @MainActor in
            repeat {
                syncAgain = false
                await sync(agent, epoch)
            } while syncAgain && epoch == self.epoch
            if epoch == self.epoch { syncing = false }
        }
    }

    private func sync(_ agent: AgentClient, _ epoch: Int) async {
        let list: [[String: Any]]
        do {
            let stream = try await agent.connect(path: Self.guestSocket)
            defer { stream.close() }
            let body = try await DockerHTTP.get(stream.fd, "/containers/json")
            list = try JSONSerialization.jsonObject(with: body) as? [[String: Any]] ?? []
        } catch {
            return log("docker: cannot list containers: \((error as? DMXError)?.message ?? "\(error)")")
        }
        guard epoch == self.epoch else { return }
        ports.setDockerForwards(Self.published(list))
        if containers != list.count {
            containers = list.count
            changed?()
        }
    }

    /// The host forwards for the TCP ports running containers publish. Docker Desktop listens
    /// where the container asked: `-p 8080:80` on every interface (0.0.0.0), `-p 127.0.0.1:8080:80`
    /// on loopback only. In the guest, docker-proxy listens on the same port, so the agent
    /// connects to it on loopback. IPv6 bindings (`::`) repeat the IPv4 ones; UDP is not forwarded.
    nonisolated static func published(_ containers: [[String: Any]]) -> [PortForward] {
        var wanted: [PortForward] = []
        for container in containers {
            for port in container["Ports"] as? [[String: Any]] ?? [] {
                guard port["Type"] as? String == "tcp", let number = port["PublicPort"] as? Int else { continue }
                let address = port["IP"] as? String ?? "0.0.0.0"
                guard address == "0.0.0.0" || address == "127.0.0.1" else { continue }
                let forward = PortForward(hostAddress: address, hostPort: number, guestPort: number)
                if !wanted.contains(forward) { wanted.append(forward) }
            }
        }
        return wanted
    }
}

/// Just enough HTTP to ask dockerd for its containers and events: HTTP/1.0, so the reply is not
/// chunked and ends when the connection closes. Blocking reads run on their own thread.
enum DockerHTTP {
    static func send(_ fd: Int32, _ path: String) async throws {
        let request = Data("GET \(path) HTTP/1.0\r\nHost: docker\r\n\r\n".utf8)
        try await onThread {
            try request.withUnsafeBytes { buf in
                var offset = 0
                while offset < buf.count {
                    let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw DMXError("docker_failed", "write to dockerd: \(String(cString: strerror(errno)))") }
                    offset += n
                }
            }
        }
    }

    /// The body of a successful GET.
    static func get(_ fd: Int32, _ path: String) async throws -> Data {
        try await send(fd, path)
        let reply = try await onThread { () throws -> Data in
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            while data.count < 64 << 20 {
                let n = read(fd, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                if n < 0 { throw DMXError("docker_failed", "read from dockerd: \(String(cString: strerror(errno)))") }
                if n == 0 { break }
                data.append(contentsOf: buffer[..<n])
            }
            return data
        }
        guard let end = reply.range(of: Data("\r\n\r\n".utf8)) else {
            throw DMXError("docker_failed", "dockerd sent no HTTP reply to \(path)")
        }
        let status = String(decoding: reply[..<end.lowerBound], as: UTF8.self).prefix { $0 != "\r" }
        guard status.split(separator: " ").dropFirst().first == "200" else {
            throw DMXError("docker_failed", "dockerd answered \(path) with \(status)")
        }
        return reply[end.upperBound...]
    }

    /// Calls `line` for each line of the body (one JSON event each) until the stream ends.
    static func lines(_ fd: Int32, _ line: @escaping @Sendable () -> Void) async {
        _ = try? await onThread {
            var buffer = [UInt8](repeating: 0, count: 16 << 10)
            var inBody = false
            var tail: [UInt8] = []
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }
                for byte in buffer[..<n] {
                    if !inBody {
                        tail.append(byte)
                        if tail.suffix(4).elementsEqual([13, 10, 13, 10]) { inBody = true; tail = [] }
                        if tail.count > 64 << 10 { return }
                    } else if byte == 10 {
                        line()
                    }
                }
            }
        }
    }

    private static func onThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
        }
    }
}
