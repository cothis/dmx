import Foundation

/// Reaps every helper this process actually spawned, including helpers that lose the daemon
/// lock race. Observing an arbitrary process never confers ownership of its wait status.
final class DaemonChildren: @unchecked Sendable {
    static let shared = DaemonChildren()
    private let lock = NSLock()
    private var children: [Int32: DispatchSourceProcess] = [:]

    func register(_ pid: Int32) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { [self] in
            lock.withLock {
                guard let source = children.removeValue(forKey: pid) else { return }
                while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
                source.setEventHandler(handler: nil)
                source.cancel()
            }
        }
        lock.withLock { children[pid] = source }
        source.resume()
    }

    func reapIfExited(_ pid: Int32) {
        lock.withLock {
            guard let source = children[pid] else { return }
            let result = waitpid(pid, nil, WNOHANG)
            if result == pid || (result < 0 && errno == ECHILD) {
                children.removeValue(forKey: pid)
                source.setEventHandler(handler: nil); source.cancel()
            }
        }
    }
}
