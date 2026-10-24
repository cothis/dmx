import Foundation

/// Removes sandboxes when their TTL runs out, in the daemon, so it happens whether or not the
/// client that created them is still around. A running sandbox keeps the VM up (it is a running
/// container), and the VM is the daemon's, so while one exists the daemon is there to reap it.
///
/// It talks to dockerd through the agent directly, not docker.sock, so it does not count as
/// using the VM. It wakes when the running containers change and then at the next expiry, at
/// least once a minute while sandboxes exist: the deadline is wall-clock time, and a Mac that
/// slept past it is caught on the next check.
@MainActor
final class SandboxReaper {
    private var task: Task<Void, Never>?

    /// dockerd's containers changed; nil when dockerd or the VM went away.
    func update(agent: AgentClient?) {
        task?.cancel()
        task = nil
        guard let agent else { return }
        let sandboxes = Sandboxes(docker: DockerAPI {
            let connection = try await agent.connect(path: DockerBridge.guestSocket)
            return DockerStream(fd: connection.fd) { connection.close() }
        })
        task = Task {
            while !Task.isCancelled {
                for removed in await sandboxes.sweep() { log("sandbox: removed \(removed.name), its TTL ran out") }
                let next: Int?
                do {
                    next = try await sandboxes.nextExpiry()
                } catch {
                    log("sandbox: \((error as? DMXError)?.message ?? "\(error)")")
                    next = 60
                }
                guard let next else { return }
                try? await Task.sleep(for: .seconds(min(max(next, 1), 60)))
            }
        }
    }
}
