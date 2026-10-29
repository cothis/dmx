import Foundation

/// Commands for the native menu app, sharing the existing daemon and Docker API. Observation
/// is deliberately separate: clients opened here are short lived and are always closed.
public struct MenuEngine: Sendable {
    public let paths: Paths
    public let executable: String
    private let environment: [String: String]
    /// Menu HTTP travels over a control-socket tunnel that refuses to boot a stopped VM.
    /// It never sets the independent Docker CLI socket's standalone keepalive.
    private func docker(readOnly: Bool = false) -> DockerAPI {
        DockerAPI {
            guard let client = try await DaemonClient.connect(paths: paths, start: false, requestTimeout: .seconds(30)) else {
                throw DMXError("daemon_unreachable", "the dmx engine is not running", hint: "reopen dmx.app")
            }
            return try await client.menuDocker(readOnly: readOnly)
        }
    }

    public init(paths: Paths = Paths(), executable: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths; self.executable = executable
        self.environment = environment
    }

    public struct Launch: Sendable {
        public let status: DaemonStatus
        public let setupFailure: DMXError?
    }

    public func start(connected: @Sendable (Int32) async -> Void = { _ in },
                      booted: @Sendable (DaemonStatus) async -> Void = { _ in }) async throws -> Launch {
        guard let client = try await DaemonClient.connect(paths: paths, start: true, executable: executable, requestTimeout: .seconds(30)) else {
            throw DMXError("daemon_unreachable", "the daemon did not start", hint: "run `dmx doctor`")
        }
        defer { client.close() }
        guard client.hello.activityNotifications == true, client.hello.menuControl == true else {
            throw DMXError("menu_daemon_old", "the running daemon predates the menu app",
                           hint: "when your containers can stop, run `dmx stop`, then reopen dmx.app with the updated CLI installed")
        }
        await connected(client.hello.pid)
        // Keep the start lease until setup completes, so a first download cannot race idle stop.
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let started = try await client.startForMenu()
            await booted(started)
            try Task.checkCancellation()
            do {
                let configDir = DockerContext.configDir(environment: environment)
                _ = try DockerContext.install(socket: paths.dockerSocket, configDir: configDir)
                _ = try await DockerTools.install(paths: paths, configDir: configDir, environment: environment)
                try Task.checkCancellation()
                return Launch(status: try await client.status(), setupFailure: nil)
            } catch {
                try Task.checkCancellation()
                return Launch(status: started, setupFailure: error as? DMXError ?? DMXError("menu_setup_failed", error.localizedDescription, hint: "run `dmx tools install`, then Retry in dmx.app"))
            }
        } onCancel: { client.close() }
    }

    public func status() async throws -> DaemonStatus? {
        guard let client = try await DaemonClient.connect(paths: paths, start: false, requestTimeout: .seconds(30)) else { return nil }
        defer { client.close() }
        return try await client.status()
    }

    /// Explicit app quit powers off the VM, then exits the daemon even when a standalone
    /// Docker socket or saved port forward would otherwise keep it resident.
    public func stop() async throws {
        guard let client = try await DaemonClient.connect(paths: paths, start: false, requestTimeout: .seconds(30)) else { return }
        defer { client.close() }
        let pid = client.hello.pid
        _ = try await client.stop(timeout: .seconds(150))
        try await client.quit()
        client.close()
        // quit acknowledges before the daemon exits. Wait only during this explicit action,
        // and reap a helper we spawned so a long-lived app never retains a zombie child.
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(pid, 0) == 0 {
            DaemonChildren.shared.reapIfExited(pid)
            guard ContinuousClock.now < deadline else {
                throw DMXError("menu_stop_timeout", "the VM stopped but its daemon has not exited",
                               hint: "run `dmx status`, then `dmx stop` before reopening dmx.app")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    public func releaseAfterIdle(pid: Int32) async throws -> Bool {
        let state = try await stateAfterIdle(pid: pid)
        return state == nil || state?.state == "stopped"
    }

    public func stateAfterIdle(pid: Int32) async throws -> MenuDaemonState? {
        guard kill(pid, 0) == 0 else { return nil }
        guard let client = try await DaemonClient.connect(paths: paths, start: false, requestTimeout: .seconds(30)) else { return nil }
        defer { client.close() }
        guard client.hello.pid == pid else { return nil }
        return try await client.menuState()
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
        let (status, body) = try await docker(readOnly: true).call("GET", "/containers/json?all=1")
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
        try await setState(action, id: container.id)
        // A paused container has to be unpaused before it can stop gracefully.
        if !running, container.state == "paused" {
            try await setState("stop?t=10", id: container.id)
        }
    }

    private func setState(_ action: String, id: String) async throws {
        let (status, body) = try await docker().call("POST", "/containers/\(id)/\(action)")
        guard status == 204 || status == 304 else {
            let message = (try? JSONDecoder().decode(JSONValue.self, from: body))?["message"]?.string
            throw DMXError("docker_failed", message ?? "container action failed (HTTP \(status))", hint: "run `docker ps -a`, then retry")
        }
    }
}
