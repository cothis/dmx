import Foundation
import Testing
@testable import DMXCore

struct MenuSessionTests {
    @Test func lateBootSnapshotCannotUndoAnAcceptedStop() {
        var state = MenuSessionState(); state.bind(pid: 123)
        state.receive(receipt("running", sequence: 1))
        state.receive(receipt("stopped", sequence: 2))
        state.reconcileBoot(state: "running")
        state.failed(DMXError("docker_context_failed", "late setup result"), scope: .operation)
        #expect(state.phase == .stopped)
        #expect(state.failure == nil)
        #expect(state.shouldExit(startupFinished: true, busy: false, refreshing: false))
        state.prepareStart()
        state.reconcileBoot(state: "running")
        #expect(state.phase == .running)
    }

    private func receipt(_ state: String, sequence: UInt64, failure: DMXError? = nil) -> EngineActivity {
        EngineActivity(pid: 123, version: "test", state: state, containers: nil, reason: nil,
                       failure: failure.map(EngineActivity.Failure.init), sequence: sequence)
    }

    @Test func operationFailureCannotRetainANormallyStoppedApp() {
        var state = MenuSessionState(); state.bind(pid: 123)
        state.receive(receipt("running", sequence: 1))
        state.failed(DMXError("docker_failed", "port in use"), scope: .operation)
        #expect(state.failure != nil)
        state.receive(receipt("stopped", sequence: 2))
        #expect(state.failure == nil)
        #expect(state.shouldExit(startupFinished: true, busy: false, refreshing: false))
    }

    @Test func lifecycleFailureIsVisibleButStaleFailureCannotReplayOnRetry() {
        var state = MenuSessionState(); state.bind(pid: 123)
        let failed = receipt("stopped", sequence: 4, failure: DMXError("boot_failed", "bad guest"))
        let first = state.receive(failed); #expect(first)
        #expect(state.blocksAutomaticExit)
        #expect(!state.shouldExit(startupFinished: true, busy: false, refreshing: false))
        state.prepareStart(); state.bind(pid: 123)
        let repeated = state.receive(failed); #expect(!repeated)
        #expect(state.failure == nil)
        let older = state.receive(receipt("running", sequence: 3)); #expect(!older)
        let newer = state.receive(receipt("running", sequence: 5)); #expect(newer)
        #expect(state.phase == .running)
    }

    @Test func successfulOperationAndAuthoritativePhaseRecoverIndependently() {
        var state = MenuSessionState(); state.bind(pid: 123)
        state.failed(DMXError("docker_timeout", "slow"), scope: .operation)
        state.operationSucceeded()
        #expect(state.failure == nil)
        state.reconcile(state: "starting"); #expect(state.phase == .starting)
        state.reconcile(state: "stopped"); #expect(state.phase == .stopped)
        #expect(!state.shouldExit(startupFinished: true, busy: true, refreshing: false))
        #expect(state.shouldExit(startupFinished: true, busy: false, refreshing: false))
    }

    @Test func controlDeadlineWakesItsOwnWaitBeforePeerCloses() async throws {
        var pair: [Int32] = [0, 0]
        let socketResult = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
        try #require(socketResult == 0)
        let fd = pair[0], peer = pair[1]
        let connection = FrameConnection(fd: fd, peer: .daemon) { Darwin.close(fd) }
        defer { connection.close(); Darwin.close(peer) }
        let started = ContinuousClock.now
        do {
            let _: DaemonStatus = try await withConnectionDeadline(.milliseconds(100), connection: connection) {
                try await connection.call("status", NoParams())
            }
            Issue.record("silent control peer must time out")
        } catch let error as DMXError { #expect(error.code == "daemon_timeout") }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(fcntl(peer, F_GETFD) >= 0)
    }

    @Test func helpersThatNeverAnswerAreReapedWithoutAnObserver() async throws {
        var args: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { free(args[0]) }
        var pid: Int32 = 0
        let spawnResult = posix_spawn(&pid, "/usr/bin/true", nil, nil, &args, environ)
        try #require(spawnResult == 0)
        DaemonChildren.shared.register(pid)
        defer { _ = waitpid(pid, nil, WNOHANG) }
        let deadline = ContinuousClock.now + .seconds(2)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) != 0)
    }
}
