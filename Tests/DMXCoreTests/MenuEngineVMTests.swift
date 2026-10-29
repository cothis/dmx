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
            let dockerConfig = home.appendingPathComponent("docker-config/config.json")
            try fm.createDirectory(at: dockerConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("[]".utf8).write(to: dockerConfig)
            let setupFailed = try await engine.start()
            #expect(setupFailed.status.state == "running")
            #expect(setupFailed.setupFailure?.code == "docker_context_failed")
            try Data("{}".utf8).write(to: dockerConfig)
            let launch = try await engine.start()
            #expect(launch.setupFailure == nil)
            let started = launch.status
            #expect(started.pid == setupFailed.status.pid)
            let pid = try #require(started.pid)
            #expect(started.state == "running")
            #expect(EngineActivity.read(paths: paths)?.pid == pid)
            try await Task.sleep(for: .seconds(2))
            let idleBeforeRead = try #require(try await engine.status()?.idleStopInS)
            #expect(try await engine.containers().isEmpty)
            let idleAfterRead = try #require(try await engine.status()?.idleStopInS)
            #expect(idleBeforeRead < 30 && idleAfterRead <= idleBeforeRead)
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
            try await engine.setRunning(true, container: created) // stale menu: Docker 304
            let running = try #require(try await engine.containers().first)
            #expect(running.running)
            try await engine.setRunning(false, container: running)
            try await engine.setRunning(false, container: running) // already stopped: 304
            let stopped = try #require(try await engine.containers().first)
            #expect(!stopped.running)
            // The menu's new tunnel must retain the normal host port collision check.
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            try #require(listener >= 0)
            defer { Darwin.close(listener) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            try #require(bound == 0)
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) } }
            try #require(named == 0)
            let port = String(UInt16(bigEndian: address.sin_port))
            _ = try await api.json("POST", "/containers/create?name=dmx-menu-collision", body: .object([
                "Image": .string("busybox:1.37"), "Cmd": .array([.string("sleep"), .string("600")]),
                "HostConfig": .object(["PortBindings": .object(["80/tcp": .array([.object(["HostIp": .string("127.0.0.1"), "HostPort": .string(port)])])])])
            ]))
            let collision = try #require(try await engine.containers().first { $0.name == "dmx-menu-collision" })
            do { try await engine.setRunning(true, container: collision); Issue.record("menu started a container over an occupied host port") }
            catch let error as DMXError { #expect(error.code == "docker_failed") }
            #expect(try await engine.containers().first { $0.name == collision.name }?.running == false)
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
