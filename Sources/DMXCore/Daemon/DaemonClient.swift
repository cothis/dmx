import Foundation

/// Talks to the dmx daemon over its control socket. Like `AgentClient`, control calls share one
/// connection and each exec opens its own.
public final class DaemonClient: Sendable {
    private let paths: Paths
    let control: FrameConnection
    public let hello: DaemonHello

    private init(paths: Paths, control: FrameConnection, hello: DaemonHello) {
        self.paths = paths
        self.control = control
        self.hello = hello
    }

    /// Connects to the daemon. With `start`, a missing daemon is started in the background
    /// (launchd starts it by itself after `dmx install`); without, nil means none is running.
    public static func connect(paths: Paths, start: Bool) async throws -> DaemonClient? {
        let deadline = ContinuousClock.now + .seconds(15)
        var spawned = false
        var lastError: DMXError?
        while ContinuousClock.now < deadline {
            do {
                let connection = try open(paths)
                // A daemon that is exiting closes connections it had not accepted yet; retry those.
                let hello: DaemonHello = try await connection.call("hello", NoParams())
                guard hello.protocol == daemonProtocol else {
                    throw DMXError("daemon_version", "the daemon speaks protocol \(hello.protocol), this dmx speaks \(daemonProtocol)", hint: "the daemon (pid \(hello.pid)) is from another dmx; run `kill \(hello.pid)`, then retry")
                }
                return DaemonClient(paths: paths, control: connection, hello: hello)
            } catch let error as DMXError where error.code == "daemon_unreachable" {
                guard start else { return nil }
                if !spawned {
                    try spawnDaemon(paths)
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

    public func close() { control.close() }

    public func status() async throws -> DaemonStatus { try await control.call("status", NoParams()) }
    /// Boots the VM if it is not running and returns once the guest agent answers.
    public func start() async throws -> DaemonStatus { try await control.call("start", NoParams()) }
    /// Powers the VM off. The daemon exits shortly after unless a client connects.
    public func stop() async throws -> DaemonStatus { try await control.call("stop", NoParams()) }
    /// Powers the VM off and ends the daemon now.
    public func quit() async throws { let _: NoParams = try await control.call("quit", NoParams()) }

    /// Starts a process in the guest, booting the VM first if needed.
    public func exec(_ request: ExecRequest) async throws -> ExecSession {
        try await Self.open(paths).exec(request)
    }

    private static func open(_ paths: Paths) throws -> FrameConnection {
        var address = try unixAddress(paths.controlSocket)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DMXError("daemon_error", "socket: \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
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
private func spawnDaemon(_ paths: Paths) throws {
    try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
    let executable = try currentExecutable()
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, paths.daemonLog.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
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
    let result = posix_spawn(&pid, executable, &actions, &attributes, &cArgs, environ)
    guard result == 0 else {
        throw DMXError("daemon_error", "cannot start \(executable) daemon: \(String(cString: strerror(result)))")
    }
}

/// The absolute path of the running dmx binary.
func currentExecutable() throws -> String {
    guard let url = Bundle.main.executableURL else {
        throw DMXError("daemon_error", "cannot find the dmx executable")
    }
    return url.resolvingSymlinksInPath().path
}
