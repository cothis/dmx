import Darwin
import Foundation
import Testing
@testable import DMXCore

/// Runs in an entitled, isolated test process: no data disk or user daemon is opened.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DMX_MACHINE_VM"] == "1"))
struct MachineLifecycleTests {
    private let spec = MachineSpec(cpus: 2, maxMemory: 256 << 20)

    @Test func partialInitReleasesVM() throws {
        do {
            _ = try Machine(spec: spec, paths: Paths(), output: .file(.nullDevice), afterMap: {
                throw DMXError("injected", "fail after hv_vm_map")
            })
            Issue.record("injection did not throw")
        } catch let error as DMXError { #expect(error.code == "injected") }
        // hv_vm_create must succeed again in this process.
        _ = try Machine(spec: spec, paths: Paths(), output: .file(.nullDevice))
    }

    @Test func failedStartReleasesVCPUsAndVM() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dmx-invalid-\(UUID())")
        let paths = Paths(environment: ["DMX_HOME": home.path])
        try FileManager.default.createDirectory(at: paths.guest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(repeating: 0, count: 64).write(to: paths.kernel)
        try Data().write(to: paths.initramfs)
        let machine = try Machine(spec: spec, paths: paths, output: .file(.nullDevice))
        do { try machine.start(); Issue.record("invalid kernel started") }
        catch let error as DMXError { #expect(error.code == "guest_invalid") }
        // Keep the failed machine alive: cleanup must finish before start() throws.
        let next = try Machine(spec: spec, paths: Paths(), output: .file(.nullDevice))
        withExtendedLifetime((machine, next)) {}
    }

    @Test func staleReleaseCannotReplaceSuccessorRAM() async throws {
        let old = try Machine(spec: spec, paths: Paths(), output: .file(.nullDevice))
        await old.stop()
        _ = await old.waitUntilStopped()
        let next = try Machine(spec: spec, paths: Paths(), output: .file(.nullDevice))
        // Exercise the actual process-wide API path after the successor owns the HV slot.
        old.release(HVLayout.ramBase, spec.maxMemory)
        try next.start()
        let agent = try? await next.connectAgent(timeout: .seconds(3))
        agent?.close()
        await next.stop()
        _ = await next.waitUntilStopped()
        #expect(agent != nil)
        withExtendedLifetime(old) {}
    }

    @Test @MainActor func detachedTickDoesNotSetNextSwapFlag() async throws {
        let machine = try Machine(spec: spec, paths: Paths(), output: .file(.nullDevice))
        func pair() throws -> (FrameConnection, FrameConnection) {
            var fds: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
            let a = fds[0], b = fds[1]
            return (FrameConnection(fd: a) { _ = Darwin.close(a) },
                    FrameConnection(fd: b) { _ = Darwin.close(b) })
        }
        let (old, peer) = try pair(), (fresh, otherPeer) = try pair()
        let a = AgentClient(control: old, open: { throw DMXError("unused", "unused") })
        let b = AgentClient(control: fresh, open: { throw DMXError("unused", "unused") })
        defer { a.close(); b.close(); peer.close(); otherPeer.close() }
        let controller = MemoryController()
        controller.attach(machine: machine, agent: a)
        defer { controller.detach() }
        let memory = GuestMemory(total: 256 << 20, free: 0, available: 0, buffers: 0, cached: 0,
                                 shmem: 0, swapTotal: 0, swapFree: 0, balloon: 0)
        let tick = Task { await controller.tick(memory, quiet: true, machine: machine, agent: a) }
        let request = try #require(try await peer.receive())
        let body = try #require(JSONSerialization.jsonObject(with: request.1) as? [String: Any])
        #expect(body["method"] as? String == "swap_on")
        controller.detach()
        controller.attach(machine: machine, agent: b)
        let reply: [String: Any] = ["id": try #require(body["id"]), "result": ["size": 64 << 20]]
        try peer.writeFrame(.json, JSONSerialization.data(withJSONObject: reply))
        await tick.value
        #expect(!controller.swapOn)
    }
}
