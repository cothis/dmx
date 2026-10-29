import Foundation

/// A one-shot deadline owns no descriptor. Expiry retires the FrameConnection, whose RPC
/// lease keeps the socket alive until in-flight I/O ends. Cancellation never replays a call.
private final class ConnectionDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var expired = false
    private var timer: DispatchSourceTimer?

    init(_ duration: Duration?, connection: FrameConnection) {
        guard let duration else { return }
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard self.active else { return }
                self.active = false
                self.expired = true
                connection.close()
            }
        }
        source.schedule(deadline: .now() + max(seconds(duration), 0))
        source.resume()
        timer = source
    }

    func finish() -> Bool {
        lock.withLock {
            active = false
            timer?.cancel(); timer = nil
            return expired
        }
    }
}

func withConnectionDeadline<T: Sendable>(_ duration: Duration?, connection: FrameConnection,
                                        _ operation: @Sendable () async throws -> T) async throws -> T {
    let deadline = ConnectionDeadline(duration, connection: connection)
    return try await withTaskCancellationHandler {
        do {
            try Task.checkCancellation()
            let result = try await operation()
            let expired = deadline.finish()
            try Task.checkCancellation()
            guard !expired else { throw timeout() }
            return result
        } catch {
            let expired = deadline.finish()
            if Task.isCancelled { throw CancellationError() }
            if expired { throw timeout() }
            throw error
        }
    } onCancel: { connection.close() }
}

private func timeout() -> DMXError {
    DMXError("daemon_timeout", "the dmx daemon did not complete the request before its deadline",
             hint: "run `dmx status`; inspect the daemon log before retrying `dmx stop`")
}
