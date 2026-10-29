import Foundation

/// `dmx daemon`: owns the VM and serves the control socket. The VM boots when a client first
/// needs it and stops after `idle_timeout` with nobody using it; the daemon itself exits once
/// the VM is stopped and no client is connected, so an idle dmx costs nothing. With `dmx install`
/// launchd holds the socket and starts the daemon again on the next connection; without it the
/// CLI starts one.
@MainActor
public final class Daemon {
    public enum State: String, Sendable { case stopped, starting, running, stopping }

    /// How long a daemon whose VM is stopped waits for clients before exiting. launchd delays
    /// relaunching a job that ran for less than 10 s, so exiting sooner would slow the next command.
    static let linger: Duration = .seconds(10)

    private let paths: Paths
    private let diagnosticLogs: DaemonLogs
    private let version: String
    private let listener: Int32
    private let launchd: Bool
    private var accepting: DispatchSourceRead?
    private var signalSources: [DispatchSourceSignal] = []
    private var finished: CheckedContinuation<Void, Never>?
    private var exiting = false

    private var state = State.stopped
    private var activitySequence: UInt64 = 0
    private var machine: Machine?
    private var agent: AgentClient?
    private var booting: Task<AgentClient, Error>?
    private var stopping: Task<Void, Never>?
    private var bootedAt: ContinuousClock.Instant?
    private var lastTimeSync = ContinuousClock.now
    private var idleTimeout = Config.defaultIdleTimeout

    /// Open connections, and those among them that asked for the VM (start, exec).
    private var clients = 0
    private var users = 0
    private var execs = 0
    /// Since when no connection has used the VM, and since when nothing at all happened.
    private var idleSince = ContinuousClock.now
    private var quietSince = ContinuousClock.now
    private var idleCheck: Task<Void, Never>?
    private var dockerWasBusy = false
    /// Idle trims, host pressure and the balloon (MemoryController.swift).
    private let memory = MemoryController()
    /// Host ports forwarded to the guest (`dmx port`); see PortForward.swift.
    private let ports: PortForwards
    /// `~/.dmx/docker.sock` and the containers behind it; see Docker.swift.
    private let docker: DockerBridge
    /// Removes sandboxes at their TTL (Sandbox/SandboxReaper.swift).
    private let sandboxReaper = SandboxReaper()

    /// Takes the control socket from launchd when launchd started us, otherwise binds it.
    public init(paths: Paths, version: String) throws {
        self.paths = paths
        self.version = version
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try Self.takeLock(paths)
        Diagnostics.detachLegacyLog(paths.daemonLog)
        diagnosticLogs = DaemonLogs(paths: paths)
        if let fd = try launchdSocket() {
            listener = fd
            launchd = true
        } else {
            listener = try listenUnix(paths.controlSocket)
            launchd = false
        }
        idleTimeout = (try? Config.load(paths))?.idleTimeoutSeconds ?? Config.defaultIdleTimeout
        ports = PortForwards(paths: paths)
        docker = DockerBridge(paths: paths, ports: ports)
    }

    /// Serves until the daemon decides to exit (idle, `quit`, SIGTERM or SIGINT).
    public func run() async {
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
        source.setEventHandler { [unowned self] in MainActor.assumeIsolated { acceptClients() } }
        source.resume()
        accepting = source
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: number, queue: .main)
            s.setEventHandler { [unowned self] in
                MainActor.assumeIsolated {
                    log("signal \(number), shutting down")
                    Task { await shutdown() }
                }
            }
            s.resume()
            signalSources.append(s)
        }
        // A forwarded connection uses the VM like an exec does: it boots it and holds off idle stop.
        // So does a Docker client's connection, and so does a running container.
        let using: @MainActor (Bool) -> Void = { [unowned self] open in
            users += open ? 1 : -1
            if !open { idleSince = .now }
            memory.noteActivity()
            scheduleIdleCheck()
        }
        ports.start(agent: { [unowned self] in try await running() }, using: using)
        docker.start(agent: { [unowned self] in try await running() }, using: using) { [unowned self] in
            if dockerWasBusy && !docker.busy { idleSince = .now }
            dockerWasBusy = docker.busy
            sandboxReaper.update(agent: docker.containers == nil ? nil : agent)
            scheduleIdleCheck()
            publishActivity()
        }
        log("listening on \(paths.controlSocket.path) (\(launchd ? "launchd" : "standalone"), pid \(getpid()))")
        scheduleIdleCheck()
        publishActivity()
        await withCheckedContinuation { finished = $0 }
        log("exiting")
    }

    // MARK: Clients

    private func acceptClients() {
        while !exiting {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            clients += 1
            idleCheck?.cancel()
            let connection = FrameConnection(fd: fd, peer: .daemon) { _ = Darwin.close(fd) }
            Task {
                let use = await serve(connection)
                connection.close()
                clients -= 1
                if use.usedVM {
                    users -= 1
                    if use.resetsIdle { idleSince = .now }
                }
                quietSince = .now
                scheduleIdleCheck()
            }
        }
    }

    /// Answers requests until the client leaves or starts an exec. Returns whether it used the VM.
    private func serve(_ connection: FrameConnection) async -> (usedVM: Bool, resetsIdle: Bool) {
        var usesVM = false
        var resetsIdle = false
        func claimVM(passive: Bool = false) {
            if !usesVM { usesVM = true; users += 1 }
            if !passive { resetsIdle = true }
        }
        while true {
            guard let (kind, payload) = try? await connection.receive() else { return (usesVM, resetsIdle) }
            guard kind == .json, let request = try? FrameConnection.decoder.decode(DaemonRequest.self, from: payload) else {
                try? connection.send(DaemonFailure(id: 0, error: DMXError("bad_request", "expected a JSON request frame")))
                return (usesVM, resetsIdle)
            }
            do {
                switch request.method {
                case "hello":
                    try connection.send(DaemonReply(id: request.id, result: DaemonHello(version: version, protocol: daemonProtocol, pid: getpid(), activityNotifications: true, menuControl: true)))
                case "status":
                    try connection.send(DaemonReply(id: request.id, result: await status()))
                case "start":
                    claimVM()
                    _ = try await running()
                    try connection.send(DaemonReply(id: request.id, result: await status()))
                case "stop":
                    docker.used = false  // a daemon the CLI started may exit again
                    await stopVM(reason: "stop requested")
                    try connection.send(DaemonReply(id: request.id, result: await status()))
                case "port_add", "port_rm", "port_ls":
                    try ports.serve(request.method, id: request.id, payload: payload, on: connection)
                case "quit":
                    try connection.send(DaemonReply(id: request.id, result: NoParams()))
                    Task { await shutdown() }
                case "menu_release":
                    // Compatibility with the unreleased first menu app. Observation never
                    // clears the keepalive established by an independent Docker CLI client.
                    let released = state == .stopped
                    try connection.send(DaemonReply(id: request.id, result: released))
                case "menu_state":
                    try connection.send(DaemonReply(id: request.id, result: MenuDaemonState(pid: getpid(), state: state.rawValue)))
                case "menu_docker", "menu_docker_read":
                    guard state == .running, let agent else {
                        throw DMXError("menu_engine_not_running", "the engine is \(state.rawValue)", hint: "reopen dmx.app to start the engine")
                    }
                    claimVM(passive: request.method == "menu_docker_read")
                    try connection.send(DaemonReply(id: request.id, result: NoParams()))
                    await docker.forwardMenu(connection.fd, agent: agent)
                    return (usesVM, resetsIdle)
                case "exec":
                    let params: ExecRequest
                    do {
                        params = try FrameConnection.decoder.decode(DaemonParams<ExecRequest>.self, from: payload).params
                    } catch {
                        throw DMXError("bad_request", "exec: \(error)")
                    }
                    claimVM()
                    try await exec(params, id: request.id, client: connection)
                    return (usesVM, resetsIdle)
                case "simulate_pressure":
                    struct Params: Decodable { let level: MemoryController.Pressure? }
                    guard let params = try? FrameConnection.decoder.decode(DaemonParams<Params>.self, from: payload).params else {
                        throw DMXError("bad_request", "simulate_pressure: level must be normal, warning, critical or null")
                    }
                    memory.simulate(params.level)
                    try connection.send(DaemonReply(id: request.id, result: await status()))
                default:
                    throw DMXError("unknown_method", "the daemon has no method \"\(request.method)\"", hint: "update the daemon: `dmx stop`, then retry")
                }
            } catch {
                let failure = error as? DMXError ?? DMXError("internal", "\(request.method): \(error)")
                try? connection.send(DaemonFailure(id: request.id, error: failure))
            }
        }
    }

    /// Starts a process in the guest, then relays bytes between the client and the agent: both
    /// speak the same framing, so the daemon never parses the process's streams.
    private func exec(_ request: ExecRequest, id: UInt64, client: FrameConnection) async throws {
        let agent = try await running()
        // The guest clock stands still while the Mac sleeps; catch it up before running anything.
        if ContinuousClock.now - lastTimeSync > .seconds(30) {
            _ = try? await agent.syncTime()
            lastTimeSync = .now
        }
        let session = try await agent.exec(request)
        defer { session.connection.close() }
        try client.send(DaemonReply(id: id, result: ExecStarted(pid: session.pid)))
        execs += 1
        memory.noteActivity()
        defer { execs -= 1; memory.noteActivity() }
        await relay(client.fd, session.connection.fd)
    }

    /// The guest's memory, or nil if the agent does not answer in time: `dmx status` answers
    /// within seconds even while a guest in trouble holds the control connection, which
    /// `AgentClient` replaces only after a minute.
    private nonisolated static func memory(of agent: AgentClient, within limit: Duration) async -> GuestMemory? {
        (try? await firstOf(within: limit) { try await agent.stats().memory }) ?? nil
    }

    private func status() async -> DaemonStatus {
        var guest: GuestMemory?
        if state == .running, let agent { guest = await Self.memory(of: agent, within: .seconds(2)) }
        let used = guest.map { Int($0.used >> 20) }
        let host = HostFootprint.read(pid: getpid())
        let others = max(clients - 1, 0)
        var idleStopIn: Int?
        if state == .running, users == 0, !docker.busy {
            let left = Duration.seconds(idleTimeout) - (ContinuousClock.now - idleSince)
            idleStopIn = max(Int(left.components.seconds), 0)
        }
        return DaemonStatus(
            state: state.rawValue, pid: getpid(), version: version, launchd: launchd,
            uptimeS: bootedAt.map { (seconds(ContinuousClock.now - $0) * 10).rounded() / 10 },
            cpus: machine?.spec.cpus, maxMemory: machine.map { formatSize($0.spec.maxMemory) },
            guestUsedMb: used, hostFootprintMb: host?.footprintMb, hostPeakFootprintMb: host?.peakFootprintMb,
            clients: others, execs: execs, containers: docker.containers, idleTimeoutS: idleTimeout, idleStopInS: idleStopIn,
            socket: paths.controlSocket.path, consoleLog: paths.consoleLog.path,
            memory: memory.status(guest: guest), disk: DataDisk.usage(paths.dataDisk), dockerSocket: paths.dockerSocket.path, logWarnings: diagnosticLogs.warnings.isEmpty ? nil : diagnosticLogs.warnings)
    }

    // MARK: VM lifecycle

    private func publishActivity(reason: String? = nil, failure: DMXError? = nil) {
        activitySequence += 1
        do {
            try EngineActivity.publish(paths: paths, version: version, state: state.rawValue,
                                       containers: docker.containers, reason: reason, failure: failure, sequence: activitySequence)
        } catch { log("lifecycle receipt: \(error.localizedDescription)") }
    }

    /// The agent of the running VM, booting it first if needed.
    private func running() async throws -> AgentClient {
        while true {
            if exiting { throw DMXError("daemon_exiting", "the daemon is shutting down", hint: "retry; the next connection starts a new daemon") }
            switch state {
            case .running:
                if let agent { return agent }
            case .starting:
                if let booting { return try await booting.value }
            case .stopping:
                await stopping?.value
            case .stopped:
                boot()
            }
        }
    }

    private func boot() {
        state = .starting
        publishActivity()
        idleCheck?.cancel()
        let started = ContinuousClock.now
        booting = Task {
            defer { booting = nil }
            do {
                let config = try Config.load(paths)
                idleTimeout = config.idleTimeoutSeconds
                var spec = try config.spec
                spec.kernelArgs.append("quiet")
                spec.dataDisk = DataDisk(url: paths.dataDisk, size: try config.diskSizeBytes)
                if let disk = DataDisk.usage(paths.dataDisk), UInt64(disk.sizeMb) << 20 > (try config.diskSizeBytes) {
                    log("disk: data.img is \(disk.sizeMb) MB, more than disk_size; a disk does not shrink")
                } else if let disk = DataDisk.usage(paths.dataDisk), UInt64(disk.sizeMb) << 20 < (try config.diskSizeBytes) {
                    log("disk: growing data.img from \(disk.sizeMb) MB to disk_size")
                }
                // A missing guest, or one from an older release, is downloaded first (GuestStore).
                try await GuestStore(paths: paths).ensure(log: log)
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: paths.dockerImage.path) {
                    spec.extraDisks = [DataDisk(url: paths.dockerImage, size: 0, readOnly: true, id: "dmx-docker")]
                }
                diagnosticLogs.retryDisabled()
                diagnosticLogs.console?.append(Data("\n--- dmx VM boot \(ISO8601DateFormatter().string(from: Date())) ---\n".utf8))
                let machine = try Machine(spec: spec, paths: paths, output: .log(diagnosticLogs.console))
                self.machine = machine
                try machine.start()
                // Generous: on a loaded Mac a first boot that formats the data disk can take 30 s,
                // and giving up then would cut the format short.
                let agent = try await machine.connectAgent(timeout: .seconds(120))
                _ = try await agent.syncTime()
                lastTimeSync = .now
                self.agent = agent
                bootedAt = .now
                state = .running
                idleSince = .now
                log("VM up in \(milliseconds(ContinuousClock.now - started)) ms (\(spec.cpus) cpus, \(formatSize(machine.spec.maxMemory)) max)")
                watch(machine)
                memory.attach(machine: machine, agent: agent)
                scheduleIdleCheck()
                docker.vmBooted()
                publishActivity()
                return agent
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                log("boot failed: \((error as? DMXError)?.message ?? "\(error)")")
                if let machine {
                    await machine.stop()
                    _ = await machine.waitUntilStopped()
                }
                agent?.close()
                agent = nil
                machine = nil
                state = .stopped
                quietSince = .now
                scheduleIdleCheck()
                if cancelled {
                    publishActivity(reason: "start_cancelled")
                    throw DMXError("start_cancelled", "VM startup was cancelled before it booted", hint: "run `dmx start` when needed")
                }
                publishActivity(reason: "boot_failed", failure: error as? DMXError ?? DMXError("boot_failed", "\(error)", hint: "run `dmx doctor`"))
                throw error
            }
        }
    }

    /// Notices a VM that stopped by itself (guest poweroff or a VMM error).
    private func watch(_ machine: Machine) {
        Task {
            let exit = await machine.waitUntilStopped()
            guard self.machine === machine, state == .running else { return }
            if case .failed(let error) = exit { log("VM failed: \(error.message)") } else { log("VM stopped by the guest") }
            memory.detach()
            docker.vmStopped()
            agent?.close()
            agent = nil
            self.machine = nil
            bootedAt = nil
            state = .stopped
            quietSince = .now
            scheduleIdleCheck()
            let failure: DMXError
            if case .failed(let error) = exit { failure = error }
            else { failure = DMXError("guest_stopped", "the guest powered off unexpectedly", hint: "run `dmx doctor`, then start dmx again") }
            publishActivity(reason: "guest_stopped", failure: failure)
        }
    }

    private func stopVM(reason: String) async {
        while true {
            switch state {
            case .stopped:
                return
            case .stopping:
                await stopping?.value
            case .starting:
                // Downloads are cancellable. Once a VM exists, allow its first disk format
                // to finish before poweroff rather than leaving a half-formatted data disk.
                if machine == nil { booting?.cancel() }
                _ = try? await booting?.value
            case .running:
                log("stopping the VM: \(reason)")
                state = .stopping
                publishActivity(reason: reason)
                let task = Task { await powerOff() }
                stopping = task
                await task.value
            }
        }
    }

    /// Asks the guest to power off through the agent, and pulls the plug after 10 s.
    private func powerOff() async {
        defer { stopping = nil }
        guard let machine else { state = .stopped; return }
        memory.detach()
        docker.vmStopped()
        let started = ContinuousClock.now
        let deadline = Task {
            try await Task.sleep(for: .seconds(10))
            log("guest did not power off within 10 s, stopping it")
            await machine.stop()
        }
        // Returns at once normally; if the guest hangs, machine.stop() ends the call.
        try? await agent?.shutdown()
        _ = await machine.waitUntilStopped()
        deadline.cancel()
        agent?.close()
        agent = nil
        self.machine = nil
        bootedAt = nil
        state = .stopped
        quietSince = .now
        log("VM stopped in \(milliseconds(ContinuousClock.now - started)) ms")
        scheduleIdleCheck()
        publishActivity(reason: "stopped")
    }

    // MARK: Idle

    /// Arms one timer for whatever comes next when nothing happens: the VM stopping for being
    /// idle, or the daemon exiting once the VM is stopped and nobody is connected.
    private func scheduleIdleCheck() {
        idleCheck?.cancel()
        idleCheck = nil
        guard !exiting else { return }
        let deadline: ContinuousClock.Instant
        switch state {
        case .running where users == 0 && !docker.busy:
            deadline = idleSince + .seconds(idleTimeout)
        case .stopped where clients == 0 && ports.isEmpty && !docker.keepsDaemon:
            deadline = quietSince + Self.linger
        default:
            return
        }
        idleCheck = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            switch state {
            case .running where users == 0 && !docker.busy:
                await stopVM(reason: "idle for \(formatDuration(idleTimeout))")
            case .stopped where clients == 0 && ports.isEmpty && !docker.keepsDaemon:
                await shutdown()
            default:
                break
            }
        }
    }

    /// Stops accepting, powers the VM off and ends `run()`. Connections still queued on the
    /// socket stay there for launchd or the CLI to hand to the next daemon.
    private func shutdown() async {
        guard !exiting else { return }
        exiting = true
        accepting?.cancel()
        accepting = nil
        idleCheck?.cancel()
        ports.stop()
        docker.stop()
        await stopVM(reason: "daemon exiting")
        if !launchd {
            unlink(paths.controlSocket.path)
            Darwin.close(listener)
        }
        finished?.resume()
        finished = nil
    }

    // MARK: Setup

    /// One daemon per DMX_HOME: the lock is held until the process exits.
    private static func takeLock(_ paths: Paths) throws {
        let path = paths.home.appendingPathComponent("daemon.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DMXError("daemon_error", "cannot open \(path): \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw DMXError("daemon_running", "another dmx daemon is running for \(paths.home.path)", hint: "run `dmx status`")
        }
    }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    Diagnostics.write(Data("\(stamp) dmx-daemon: \(message)\n".utf8))
}

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

/// `read` for a blocking socket, waiting in `poll` first. macOS can lose the wakeup of a read
/// sleeping on a Unix socket when the peer shuts its sending side down (`shutdown(SHUT_WR)`):
/// the socket is at end of stream, a new read returns 0 at once, but the sleeping one never
/// returns. A socketpair with one thread reading and another writing and then shutting down
/// hung within 5,000 to 80,000 rounds (macOS 26.6); waiting in `poll` or kqueue held for 4 million.
/// The vsock streams are socketpairs that see such half closes whenever the guest's side ends
/// first (dockerd answering an HTTP/1.0 request), and docker.sock clients see them from the
/// daemon, so every blocking read of a socket goes through here. Reported to Apple as FB25307646.
func readSocket(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while poll(&ready, 1, -1) < 0 && errno == EINTR {}
    // Readable, at end of stream, or failed: the read says which.
    return read(fd, buffer, count)
}

/// Copies bytes both ways between two connected sockets until either side is done, then shuts
/// both down so the other direction ends too. A direction that ends because its destination
/// stopped taking bytes shuts nothing down: what that side sent before going away (an exec's last
/// output and its `exit`) may still be unread, and shutting down its read side would discard it.
/// The other direction ends at its end of stream.
func relay(_ a: Int32, _ b: Int32) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        let group = DispatchGroup()
        for (from, to) in [(a, b), (b, a)] {
            group.enter()
            Thread.detachNewThread {
                if pump(from: from, to: to) {
                    shutdown(a, SHUT_RDWR)
                    shutdown(b, SHUT_RDWR)
                }
                group.leave()
            }
        }
        group.notify(queue: .global()) { done.resume() }
    }
}

/// Returns false when writing to `to` failed, true when `from` ended.
private func pump(from: Int32, to: Int32) -> Bool {
    let size = 128 << 10
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    defer { buffer.deallocate() }
    while true {
        let n = readSocket(from, buffer, size)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return true }
        var offset = 0
        while offset < n {
            let w = write(to, buffer + offset, n - offset)
            if w < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += w
        }
    }
}

/// The socket launchd opened for us (`Sockets.<name>` in the plist), or nil when launchd did
/// not start this process or the plist has no such socket (an install from an older dmx).
/// `launch_activate_socket` is not in Swift's Darwin module.
func launchdSocket(_ name: String = "Listeners") throws -> Int32? {
    typealias Activate = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>, UnsafeMutablePointer<Int>) -> Int32
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "launch_activate_socket") else { return nil }
    let activate = unsafeBitCast(symbol, to: Activate.self)
    var fds: UnsafeMutablePointer<Int32>?
    var count = 0
    let result = activate(name, &fds, &count)
    if result == ESRCH || result == ENOENT { return nil }
    guard result == 0, let fds, count > 0 else {
        throw DMXError("daemon_error", "launch_activate_socket: \(String(cString: strerror(result)))", hint: "run `dmx install` again")
    }
    defer { free(fds) }
    return fds[0]
}

/// Binds and listens on a Unix socket only this user can reach.
func listenUnix(_ url: URL) throws -> Int32 {
    var address = try unixAddress(url)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DMXError("daemon_error", "socket: \(String(cString: strerror(errno)))") }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    unlink(url.path)
    let old = umask(0o077)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    umask(old)
    guard bound == 0, listen(fd, 64) == 0 else {
        let message = String(cString: strerror(errno))
        Darwin.close(fd)
        throw DMXError("daemon_error", "cannot listen on \(url.path): \(message)")
    }
    return fd
}

func unixAddress(_ url: URL) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(url.path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.count < capacity else {
        throw DMXError("socket_path_too_long", "\(url.path) is longer than a Unix socket path may be (\(capacity - 1) bytes)", hint: "use a shorter DMX_HOME")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buf in
        buf.copyBytes(from: path)
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}
