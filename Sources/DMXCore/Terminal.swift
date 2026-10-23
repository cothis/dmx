import Foundation

/// Puts the controlling terminal in raw mode so keystrokes (Ctrl-C included) reach the guest.
public final class RawTerminal {
    private var saved = termios()

    /// Returns nil when stdin is not a terminal, e.g. when an agent pipes input in.
    public init?() {
        guard isatty(STDIN_FILENO) == 1, tcgetattr(STDIN_FILENO, &saved) == 0 else { return nil }
        var raw = saved
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    }

    public func restore() {
        tcsetattr(STDIN_FILENO, TCSANOW, &saved)
    }

    deinit { restore() }
}

/// Copies stdin to the guest on a background thread, handing each chunk to `send`.
/// Calls `onEscape` when Ctrl-] is typed.
public func forwardStdin(_ send: @escaping @Sendable (Data) -> Void, onEscape: @escaping @Sendable () -> Void) {
    let thread = Thread {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(STDIN_FILENO, &buffer, buffer.count)
            // On a terminal stdin shares its file description with stdout, which may have been
            // made non-blocking, so wait instead of treating EAGAIN as EOF.
            if n < 0, errno == EAGAIN || errno == EINTR {
                var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                _ = poll(&fd, 1, -1)
                continue
            }
            if n <= 0 { return }
            var chunk = buffer[0..<n]
            if let escape = chunk.firstIndex(of: 0x1d) {
                chunk = chunk[..<escape]
                send(Data(chunk))
                onEscape()
                return
            }
            send(Data(chunk))
        }
    }
    thread.start()
}
