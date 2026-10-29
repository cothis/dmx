import Foundation

/// Commands for the native menu app, sharing the existing daemon and Docker API. Observation
/// is deliberately separate: clients opened here are short lived and are always closed.
public struct MenuEngine: Sendable {
    public let paths: Paths
    public let executable: String
    private let environment: [String: String]
    /// Only start() may spawn an engine for the app. Menu reads/actions never run the UI
    /// executable as a fallback daemon, and stalled requests cannot hold Quit indefinitely.
    private var docker: DockerAPI { .host(paths, executable: executable, startDaemon: false, timeoutSeconds: 30) }

    public init(paths: Paths = Paths(), executable: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths; self.executable = executable
        self.environment = environment
    }

    public func start(connected: @Sendable (Int32) async -> Void = { _ in }) async throws -> DaemonStatus {
        guard let client = try await DaemonClient.connect(paths: paths, start: true, executable: executable) else {
            throw DMXError("daemon_unreachable", "the daemon did not start", hint: "run `dmx doctor`")
        }
        defer { client.close() }
        guard client.hello.activityNotifications == true else {
            throw DMXError("menu_daemon_old", "the running daemon predates the menu app",
                           hint: "when your containers can stop, run `dmx stop`, then reopen dmx.app with the updated CLI installed")
        }
        await connected(client.hello.pid)
        // Keep the start lease until setup completes, so a first download cannot race idle stop.
        _ = try await client.start()
        let configDir = DockerContext.configDir(environment: environment)
        _ = try DockerContext.install(socket: paths.dockerSocket, configDir: configDir)
        _ = try await DockerTools.install(paths: paths, configDir: configDir, environment: environment)
        return try await client.status()
    }

    public func status() async throws -> DaemonStatus? {
        guard let client = try await DaemonClient.connect(paths: paths, start: false) else { return nil }
        defer { client.close() }
        return try await client.status()
    }

    /// Explicit app quit powers off the VM, then exits the daemon even when a standalone
    /// Docker socket or saved port forward would otherwise keep it resident.
    public func stop() async throws {
        guard let client = try await DaemonClient.connect(paths: paths, start: false) else { return }
        defer { client.close() }
        let pid = client.hello.pid
        _ = try await client.stop()
        try await client.quit()
        client.close()
        // quit acknowledges before the daemon exits. Wait only during this explicit action,
        // and reap a helper we spawned so a long-lived app never retains a zombie child.
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(pid, 0) == 0 {
            if waitpid(pid, nil, WNOHANG) == pid { return }
            guard ContinuousClock.now < deadline else {
                throw DMXError("menu_stop_timeout", "the VM stopped but its daemon has not exited",
                               hint: "run `dmx status`, then `dmx stop` before reopening dmx.app")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    public func releaseAfterIdle(pid: Int32) async throws -> Bool {
        guard kill(pid, 0) == 0 else { return true }
        guard let client = try await DaemonClient.connect(paths: paths, start: false) else { return true }
        defer { client.close() }
        guard client.hello.pid == pid else { return false }
        return try await client.releaseMenuSession()
    }

    public struct Container: Codable, Sendable {
        public let id: String
        public let names: [String]
        public let image: String
        public let state: String
        public let status: String
        public var name: String { names.first.map { String($0.drop(while: { $0 == "/" })) } ?? String(id.prefix(12)) }
        public var running: Bool { state == "running" || state == "restarting" || state == "paused" }

        enum CodingKeys: String, CodingKey {
            case id = "Id", names = "Names", image = "Image", state = "State", status = "Status"
        }
    }

    public func containers() async throws -> [Container] {
        let (status, body) = try await docker.call("GET", "/containers/json?all=1")
        guard status == 200 else { throw DMXError("docker_failed", "cannot list containers (HTTP \(status))", hint: "run `docker ps -a`") }
        return try JSONDecoder().decode([Container].self, from: body).sorted {
            if $0.running != $1.running { return $0.running }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func setRunning(_ running: Bool, container: Container) async throws {
        // IDs come from dockerd, but validate them before placing them in an API path.
        guard container.id.count == 64, container.id.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw DMXError("docker_bad_id", "dockerd returned an invalid container ID", hint: "run `docker ps -a`")
        }
        let action = running ? "start" : (container.state == "paused" ? "unpause" : "stop?t=10")
        _ = try await docker.json("POST", "/containers/\(container.id)/\(action)")
        // A paused container has to be unpaused before it can stop gracefully.
        if !running, container.state == "paused" {
            _ = try await docker.json("POST", "/containers/\(container.id)/stop?t=10")
        }
    }
}
