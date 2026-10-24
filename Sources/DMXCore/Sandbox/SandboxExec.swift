import Foundation

extension Sandboxes {
    /// Runs a command in the sandbox and collects its output like `dmx_exec`: head and tail of
    /// each stream within `maxOutputBytes`, and on timeout or cancellation the command and its
    /// children are killed.
    public func exec(_ name: String, argv: [String], stdin: Data?, env: [String], cwd: String?,
                     timeout: Duration, maxOutputBytes: Int) async throws -> CappedExecResult {
        let started = ContinuousClock.now
        let capture = Captures(limit: maxOutputBytes)
        let (code, timedOut) = try await run(name, argv: argv, stdin: stdin, env: env, cwd: cwd, timeout: timeout) { stream, data in
            capture.append(stream, data)
        }
        if Task.isCancelled { throw CancellationError() }
        let (stdoutText, stdoutOmitted) = capture.out.finish()
        let (stderrText, stderrOmitted) = capture.err.finish()
        return CappedExecResult(
            exitCode: code, signal: nil, timedOut: timedOut, durationMs: milliseconds(ContinuousClock.now - started),
            stdout: stdoutText, stderr: stderrText, stdoutBytes: capture.out.total, stderrBytes: capture.err.total,
            stdoutOmittedBytes: stdoutOmitted, stderrOmittedBytes: stderrOmitted)
    }

    /// Runs a command in the sandbox, calling `output` with each piece of stdout (1) or stderr
    /// (2) as it comes, on a reading thread. Returns the exit code, or nil and whether the
    /// timeout ran out when it was killed. A stopped sandbox (the VM stopped) starts again first.
    public func run(_ name: String, argv: [String], stdin: Data?, env: [String], cwd: String?, timeout: Duration?,
                    output: @escaping @Sendable (UInt8, Data) -> Void) async throws -> (exitCode: Int32?, timedOut: Bool) {
        guard !argv.isEmpty else { throw DMXError("bad_argument", "no command to run", hint: "e.g. `dmx sandbox exec NAME -- uname -a`") }
        let id = try await running(name)
        var body: [String: JSONValue] = [
            "AttachStdin": .bool(stdin != nil), "AttachStdout": true, "AttachStderr": true, "Tty": false,
            "Cmd": .array(argv.map { .string($0) }),
        ]
        if !env.isEmpty { body["Env"] = .array(env.map { .string($0) }) }
        if let cwd { body["WorkingDir"] = .string(cwd) }
        let created = try await docker.json("POST", "/containers/\(id)/exec", body: .object(body), code: "sandbox_exec_failed", notFound: notFound(name))
        guard let execID = created["Id"]?.string else { throw DMXError("sandbox_exec_failed", "dockerd returned no exec id") }
        let (status, stream, rest) = try await docker.start("POST", "/exec/\(execID)/start", body: ["Detach": false, "Tty": false])
        defer { stream.close() }
        guard status == 200 || status == 101 else {
            let message = String(decoding: rest.prefix(300), as: UTF8.self)
            throw DMXError("sandbox_exec_failed", "\(argv[0]): dockerd answered \(status): \(message)", hint: "check the program exists in the image")
        }

        let killer = StreamKiller(stream)
        let timer = timeout.map { timeout in
            Task {
                try await Task.sleep(for: timeout)
                killer.kill(timedOut: true)
            }
        }
        defer { timer?.cancel() }
        let feed = Task.detached {
            guard let stdin else { return }
            var offset = 0
            while offset < stdin.count {
                let end = min(offset + 256 << 10, stdin.count)
                guard (try? stream.writeAll(stdin[offset..<end])) != nil else { return }
                offset = end
            }
            _ = Darwin.shutdown(stream.fd, SHUT_WR)
        }
        defer { feed.cancel() }

        try await withTaskCancellationHandler {
            _ = try await onThread {
                var frames = DockerFrames()
                for (s, data) in frames.feed(rest) { output(s, data) }
                while true {
                    guard let chunk = try? stream.read(), !chunk.isEmpty else { return }
                    for (s, data) in frames.feed(chunk) { output(s, data) }
                }
            }
        } onCancel: {
            killer.kill(timedOut: false)
        }

        if killer.killed {
            await kill(execID)
            return (nil, killer.timedOut)
        }
        // The stream ends a moment before dockerd records the exit code.
        for _ in 0..<50 {
            let state = try await docker.json("GET", "/exec/\(execID)/json", code: "sandbox_exec_failed")
            if state["Running"] != .bool(true), let code = state["ExitCode"]?.intValue { return (Int32(code), false) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw DMXError("sandbox_exec_failed", "\(argv[0]): no exit code from dockerd", hint: "see `dmx exec -- tail -50 \(dockerdLog)`")
    }

    /// The id of the sandbox's running container. A sandbox stopped with the VM (`dmx stop`, a
    /// reboot) starts again here, with its egress rules, unless its TTL has passed.
    func running(_ name: String) async throws -> String {
        try Self.checkName(name)
        guard let c = try await find(name), let id = c["Id"]?.string, let labels = c["Labels"]?.object else { throw notFound(name) }
        if c["State"]?.string == "running" { return id }
        if let expires = Int(labels[Self.expiresLabel]?.string ?? ""), expires <= Int(Date().timeIntervalSince1970) {
            _ = try? await remove(name, reason: "ttl")
            throw notFound(name)
        }
        let policy = labels[Self.policyLabel]?.string.flatMap { try? FrameConnection.decoder.decode(SandboxPolicy.self, from: Data($0.utf8)) } ?? SandboxPolicy()
        if policy.command != nil {
            throw DMXError("sandbox_not_running", "\(name)'s command has exited (\(c["Status"]?.string ?? "stopped"))",
                           hint: "read its output with `dmx sandbox logs \(name)`; roll it back or remove it")
        }
        try await docker.json("POST", "/containers/\(id)/start", code: "sandbox_exec_failed")
        try await fence(id: id, policy: policy, allowed: (labels[Self.allowedLabel]?.string ?? "").split(separator: ",").map(String.init))
        return id
    }

    /// Kills a timed out or cancelled exec and everything it started. Docker has no call for
    /// that (closing the stream leaves the process running), so it is done from the guest:
    /// each process is stopped before its children are listed, so none can slip out.
    private func kill(_ execID: String) async {
        guard let state = try? await docker.json("GET", "/exec/\(execID)/json"), let pid = state["Pid"]?.intValue, pid > 0,
              state["Running"] == .bool(true) else { return }
        let script = #"k() { kill -STOP "$1" 2>/dev/null; for c in $(pgrep -P "$1"); do k "$c"; done; kill -KILL "$1" 2>/dev/null; }; k "$1""#
        _ = try? await guest(["sh", "-c", script, "kill", String(pid)])
    }
}

/// Both streams' captures, written by the reading thread and read once it is done.
private final class Captures: @unchecked Sendable {
    var out: OutputCapture
    var err: OutputCapture

    init(limit: Int) {
        out = OutputCapture(limit: limit)
        err = OutputCapture(limit: limit)
    }

    func append(_ stream: UInt8, _ data: Data) {
        if stream == 2 { err.append(data) } else { out.append(data) }
    }
}

/// Ends a read from another task by shutting the stream down; remembers why.
final class StreamKiller: @unchecked Sendable {
    private let lock = NSLock()
    private let stream: DockerStream
    private var done = false
    private var byTimeout = false

    init(_ stream: DockerStream) { self.stream = stream }

    var killed: Bool { lock.withLock { done } }
    var timedOut: Bool { lock.withLock { byTimeout } }

    func kill(timedOut: Bool) {
        lock.withLock {
            guard !done else { return }
            done = true
            byTimeout = timedOut
            stream.shutdown()
        }
    }
}
