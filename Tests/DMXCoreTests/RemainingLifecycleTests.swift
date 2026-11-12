import Darwin
import Foundation
import Testing
@testable import DMXCore

@Suite(.serialized) struct RemainingLifecycleTests {
    struct Empty: Codable, Sendable {}
    func pair() throws -> (FrameConnection, FrameConnection) {
        var fds: [Int32] = [-1,-1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let a = fds[0], b = fds[1]
        return (FrameConnection(fd: a) { _ = Darwin.close(a) }, FrameConnection(fd: b) { _ = Darwin.close(b) })
    }

    @Test func stdinSliceKeepsItsBytesAcrossFrames() async throws {
        let (a,b) = try pair()
        defer { a.close(); b.close() }
        let start = Task { try await a.exec(ExecRequest(argv:["cat"])) }
        _ = try await b.receive()
        try b.writeFrame(.json, Data(#"{"id":1,"ok":true,"result":{"pid":1,"stdin_window":65536}}"#.utf8))
        let session = try await start.value
        let events = Task { for try await _ in session.events {} }
        let data = Data((0..<(1 << 19)).map { UInt8($0 & 255) }).dropFirst(17)
        #expect(data.startIndex == 17)
        let feed = Task.detached { try session.write(data); try session.closeStdin() }
        var received = Data()
        while let (kind,payload) = try await b.receive() {
            #expect(kind == .stdin)
            if payload.isEmpty { break }
            received.append(payload)
            try b.writeFrame(.json, JSONSerialization.data(withJSONObject:["event":"stdin_credit","bytes":payload.count]))
        }
        try b.writeFrame(.json, Data(#"{"event":"exit","code":0,"signal":null}"#.utf8))
        try await feed.value
        try await events.value
        #expect(received == data)
    }

    @Test func agentDeadlineKeepsTheAgentErrorCode() async throws {
        let (a,b) = try pair()
        defer { a.close(); b.close() }
        do {
            let _: Empty = try await withConnectionDeadline(.milliseconds(50), connection:a) {
                try await a.call("shutdown", Empty())
            }
            Issue.record("silent guest did not time out")
        } catch let error as DMXError { #expect(error.code == "agent_timeout") }
    }

    @Test @MainActor func shutdownBypassesBusyControl() async throws {
        let (control, peer) = try pair(), (fresh, shutdownPeer) = try pair()
        let agent = AgentClient(control: control, open: { fresh })
        defer { agent.close(); peer.close(); fresh.close(); shutdownPeer.close() }
        let slow = Task { () -> Empty in try await agent.call("slow", Empty()) }
        let request = try #require(try await peer.receive())
        let body = try #require(JSONSerialization.jsonObject(with: request.1) as? [String: Any])
        let id = try #require(body["id"] as? Int)
        let release = Task {
            try await Task.sleep(for: .milliseconds(700))
            try peer.writeFrame(.json, JSONSerialization.data(withJSONObject: ["id":id,"ok":true,"result":[:]]))
            if let f = try? await peer.receive(), let q = try? JSONSerialization.jsonObject(with: f.1) as? [String:Any], let id = q["id"] {
                try? peer.writeFrame(.json, JSONSerialization.data(withJSONObject: ["id":id,"ok":true,"result":[:]]))
            }
        }
        let answer = Task {
            if let f = try await shutdownPeer.receive(), let q = try JSONSerialization.jsonObject(with: f.1) as? [String:Any] {
                #expect(q["method"] as? String == "shutdown")
                try shutdownPeer.writeFrame(.json, JSONSerialization.data(withJSONObject: ["id":try #require(q["id"]),"ok":true,"result":[:]]))
            }
        }
        let start = ContinuousClock.now
        try await agent.shutdown()
        #expect(ContinuousClock.now - start < .milliseconds(400))
        _ = try await slow.value
        peer.close(); shutdownPeer.close()
        _ = try? await answer.value; _ = try? await release.value
    }

    @Test @MainActor func failedContainerListingRetriesAndOldEpochStops() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dmx-list-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(environment: ["DMX_HOME":home.path])
        let ports = PortForwards(paths: paths)
        var calls = 0
        let bridge = DockerBridge(paths: paths, ports: ports, listContainers: { _ in
            calls += 1
            if calls == 1 { throw DMXError("injected", "listing failed") }
            return []
        })
        let (a,b) = try pair()
        let agent = AgentClient(control: a, open: { throw DMXError("unused", "unused") })
        defer { bridge.vmStopped(); agent.close(); b.close() }
        bridge.syncSoon(agent, 0)
        try await Task.sleep(for: .milliseconds(40))
        #expect(bridge.busy)
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls == 2)
        #expect(bridge.containers == 0)
        #expect(!bridge.busy)
        bridge.vmStopped()
        bridge.syncSoon(agent, 0) // old event cannot start another listing
        try await Task.sleep(for: .milliseconds(150))
        #expect(calls == 2)
    }

    final class Counter: @unchecked Sendable {
        let lock = NSLock(); private var value = 0
        func hit() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }
    @Test @MainActor func dockerEMFILEBacksOff() async throws {
        let home = URL(fileURLWithPath:"/private/tmp/dmx-emf-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(environment:["DMX_HOME":home.path])
        let calls = Counter()
        let bridge = DockerBridge(paths:paths, ports:PortForwards(paths:paths), acceptFD: { _ in calls.hit(); errno = EMFILE; return -1 })
        bridge.start(agent: { throw DMXError("unused","unused") }, using: {_ in}, changed: {})
        defer { bridge.stop() }
        let fd = socket(AF_UNIX,SOCK_STREAM,0)
        defer { Darwin.close(fd) }
        var address = try unixAddress(paths.dockerSocket)
        let result = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(result == 0)
        try await Task.sleep(for:.milliseconds(350))
        #expect(calls.count >= 2 && calls.count <= 5)
    }

    @Test func forwardedSocketsHaveBoundedKeepalive() {
        for family in [AF_INET, AF_INET6] {
            let fd = socket(family, SOCK_STREAM, 0)
            #expect(fd >= 0)
            defer { Darwin.close(fd) }
            configureForwardKeepalive(fd)
            for (level, option, expected): (Int32, Int32, Int32) in [
                (SOL_SOCKET, SO_KEEPALIVE, 1), (IPPROTO_TCP, TCP_KEEPALIVE, 60),
                (IPPROTO_TCP, TCP_KEEPINTVL, 10), (IPPROTO_TCP, TCP_KEEPCNT, 3)
            ] {
                var value: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                #expect(getsockopt(fd, level, option, &value, &length) == 0)
                if level == SOL_SOCKET { #expect(value != 0) }
                else { #expect(value == expected) }
            }
        }
    }

    @Test func halfClosedFlowExpiresAndLiveIdleFlowStays() {
        let device = VirtioNet()
        device.queue.sync {
            let key = UserNet.FlowKey(guestPort:1234,remote:IPAddress(v4:0x08080808),remotePort:80)
            let half = TCPFlow(key:key,irs:10)
            half.guestFinished = true
            half.halfClosedAt = .now - UserNet.halfCloseTimeout - .seconds(1)
            // Expiry only needs the close path; a nil socket is safe for an unconnected flow.
            device.net.tcp[key] = half
            device.net.tcpTick(.now)
            #expect(device.net.tcp[key] == nil)
            let active = TCPFlow(key:key,irs:12)
            active.halfClosedAt = .now - UserNet.halfCloseTimeout - .seconds(1)
            active.madeProgress()
            device.net.tcp[key] = active
            device.net.tcpTick(.now)
            #expect(device.net.tcp[key] === active)
            device.net.tcpTick(.now + UserNet.halfCloseTimeout + .seconds(1))
            #expect(device.net.tcp[key] == nil)
            let live = TCPFlow(key:key,irs:11)
            device.net.tcp[key] = live
            device.net.tcpTick(.now + .seconds(600))
            #expect(device.net.tcp[key] === live)
            device.net.tcp.removeAll()
        }
        device.stop()
    }
}
