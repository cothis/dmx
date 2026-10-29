import Foundation
import MachO
import Synchronization

/// Talks to the dmx daemon over its control socket. Like `AgentClient`, control calls share one
/// connection and each exec opens its own.
public final class DaemonClient: Sendable {
    private let paths: Paths
    let control: FrameConnection
    public let hello: DaemonHello
    private let requestTimeout: Duration?

    private init(paths: Paths, control: FrameConnection, hello: DaemonHello, requestTimeout: Duration?) {
        self.paths = paths
        self.control = control
        self.hello = hello
        self.requestTimeout = requestTimeout
    }

    /// Connects to the daemon. With `start`, a missing daemon is started in the background
    /// (launchd starts it by itself after `dmx install`); without, nil means none is running.
    public static func connect(paths: Paths, start: Bool, executable: String? = nil,
                               requestTimeout: Duration? = nil) async throws -> DaemonClient? {
        let deadline = ContinuousClock.now + .seconds(15)
        var spawned = false
        var lastError: DMXError?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            do {
                let connection = try open(paths)
                // A daemon that is exiting closes connections it had not accepted yet; retry those.
                let hello: DaemonHello = try await withConnectionDeadline(min(requestTimeout ?? .seconds(15), .seconds(15)), connection: connection) {
                    try await connection.call("hello", NoParams())
                }
                guard hello.protocol == daemonProtocol else {
                    throw DMXError("daemon_version", "the daemon speaks protocol \(hello.protocol), this dmx speaks \(daemonProtocol)", hint: "the daemon (pid \(hello.pid)) is from another dmx; run `kill \(hello.pid)`, then retry")
                }
                noticeOldDaemon(hello)
                return DaemonClient(paths: paths, control: connection, hello: hello, requestTimeout: requestTimeout)
            } catch let error as DMXError where error.code == "daemon_unreachable" {
                guard start else { return nil }
                if !spawned {
                    try spawnDaemon(paths, executable: executable)
                    spawned = true
                }
                lastError = error
            } catch let error as DMXError where error.code == "daemon_disconnected" {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw DMXError("daemon_unreachable", "no answer from the dmx daemon on \(paths.controlSocket.path)" + (lastError.map { ": \($0.message)" } ?? ""),
                       hint: "see \(paths.daemonLog.path), or run `dmx daemon` in a terminal to watch it")
    }

    /// After `dmx update` the old daemon keeps serving until it exits, so a command can run
    /// against a version the user no longer has installed. Say so once per process, on stderr so
    /// `--json` output stays machine-readable; it is a notice, not an error, because the daemon
    /// speaks the same protocol and the VM and its containers are fine where they are.
    private static let noticed = Atomic<Bool>(false)
    private static func noticeOldDaemon(_ hello: DaemonHello) {
        guard hello.version != dmxVersion, !noticed.exchange(true, ordering: .relaxed) else { return }
        FileHandle.standardError.write(Data("""
            dmx: the daemon answering is \(hello.version) (pid \(hello.pid)), this dmx is \(dmxVersion)
            dmx: `dmx stop` powers the VM off and the daemon exits; the next command runs \(dmxVersion)\n
            """.utf8))
    }

    public func close() { control.close() }

    private func call<R: Decodable & Sendable>(_ method: String, timeout: Duration? = nil) async throws -> R {
        try await withConnectionDeadline(timeout ?? requestTimeout, connection: control) {
            try await self.control.call(method, NoParams())
        }
    }

    public func status() async throws -> DaemonStatus { try await call("status") }
    /// Boots the VM if it is not running and returns once the guest agent answers.
    public func start(timeout: Duration? = nil) async throws -> DaemonStatus { try await call("start", timeout: timeout) }
    /// First boot includes a potentially slow guest download. Quit cancels this owned
    /// connection; a shorter client timer must not orphan a legitimate daemon boot.
    func startForMenu() async throws -> DaemonStatus {
        try await withConnectionDeadline(nil, connection: control) { try await self.control.call("start", NoParams()) }
    }
    /// Powers the VM off. The daemon exits shortly after unless a client connects.
    public func stop(timeout: Duration? = nil) async throws -> DaemonStatus { try await call("stop", timeout: timeout) }
    /// Powers the VM off and ends the daemon now.
    public func quit() async throws { let _: NoParams = try await call("quit") }
    public func releaseMenuSession() async throws -> Bool { try await call("menu_release") }
    public func menuState() async throws -> MenuDaemonState { try await call("menu_state") }

    func menuDocker(readOnly: Bool = false) async throws -> DockerStream {
        do {
            let _: NoParams = try await call(readOnly ? "menu_docker_read" : "menu_docker")
            let connection = control
            return DockerStream(fd: connection.fd, timeoutSeconds: 30) { connection.close() }
        } catch { control.close(); throw error }
    }

    /// Starts a process in the guest, booting the VM first if needed.
    public func exec(_ request: ExecRequest) async throws -> ExecSession {
        try await Self.open(paths).exec(request)
    }

    private static func open(_ paths: Paths) throws -> FrameConnection {
        var address = try unixAddress(paths.controlSocket)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DMXError("daemon_error", "socket: \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result < 0, errno == EINPROGRESS {
            let deadline = ContinuousClock.now + .seconds(15)
            while true {
                var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let remaining = max(seconds(deadline - .now), 0)
                let readyCount = poll(&ready, 1, Int32(min(remaining * 1000 + 1, 15_000)))
                if readyCount < 0, errno == EINTR, ContinuousClock.now < deadline { continue }
                if readyCount > 0 {
                    var code: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    if getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &length) == 0, code == 0 { result = 0 }
                    else { errno = code == 0 ? ECONNREFUSED : code }
                } else if readyCount == 0 { errno = ETIMEDOUT }
                break
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw DMXError("daemon_unreachable", "connect \(paths.controlSocket.path): \(String(cString: strerror(code)))")
        }
        return FrameConnection(fd: fd, peer: .daemon) { _ = Darwin.close(fd) }
    }
}

/// Starts `dmx daemon` detached from this process, logging to `~/.dmx/logs/daemon.log`.
/// Two clients may both start one; the second finds the lock taken and exits.
private func spawnDaemon(_ paths: Paths, executable: String?) throws {
    try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
    let executable = try executable ?? currentExecutable()
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Its own session, so the terminal's signals (Ctrl-C) and hangup do not reach it.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    let argv = [executable, "daemon"]
    var cArgs = argv.map { strdup($0) } + [nil]
    defer { for p in cArgs { free(p) } }
    var pid: pid_t = 0
    // App/test clients can supply Paths explicitly; the helper must use that same home.
    var environment = ProcessInfo.processInfo.environment
    environment["DMX_HOME"] = paths.home.path
    var cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { for p in cEnv { free(p) } }
    let result = posix_spawn(&pid, executable, &actions, &attributes, &cArgs, &cEnv)
    guard result == 0 else {
        throw DMXError("daemon_error", "cannot start \(executable) daemon: \(String(cString: strerror(result)))")
    }
    DaemonChildren.shared.register(pid)
}

/// The absolute path of the running dmx binary.
func currentExecutable() throws -> String {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var path = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&path, &size) == 0 else {
        throw DMXError("daemon_error", "cannot find the dmx executable")
    }
    // Bundle.main can name dmx-menu when this helper lives inside dmx.app.
    return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
}
