// Run alone: forces descriptor reuse while Docker HTTP is paused before its second poll.
import Darwin
import Foundation
@testable import DMXCore
@main struct DockerFDProbe {
    final class Result: @unchecked Sendable { var body: Data?; var lines = 0 }
    static func pair() -> [Int32] {
        var fds: [Int32] = [-1,-1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return fds
    }
    static func main() throws {
        let original=pair(),victim=pair(),fd=original[0],mode=CommandLine.arguments[1]
        var notify:[Int32]=[-1,-1],release:[Int32]=[-1,-1]
        precondition(pipe(&notify)==0 && pipe(&release)==0)
        setenv("DMX_GATE_ORIGINAL",String(fd),1)
        setenv("DMX_GATE_NOTIFY",String(notify[1]),1)
        setenv("DMX_GATE_RELEASE",String(release[0]),1)
        let connection=FrameConnection(fd:fd,duplicateFD:{ n in
            let copy=fcntl(n,F_DUPFD_CLOEXEC,0)
            setenv("DMX_GATE_COPY",String(copy),1)
            return copy
        }) { _ = Darwin.close(fd) }
        let first=Data("HTTP/1.0 200 OK\r\n\r\none\n".utf8)
        precondition(first.withUnsafeBytes { write(original[1],$0.baseAddress!,$0.count) }==first.count)
        let result=Result(),done=DispatchSemaphore(value:0)
        DispatchQueue.global().async { Task {
            if mode=="get" { result.body=try? await DockerHTTP.get(connection,"/containers/json") }
            else { await DockerHTTP.lines(connection) { result.lines += 1 } }
            done.signal()
        } }
        var byte:UInt8=0
        precondition(read(notify[0],&byte,1)==1,"reader reached next poll")
        connection.close()
        precondition(dup2(victim[0],fd)==fd)
        let foreign=Data("foreign\n".utf8)
        precondition(foreign.withUnsafeBytes { write(victim[1],$0.baseAddress!,$0.count) }==foreign.count)
        shutdown(victim[1],SHUT_WR)
        precondition(write(release[1],&byte,1)==1)
        precondition(done.wait(timeout:.now()+2) == .success,"cancel ends HTTP")
        if mode=="get" { precondition(result.body==nil || result.body==Data("one\n".utf8),"foreign response was spliced") }
        else { precondition(result.lines==1,"foreign event was consumed") }
        var bytes=[UInt8](repeating:0,count:foreign.count)
        precondition(recv(victim[0],&bytes,bytes.count,MSG_PEEK|MSG_DONTWAIT)==foreign.count,"foreign response remains unread")
        connection.close()
        precondition(fcntl(fd,F_GETFD)>=0)
        print("isolated Docker descriptor probe passed: \(mode)")
    }
}
