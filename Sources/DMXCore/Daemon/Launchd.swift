import Foundation

/// The launchd user agent that owns the control socket and the Docker socket and starts
/// `dmx daemon` on the first connection to either, so nothing runs until a client connects.
public enum LaunchAgent {
    public static let label = "io.github.cothis.dmx"

    public static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public struct Report: Encodable, Sendable {
        public let ok = true
        public let label: String
        public let plist: String
        public let socket: String
        public let executable: String?
        /// The daemon that answered on the socket after install; nil after uninstall.
        public let daemonPid: Int32?
        /// The `docker context` install created and selected; nil after uninstall.
        public var dockerContext: DockerContext.Report? = nil
        /// `~/.docker/run/docker.sock` (Docker Desktop's path) and whether it leads to dmx; nil after uninstall.
        public var dockerSocketLink: DockerSocketLink.Report? = nil
        /// The docker CLI and plugins install put in place; nil after uninstall.
        public var dockerTools: DockerTools.Report? = nil
    }

    /// Writes the plist, loads it, and checks that a connection starts the daemon. Replaces an
    /// earlier install, and stops a daemon the CLI started, which would hold the socket. Then
    /// creates and selects the `dmx` docker context, links Docker Desktop's socket path to dmx's,
    /// and installs the docker CLI and its plugins.
    @MainActor
    public static func install(paths: Paths, progress: @Sendable (String) -> Void = { _ in }) async throws -> Report {
        let executable = try currentExecutable()
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try await quitStandaloneDaemon(paths)

        let data = try plistData(paths: paths, executable: executable)
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = runningPid()
        _ = try? launchctl(["bootout", "\(domain)/\(label)"])
        try await waitUntilGone(previous)
        try data.write(to: plist, options: .atomic)
        try await bootstrap()

        let client = try await firstConnection(paths)
        defer { client.close() }
        var report = Report(label: label, plist: plist.path, socket: paths.controlSocket.path, executable: executable, daemonPid: client.hello.pid)
        report.dockerContext = try DockerContext.install(socket: paths.dockerSocket, configDir: DockerContext.configDir())
        report.dockerSocketLink = DockerSocketLink.install(socket: paths.dockerSocket, link: DockerSocketLink.path())
        do {
            report.dockerTools = try await DockerTools.install(paths: paths, progress: progress)
        } catch let error as DMXError {
            throw DMXError(error.code, "the launchd agent and the docker context are installed, but not the docker CLI: \(error.message)", hint: error.hint)
        }
        return report
    }

    /// The pid of the job's running daemon, if launchd has one.
    private static func runningPid() -> pid_t? {
        guard let text = try? launchctl(["print", "\(domain)/\(label)"]) else { return nil }
        return text.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("pid = ") }
            .flatMap { pid_t($0.dropFirst(6)) }
    }

    /// `launchctl bootout` returns while the old daemon is still exiting, which takes a second or
    /// more when it powers a VM off. Until launchd has let go of the job, bootstrapping it again
    /// fails ("Bootstrap failed: 5: Input/output error") or loads a job whose sockets do not
    /// answer yet: on one Mac `dmx install` failed every time it ran with the VM up.
    @MainActor
    private static func waitUntilGone(_ pid: pid_t?) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            let loaded = (try? launchctl(["print", "\(domain)/\(label)"])) != nil
            let alive = pid.map { kill($0, 0) == 0 } ?? false
            if !loaded && !alive { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Loads the plist, retrying for a few seconds while launchd still answers EIO for a job it
    /// is tearing down.
    @MainActor
    private static func bootstrap() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            do {
                try launchctl(["bootstrap", domain, plist.path])
                return
            } catch let error as DMXError {
                if error.message.contains(": 5: "), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                throw DMXError("install_failed", error.message, hint: "check \(plist.path), then run `dmx install` again")
            }
        }
    }

    /// The daemon behind launchd's socket, right after bootstrap. launchd may set the socket up
    /// a moment after `launchctl bootstrap` returns (a Mac reported `install_failed` while the
    /// job was running and serving the Docker socket), so keep trying for a few seconds, and say
    /// why the last attempt failed and what launchd reports if it never answers.
    @MainActor
    private static func firstConnection(_ paths: Paths) async throws -> DaemonClient {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            if let client = try await DaemonClient.connect(paths: paths, start: false) { return client }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let state = (try? launchctl(["print", "\(domain)/\(label)"]))?
            .split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("state =") }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? "not loaded"
        throw DMXError("install_failed",
                       "launchd did not answer on \(paths.controlSocket.path) within 10 s (\(connectError(paths.controlSocket)); launchd job \(state))",
                       hint: "see \(paths.daemonLog.path) and `launchctl print \(domain)/\(label)`, then run `dmx install` again")
    }

    /// Why connecting to `path` fails right now, as strerror text, or "it accepts connections".
    private static func connectError(_ path: URL) -> String {
        guard var address = try? unixAddress(path) else { return "socket path too long" }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result == 0 ? "it accepts connections" : "connect: \(String(cString: strerror(errno)))"
    }

    /// The job launchd runs: `dmx daemon` with both sockets, started on the first connection.
    public static func plistData(paths: Paths, executable: String) throws -> Data {
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "daemon"],
            "EnvironmentVariables": ["DMX_HOME": paths.home.path],
            "Sockets": [
                "Listeners": ["SockPathName": paths.controlSocket.path, "SockPathMode": 0o600],
                // The first Docker client starts the daemon too (DockerBridge takes it by this name).
                "Docker": ["SockPathName": paths.dockerSocket.path, "SockPathMode": 0o600],
            ],
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
            // Containers are interactive work: no background CPU and I/O throttling.
            "ProcessType": "Interactive",
            // The daemon exits whenever it is idle; let the next connection start it at once.
            "ThrottleInterval": 1,
        ]
        return try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    }

    /// Unloads the agent (launchd sends SIGTERM, so a running VM powers off cleanly) and removes
    /// the plist and the socket. Succeeds when nothing was installed.
    public static func uninstall(paths: Paths) throws -> Report {
        _ = try? launchctl(["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: plist)
        if isLaunchdSocket(paths.controlSocket) { unlink(paths.controlSocket.path) }
        if isLaunchdSocket(paths.dockerSocket) { unlink(paths.dockerSocket.path) }
        try DockerContext.uninstall(configDir: DockerContext.configDir())
        DockerSocketLink.uninstall(socket: paths.dockerSocket, link: DockerSocketLink.path())
        try DockerTools.uninstall(paths: paths)
        return Report(label: label, plist: plist.path, socket: paths.controlSocket.path, executable: nil, daemonPid: nil)
    }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: plist.path) }

    private static var domain: String { "gui/\(getuid())" }

    /// After bootout the socket file stays behind; remove it only if nothing listens on it.
    private static func isLaunchdSocket(_ path: URL) -> Bool {
        guard let address = try? unixAddress(path) else { return false }
        var a = address
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        let result = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result != 0
    }

    /// A daemon the CLI started holds the socket path; ask it to power off and exit first.
    @MainActor
    private static func quitStandaloneDaemon(_ paths: Paths) async throws {
        guard let client = try await DaemonClient.connect(paths: paths, start: false) else { return }
        defer { client.close() }
        guard let status = try? await client.status(), status.launchd == false else { return }
        try await client.quit()
        let deadline = ContinuousClock.now + .seconds(15)
        while kill(client.hello.pid, 0) == 0 {
            guard ContinuousClock.now < deadline else {
                throw DMXError("install_failed", "the running daemon (pid \(client.hello.pid)) did not exit", hint: "run `kill \(client.hello.pid)`, then `dmx install`")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @discardableResult
    static func launchctl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw DMXError("launchctl_failed", "launchctl \(arguments.joined(separator: " ")): \(text.isEmpty ? "exit \(process.terminationStatus)" : text)")
        }
        return text
    }
}
