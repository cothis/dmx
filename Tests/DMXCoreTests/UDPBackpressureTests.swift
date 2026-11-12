import Darwin
import Foundation
import Testing
@testable import DMXCore

@Suite struct UDPBackpressureTests {
    final class Peers: @unchecked Sendable {
        let lock = NSLock()
        var connections: [FrameConnection] = []
        var closed = false
        func open() throws -> FrameConnection {
            var fds:[Int32]=[-1,-1]
            guard socketpair(AF_UNIX,SOCK_STREAM,0,&fds)==0 else { throw DMXError("test","socketpair") }
            let a=fds[0],b=fds[1]
            let host=FrameConnection(fd:a) { _ = Darwin.close(a) }
            let peer=FrameConnection(fd:b) { _ = Darwin.close(b) }
            lock.lock()
            if closed { peer.close() } else { connections.append(peer) }
            lock.unlock()
            return host
        }
        func close() { lock.withLock { closed=true; for c in connections { c.close() }; connections=[] } }
    }
    @Test @MainActor func unreadGuestCannotBlockCountsOrClose() async throws {
        let reserve=socket(AF_INET,SOCK_DGRAM,0)
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1")
        let bound=withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { bind(reserve,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(bound==0)
        var length=socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(reserve,$0,&length) } }
        Darwin.close(reserve)
        let peers=Peers()
        let relay=try UDPRelay(PortForward(hostAddress:"127.0.0.1",hostPort:Int(UInt16(bigEndian:address.sin_port)),guestPort:9999,proto:"udp"),connect:{try peers.open()},using:{_ in})
        defer { peers.close(); relay.close() }
        let destination=address
        let flood=Task.detached {
            let fd=socket(AF_INET,SOCK_DGRAM,0)
            defer { Darwin.close(fd) }
            _ = fcntl(fd,F_SETFL,O_NONBLOCK)
            let data=[UInt8](repeating:1,count:8192)
            var target=destination
            for _ in 0..<1500 {
                _ = withUnsafePointer(to:&target) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { sendto(fd,data,data.count,0,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                usleep(100)
            }
        }
        await flood.value
        try await Task.sleep(for:.milliseconds(100))
        let returned=DispatchSemaphore(value:0)
        DispatchQueue.global().async { _ = relay.counts; relay.close(); returned.signal() }
        let result=await withCheckedContinuation { done in
            DispatchQueue.global().async { done.resume(returning:returned.wait(timeout:.now() + .milliseconds(100))) }
        }
        try await Task.sleep(for: .milliseconds(100))
        let closed = relay.counts.active == 0
        peers.close() // also releases a blocking-write mutant after the assertion snapshot
        #expect(result == .success)
        #expect(closed)
    }
}
