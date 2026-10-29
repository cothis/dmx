import Foundation
import Testing
@testable import DMXCore

/// Opt-in real-VM suite, run by make menutest in its own process. Never touches the user's
/// daemon, data disk or Docker context; only pinned guest/tool binaries are shared read-only.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DMX_MENU_VM"] == "1"))
struct MenuEngineVMTests {
    @Test func containerActionsAndShutdown() async throws {
        let fm = FileManager.default
        // macOS's per-user temporary directory plus a UUID exceeds sockaddr_un's 103 bytes.
        let home = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("dmx-mvm-\(UUID())")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let source = Paths()
        for name in ["guest", "bin", "cli-plugins"] {
            try fm.createSymbolicLink(at: home.appendingPathComponent(name), withDestinationURL: source.home.appendingPathComponent(name))
        }
        try Data(#"{"cpus":2,"memory":"2G","shares":[],"idle_timeout":30}"#.utf8)
            .write(to: home.appendingPathComponent("config.json"))
        let paths = Paths(environment: ["DMX_HOME": home.path])
        let helper = try #require(ProcessInfo.processInfo.environment["DMX_MENU_EXECUTABLE"])
        let engine = MenuEngine(paths: paths, executable: helper,
                                environment: ["DOCKER_CONFIG": home.appendingPathComponent("docker-config").path, "PATH": "/usr/bin:/bin"])
        do {
            let started = try await engine.start()
            let pid = try #require(started.pid)
            #expect(started.state == "running")
            #expect(EngineActivity.read(paths: paths)?.pid == pid)
            #expect(try await engine.containers().isEmpty)
            let api = DockerAPI.host(paths)
            // Workload images are test fixtures, not guest build inputs. A minimal BusyBox
            // container exercises the exact typed methods used by the menu's Start/Stop.
            _ = try await api.json("POST", "/images/create?fromImage=busybox&tag=1.37")
            _ = try await api.json("POST", "/containers/create?name=dmx-menu-probe", body: .object([
                "Image": .string("busybox:1.37"), "Cmd": .array([.string("sleep"), .string("600")])
            ]))
            let created = try #require(try await engine.containers().first)
            #expect(created.name == "dmx-menu-probe")
            #expect(!created.running)
            try await engine.setRunning(true, container: created)
            let running = try #require(try await engine.containers().first)
            #expect(running.running)
            try await engine.setRunning(false, container: running)
            let stopped = try #require(try await engine.containers().first)
            #expect(!stopped.running)
            try await engine.stop()
            let deadline = ContinuousClock.now + .seconds(5)
            while kill(pid, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            let stillPresent = kill(pid, 0) == 0
            if stillPresent {
                let ps = Process()
                ps.executableURL = URL(fileURLWithPath: "/bin/ps")
                ps.arguments = ["-o", "pid,ppid,state,rss,command", "-p", String(pid)]
                try ps.run(); ps.waitUntilExit()
                let reaped = waitpid(pid, nil, WNOHANG)
                print("menu shutdown diagnostic: waitpid returned \(reaped), expected child \(pid)")
            }
            #expect(!stillPresent)
        } catch {
            try? await engine.stop()
            throw error
        }
    }
}
