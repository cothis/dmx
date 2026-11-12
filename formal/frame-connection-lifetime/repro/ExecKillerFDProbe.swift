// Destructive FD reuse must run in its own process.
import Darwin
import Foundation
@testable import DMXCore
@main struct ExecKillerFDProbe {
    static func pair() -> [Int32] {
        var fds:[Int32]=[-1,-1]
        precondition(socketpair(AF_UNIX,SOCK_STREAM,0,&fds)==0)
        var on:Int32=1
        for fd in fds { _ = setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&on,socklen_t(MemoryLayout<Int32>.size)) }
        return fds
    }
    static func main() async throws {
        let original=pair(),victim=pair(),fd=original[0]
        let connection=FrameConnection(fd:fd) { _ = Darwin.close(fd) }
        let session=ExecSession(connection:connection,pid:1),killer=ExecKiller(ExecSession(connection:connection,pid:1))
        shutdown(original[1],SHUT_WR)
        var iterator=session.events.makeAsyncIterator()
        do { _ = try await iterator.next();preconditionFailure("EOF without exit must throw") } catch {}
        precondition(connection.isClosed)
        // Pause before killer.finish(): cancellation may arrive after EOF has freed fd.
        precondition(dup2(victim[0],fd)==fd)
        killer.kill(timedOut:true)
        var byte:UInt8=42,received:UInt8=0
        precondition(write(victim[0],&byte,1)==1,"unrelated socket can still send")
        precondition(recv(victim[1],&received,1,MSG_DONTWAIT)==1 && received==42)
        precondition(write(victim[1],&byte,1)==1,"unrelated peer can still send")
        precondition(recv(victim[0],&received,1,MSG_DONTWAIT)==1 && received==42)
        killer.finish()
        precondition(fcntl(fd,F_GETFD)>=0,"late finish leaves reused descriptor open")
        print("isolated exec cancellation descriptor probe passed")
    }
}
