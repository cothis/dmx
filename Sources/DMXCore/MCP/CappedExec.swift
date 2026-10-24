import Foundation

/// What a command run with `execCapped` produced. Each stream keeps its first and last bytes
/// up to the limit, with a marker in between saying how many were dropped.
public struct CappedExecResult: Codable, Sendable {
    /// Nil when the process was killed by a signal or by the timeout.
    public let exitCode: Int32?
    public let signal: Int32?
    /// The timeout ran out; the process and everything it started were killed.
    public let timedOut: Bool
    public let durationMs: Int
    public let stdout: String
    public let stderr: String
    /// Bytes the stream carried in total, and how many of them are not in the text.
    public let stdoutBytes: Int
    public let stderrBytes: Int
    public let stdoutOmittedBytes: Int
    public let stderrOmittedBytes: Int

    /// Like the synthesized one, but writes `exit_code` and `signal` as null rather than leaving
    /// them out, so every field is always present.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exitCode, forKey: .exitCode)
        try c.encode(signal, forKey: .signal)
        try c.encode(timedOut, forKey: .timedOut)
        try c.encode(durationMs, forKey: .durationMs)
        try c.encode(stdout, forKey: .stdout)
        try c.encode(stderr, forKey: .stderr)
        try c.encode(stdoutBytes, forKey: .stdoutBytes)
        try c.encode(stderrBytes, forKey: .stderrBytes)
        try c.encode(stdoutOmittedBytes, forKey: .stdoutOmittedBytes)
        try c.encode(stderrOmittedBytes, forKey: .stderrOmittedBytes)
    }
}

/// Keeps the head and tail of a stream within `limit` bytes however long the stream is, and
/// counts the rest. Memory stays under about twice the limit plus one chunk.
struct OutputCapture {
    let headLimit: Int
    let tailLimit: Int
    private var head = Data()
    private var tail = Data()
    private(set) var total = 0

    init(limit: Int) {
        headLimit = limit / 2
        tailLimit = limit - limit / 2
    }

    mutating func append(_ data: Data) {
        total += data.count
        var rest = data[...]
        if head.count < headLimit {
            let n = min(headLimit - head.count, rest.count)
            head.append(rest.prefix(n))
            rest = rest.dropFirst(n)
        }
        guard !rest.isEmpty, tailLimit > 0 else { return }
        tail.append(rest.suffix(tailLimit))
        if tail.count > 2 * tailLimit { tail = Data(tail.suffix(tailLimit)) }
    }

    /// The text kept, as UTF-8 cut on character boundaries, and the number of bytes left out.
    func finish() -> (text: String, omitted: Int) {
        if total <= headLimit + tailLimit {
            return (String(decoding: head + tail, as: UTF8.self), 0)
        }
        let first = head.prefix(utf8Prefix(head))
        var last = tail.suffix(tailLimit)
        while let byte = last.first, byte & 0xC0 == 0x80 { last = last.dropFirst() }
        let omitted = total - first.count - last.count
        let marker = "\n[... dmx: \(omitted) bytes omitted ...]\n"
        return (String(decoding: first, as: UTF8.self) + marker + String(decoding: last, as: UTF8.self), omitted)
    }

    /// The length of `data` without a multi-byte character cut off at its end.
    private func utf8Prefix(_ data: Data) -> Int {
        let bytes = [UInt8](data.suffix(4))
        for back in stride(from: 1, through: bytes.count, by: 1) {
            let byte = bytes[bytes.count - back]
            if byte & 0xC0 == 0x80 { continue }
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return length > back ? data.count - back : data.count
        }
        return data.count
    }
}

/// Runs a command in the daemon's VM (booting it if needed) and collects its output with at
/// most `maxOutputBytes` kept per stream. When `timeout` runs out, or the calling task is
/// cancelled, the connection is shut down and the agent kills the process group with SIGKILL.
public func execCapped(paths: Paths, argv: [String], stdin: Data?, env: [String], cwd: String?,
                       timeout: Duration, maxOutputBytes: Int) async throws -> CappedExecResult {
    let started = ContinuousClock.now
    guard let client = try await DaemonClient.connect(paths: paths, start: true) else {
        throw DMXError("daemon_unreachable", "no dmx daemon is running")
    }
    var request = ExecRequest(argv: argv)
    request.env = env
    request.cwd = cwd
    request.stdin = stdin != nil
    let session: ExecSession
    do {
        session = try await client.exec(request)
    } catch {
        client.close()
        throw error
    }
    client.close()

    let killer = ExecKiller(session)
    defer { killer.finish() }
    let timer = Task {
        try await Task.sleep(for: timeout)
        killer.kill(timedOut: true)
    }
    defer { timer.cancel() }
    // Output is read only while we iterate, so stdin goes in alongside (see AgentClient.run).
    let feed = Task.detached {
        guard let stdin else { return }
        var offset = 0
        while offset < stdin.count {
            let end = min(offset + 256 << 10, stdin.count)
            guard (try? session.write(stdin[offset..<end])) != nil else { return }
            offset = end
        }
        try? session.closeStdin()
    }
    defer { feed.cancel() }

    var out = OutputCapture(limit: maxOutputBytes)
    var err = OutputCapture(limit: maxOutputBytes)
    var exit: ExecExit?
    do {
        try await withTaskCancellationHandler {
            for try await event in session.events {
                switch event {
                case .stdout(let data): out.append(data)
                case .stderr(let data): err.append(data)
                case .exit(let e): exit = e
                }
            }
        } onCancel: {
            killer.kill(timedOut: false)
        }
    } catch {
        if Task.isCancelled { throw CancellationError() }
        guard killer.timedOut else { throw error }
    }
    if Task.isCancelled { throw CancellationError() }
    if exit == nil && !killer.timedOut {
        throw DMXError("daemon_disconnected", "\(argv[0]): connection closed before the process exited", hint: "see \(paths.daemonLog.path)")
    }
    let (stdoutText, stdoutOmitted) = out.finish()
    let (stderrText, stderrOmitted) = err.finish()
    let elapsed = ContinuousClock.now - started
    return CappedExecResult(
        exitCode: exit?.code, signal: exit?.signal, timedOut: exit == nil,
        durationMs: Int(elapsed / .milliseconds(1)),
        stdout: stdoutText, stderr: stderrText, stdoutBytes: out.total, stderrBytes: err.total,
        stdoutOmittedBytes: stdoutOmitted, stderrOmittedBytes: stderrOmitted)
}

/// Ends an exec from another task: shutting the socket down wakes the blocked read, and the
/// daemon, seeing the client gone, closes the agent's connection, so the agent kills the
/// process group. Does nothing once the exec is over, so a reused descriptor is never touched.
private final class ExecKiller: @unchecked Sendable {
    private let lock = NSLock()
    private let session: ExecSession
    private var done = false
    private var killedByTimeout = false

    init(_ session: ExecSession) { self.session = session }

    var timedOut: Bool { lock.withLock { killedByTimeout } }

    func kill(timedOut: Bool) {
        lock.withLock {
            guard !done else { return }
            done = true
            killedByTimeout = timedOut
            Darwin.shutdown(session.connection.fd, SHUT_RDWR)
        }
    }

    func finish() {
        lock.withLock {
            done = true
            session.connection.close()
        }
    }
}
