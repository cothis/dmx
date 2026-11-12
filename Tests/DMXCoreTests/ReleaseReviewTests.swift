import Darwin
import Foundation
import Testing
@testable import DMXCore

@Suite(.serialized) struct ReleaseReviewTests {
    func pair() throws -> (FrameConnection, FrameConnection) { try RemainingLifecycleTests().pair() }
    func wait(_ semaphore:DispatchSemaphore,seconds:Double) async -> DispatchTimeoutResult {
        await withCheckedContinuation { done in
            DispatchQueue.global().async { done.resume(returning:semaphore.wait(timeout:.now()+seconds)) }
        }
    }
    final class Failure: @unchecked Sendable {
        let lock=NSLock();var code="none"
        func set(_ error:Error) { lock.withLock { code=(error as? DMXError)?.code ?? "other" } }
        var value:String { lock.withLock { code } }
    }
    @Test func legacyInputRejectsBeforeBlockingControls() async throws {
        let (a,b)=try pair();defer { a.close();b.close() }
        let session=ExecSession(connection:a,pid:1)
        let entered=DispatchSemaphore(value:0),fed=DispatchSemaphore(value:0),signalled=DispatchSemaphore(value:0)
        let failure=Failure()
        DispatchQueue.global().async {
            entered.signal()
            do { try session.write(Data(repeating:1,count:1<<20)) } catch { failure.set(error) }
            fed.signal()
        }
        _ = await wait(entered,seconds:1)
        try await Task.sleep(for:.milliseconds(20))
        DispatchQueue.global().async { try? session.signal(SIGINT);signalled.signal() }
        let feedReturned=await wait(fed,seconds:0.1),controlReturned=await wait(signalled,seconds:0.1)
        a.close() // release the original blocked writer before asserting
        #expect(feedReturned == .success)
        #expect(controlReturned == .success)
        if feedReturned != .success { _ = await wait(fed,seconds:1) }
        if controlReturned != .success { _ = await wait(signalled,seconds:1) }
        #expect(failure.value == "guest_upgrade_required")
    }
    @Test func peerEOFWakesAWriterWaitingForCredit() async throws {
        let (a,b)=try pair();defer { a.close();b.close() }
        let start=Task { try await a.exec(ExecRequest(argv:["sleep","30"])) }
        _ = try await b.receive()
        try b.writeFrame(.json,Data(#"{"id":1,"ok":true,"result":{"pid":1,"stdin_window":65536}}"#.utf8))
        let session=try await start.value
        let fed=DispatchSemaphore(value:0)
        DispatchQueue.global().async { try? session.write(Data(repeating:1,count:128<<10));fed.signal() }
        let events=Task { do { for try await _ in session.events {} } catch {} }
        var count=0
        while count<65536 { let frame=try #require(try await b.receive());count+=frame.1.count }
        b.close() // no exit event or final credit is sent
        await events.value
        let woke=await wait(fed,seconds:0.2)
        a.close()
        #expect(woke == .success)
        if woke != .success { _ = await wait(fed,seconds:1) }
    }
    @Test @MainActor func clockMeasurementExcludesConnectionSetup() async throws {
        let (a,b)=try pair(),(fresh,peer)=try pair()
        let client=AgentClient(control:a,open:{try await Task.sleep(for:.milliseconds(150));return fresh})
        defer { client.close();b.close();fresh.close();peer.close() }
        let responder=Task {
            let frame=try #require(try await peer.receive())
            let request=try #require(JSONSerialization.jsonObject(with:frame.1) as? [String:Any])
            let params=try #require(request["params"] as? [String:Any])
            let stamp=try #require(params["unix_ns"] as? Int64)
            let result:[String:Any] = ["id":try #require(request["id"]),"ok":true,"result":["offset_ns":Int64(Date().timeIntervalSince1970*1e9)-stamp,"measured":true]]
            try peer.writeFrame(.json,JSONSerialization.data(withJSONObject:result))
        }
        let reading=try await client.measureClock()
        try await responder.value
        #expect(reading.roundTripNs < 100_000_000)
        #expect(abs(reading.arrivalNs) < 100_000_000)
    }
    @Test func earlyExitWinsOverUnusedStdin() async throws {
        let (a,b)=try pair(),(fresh,peer)=try pair()
        let client=AgentClient(control:a,open:{fresh})
        defer { client.close();b.close();fresh.close();peer.close() }
        let responder=Task {
            _ = try await peer.receive()
            try peer.writeFrame(.json,Data(#"{"id":1,"ok":true,"result":{"pid":1,"stdin_window":65536}}"#.utf8))
            try peer.writeFrame(.json,Data(#"{"event":"exit","code":0}"#.utf8))
            try await Task.sleep(for:.milliseconds(100))
            peer.close() // keep a regressed feeder bounded while still requiring the exit result
        }
        let result=try await client.run(["true"],stdin:Data(repeating:1,count:1<<20))
        try await responder.value
        #expect(result.exit.code == 0)
    }
    @Test func bootClockAllowsAColdGuestResponse() async throws {
        let (a,b)=try pair(),(fresh,peer)=try pair()
        let client=AgentClient(control:a,open:{fresh})
        defer { client.close();b.close();fresh.close();peer.close() }
        let responder=Task {
            _ = try await peer.receive()
            try await Task.sleep(for:.milliseconds(2100))
            try peer.writeFrame(.json,Data(#"{"id":1,"ok":true,"result":{"offset_ns":0}}"#.utf8))
        }
        #expect(try await client.syncTime() == 0)
        try await responder.value
    }
    @Test @MainActor func dockerdAbsenceRetiresListingRetryBeforeRestart() async throws {
        let home=URL(fileURLWithPath:"/private/tmp/dmx-dockerd-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at:home) }
        let paths=Paths(environment:["DMX_HOME":home.path]);var calls=0,healthy=false
        let bridge=DockerBridge(paths:paths,ports:PortForwards(paths:paths),listContainers:{_ in
            calls+=1
            if !healthy { throw DMXError("injected","unavailable") }
            return []
        })
        let (a,b)=try pair();let agent=AgentClient(control:a,open:{throw DMXError("unused","unused")})
        defer { bridge.vmStopped();agent.close();b.close() }
        bridge.syncSoon(agent,0)
        try await Task.sleep(for:.milliseconds(30));#expect(bridge.busy)
        bridge.dockerdStopped()
        let stopped=calls
        try await Task.sleep(for:.milliseconds(250))
        #expect(!bridge.busy);#expect(calls == stopped)
        healthy=true;bridge.syncSoon(agent,0)
        try await Task.sleep(for:.milliseconds(50))
        #expect(calls == stopped+1);#expect(bridge.containers == 0);#expect(!bridge.busy)
    }
}
