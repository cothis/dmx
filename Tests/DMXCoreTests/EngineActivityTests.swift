import Foundation
import Testing
import Synchronization
@testable import DMXCore

@Suite("Passive menu observation")
struct EngineActivityTests {
    @Test func connectedPeerCannotHoldMenuReadForever() async throws {
        let home = URL(fileURLWithPath: "/tmp").appendingPathComponent("dmx-stall-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = Paths(environment: ["DMX_HOME": home.path])
        let listener = try listenUnix(paths.dockerSocket)
        let release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let serverClosed = Mutex(false)
        var joined = false
        Thread.detachNewThread {
            var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            if poll(&ready, 1, 3_000) > 0 {
                let peer = accept(listener, nil, nil)
                if peer >= 0 {
                    // Keep the socket open and send nothing. A ten-second hard cleanup
                    // ceiling cannot make the one-second deadline assertions pass.
                    _ = release.wait(timeout: .now() + .seconds(10))
                    serverClosed.withLock { $0 = true }
                    Darwin.close(peer)
                }
            }
            finished.signal()
        }
        defer {
            release.signal()
            if joined {
                Darwin.close(listener)
                try? FileManager.default.removeItem(at: home)
            }
        }
        let started = ContinuousClock.now
        do {
            _ = try await DockerAPI.host(paths, startDaemon: false, timeoutSeconds: 1).call("GET", "/containers/json")
            Issue.record("a silent connected peer must time out")
        } catch let error as DMXError {
            #expect(error.code == "docker_timeout")
        } catch {
            Issue.record(error)
        }
        // Assert before teardown closes the peer: the deadline must supply its own wakeup.
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(!serverClosed.withLock { $0 })
        release.signal()
        joined = try await onThread { finished.wait(timeout: .now() + .seconds(12)) == .success }
        #expect(joined)
    }

    @Test func menuReadDoesNotSpawnAFallbackExecutable() async throws {
        let home = URL(fileURLWithPath: "/tmp").appendingPathComponent("dmx-no-spawn-\(UUID())")
        let engine = MenuEngine(paths: Paths(environment: ["DMX_HOME": home.path]), executable: "/not-a-dmx-helper")
        do {
            _ = try await engine.containers()
            Issue.record("a missing engine must fail without starting a helper")
        } catch let error as DMXError {
            #expect(error.code == "daemon_unreachable")
        }
        #expect(!FileManager.default.fileExists(atPath: home.path))
    }

    @Test @MainActor func observesAbruptProcessExitWithoutAReceipt() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dmx-exit-\(UUID())")
        let paths = Paths(environment: ["DMX_HOME": home.path])
        defer { try? FileManager.default.removeItem(at: home) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        var exited: Int32?
        let observer = try EngineActivityObserver(paths: paths, changed: { _ in }, exited: { exited = $0 })
        defer { observer.close() }
        observer.watch(pid: child.processIdentifier)
        child.terminate()
        let deadline = ContinuousClock.now + .seconds(2)
        while exited == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(exited == child.processIdentifier)
        #expect(EngineActivity.read(paths: paths) == nil)
    }

    @Test @MainActor func observesAtomicReplacementWithoutAControlSocket() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dmx-observe-\(UUID())")
        let paths = Paths(environment: ["DMX_HOME": home.path])
        defer { try? FileManager.default.removeItem(at: home) }
        var observed: [EngineActivity] = []
        let observer = try EngineActivityObserver(paths: paths, changed: { observed.append($0) }, exited: { _ in })
        defer { observer.close() }
        try EngineActivity.publish(paths: paths, version: "test", state: "running", containers: 2)
        let deadline = ContinuousClock.now + .seconds(2)
        while observed.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(observed.last?.state == "running")
        #expect(observed.last?.containers == 2)
        try EngineActivity.publish(paths: paths, version: "test", state: "stopped", containers: nil,
                                   failure: DMXError("test_failure", "failed", hint: "run `dmx doctor`"))
        while observed.last?.state != "stopped", ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(observed.last?.failure?.code == "test_failure")
        #expect(!FileManager.default.fileExists(atPath: paths.controlSocket.path))
    }

    @Test func bundledCLIRefusesEvenAForcedPartialUpdate() throws {
        let updater = SelfUpdate(current: "0.3.12", executable: URL(fileURLWithPath: "/Applications/dmx.app/Contents/MacOS/dmx"))
        #expect(throws: (any Error).self) { try updater.checkDestination(force: true) }
        do { try updater.checkDestination(force: true) }
        catch let error as DMXError { #expect(error.code == "update_app_bundle") }
    }
}
