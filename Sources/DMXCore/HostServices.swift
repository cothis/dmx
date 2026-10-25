import Foundation

/// Services on the Mac that the guest connects to over vsock, as Docker Desktop offers them under
/// `/run/host-services` in its VM. The guest agent listens on a Unix socket there and opens a
/// vsock stream to the host port for each connection (docs/agent-protocol.md).
enum HostServices {
    /// The Mac's SSH agent, for `/run/host-services/ssh-auth.sock` in the guest.
    static let sshAgentPort: UInt32 = 1025

    static func attach(to vsock: VirtioVsock) {
        vsock.listen(port: sshAgentPort) { guest in
            Task {
                await sshAgent(guest)
                close(guest)
            }
        }
    }

    /// Joins one guest connection to the Mac's SSH agent. Without an agent the guest's client
    /// reads end of stream, as from an agent that went away.
    static func sshAgent(_ guest: Int32) async {
        guard let path = sshAgentPath() else {
            log("ssh agent: no SSH_AUTH_SOCK here or in launchd; a guest client got nothing")
            return
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard var address = try? unixAddress(URL(fileURLWithPath: path)) else { return }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            log("ssh agent: connect \(path): \(String(cString: strerror(errno)))")
            return
        }
        await splice(guest, fd)
    }

    /// The agent socket: this process's SSH_AUTH_SOCK (a daemon the CLI started has the user's
    /// environment, a launchd one the login session's), else the one launchd sets up for macOS's
    /// own ssh-agent, which a daemon started outside the login session (over ssh, in an old tmux)
    /// does not inherit.
    static func sshAgentPath() -> String? {
        if let path = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !path.isEmpty { return path }
        if let path = try? LaunchAgent.launchctl(["getenv", "SSH_AUTH_SOCK"]), !path.isEmpty { return path }
        // "SSH_AUTH_SOCK => /var/run/com.apple.launchd.<id>/Listeners" among the job's variables.
        let job = (try? LaunchAgent.launchctl(["print", "gui/\(getuid())/com.openssh.ssh-agent"])) ?? ""
        for line in job.split(separator: "\n") {
            let parts = line.split(separator: "=>", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "SSH_AUTH_SOCK", parts[1].hasPrefix("/") { return parts[1] }
        }
        return nil
    }
}
