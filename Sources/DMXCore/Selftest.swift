import Foundation

public struct SelftestCheck: Encodable, Sendable {
    public let name: String
    public let ok: Bool
    public let detail: String
}

public struct SelftestReport: Encodable, Sendable {
    public let ok: Bool
    /// Host clock from `vm.start()` until dmx-agent answered `hello`.
    public let bootMs: Int?
    /// Host clock from the agent `shutdown` call until the VM stopped.
    public let shutdownMs: Int?
    public let cpus: Int
    public let maxMemory: String
    public let agent: AgentHello?
    public let uname: String?
    /// Guest clock minus host clock at boot, before `time_sync` corrected it.
    public let clockOffsetMs: Double?
    /// Guest memory in use (total minus available), in MiB, after dropping caches.
    public let guestUsedMb: Int?
    public let stats: AgentStats?
    public let checks: [SelftestCheck]
    public let problems: [String]
    /// Raw console output, included only when the run failed.
    public let console: [String]?
}

/// Boots the guest, exercises every agent call over vsock, and powers off through the agent.
@MainActor
public func runSelftest(paths: Paths, spec: MachineSpec, timeout: Duration, echo: Bool) async throws -> SelftestReport {
    var spec = spec
    if !echo { spec.kernelArgs.append("quiet") }

    let capture = ConsoleCapture(echo: echo)
    let console = Console(fromGuest: capture.pipe.fileHandleForWriting)
    let machine = try Machine(spec: spec, paths: paths, console: console)

    let started = ContinuousClock.now
    capture.start()
    try await machine.start()

    let watchdog = Task { @MainActor () -> Bool in
        do { try await Task.sleep(for: timeout) } catch { return false }
        await machine.stop()
        return true
    }

    var problems: [String] = []
    var checks: [SelftestCheck] = []
    var hello: AgentHello?, uname: String?, offsetMs: Double?, stats: AgentStats?
    var bootMs: Int?, shutdownStarted: ContinuousClock.Instant?
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        checks.append(SelftestCheck(name: name, ok: ok, detail: detail))
        if !ok { problems.append("\(name): \(detail)") }
    }
    func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    do {
        let agent = try await machine.connectAgent(timeout: timeout)
        bootMs = milliseconds(ContinuousClock.now - started)
        hello = try await agent.hello()
        offsetMs = Double(try await agent.syncTime()) / 1e6

        let un = try await agent.run(["uname", "-a"])
        uname = text(un.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        check("exec", un.exit.code == 0 && !(uname ?? "").isEmpty, "uname -a exited \(un.exit.code.map(String.init) ?? "by signal")")

        let cat = try await agent.run(["cat"], stdin: Data("ping\n".utf8))
        check("exec_stdin", text(cat.stdout) == "ping\n", "cat echoed \(text(cat.stdout).debugDescription)")

        let sh = try await agent.run(["sh", "-c", "echo out; echo err >&2; exit 3"])
        check("exec_streams", sh.exit.code == 3 && text(sh.stdout) == "out\n" && text(sh.stderr) == "err\n",
              "exit \(sh.exit.code.map(String.init) ?? "nil"), stdout \(text(sh.stdout).debugDescription), stderr \(text(sh.stderr).debugDescription)")

        let tty = try await agent.run(["tty"], tty: true)
        let ttyName = text(tty.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        check("exec_tty", ttyName.hasPrefix("/dev/pts/"), "tty printed \(ttyName.debugDescription)")

        let missing = try? await agent.run(["/nonexistent"])
        check("exec_missing", missing == nil, missing == nil ? "rejected with an error" : "unexpectedly ran")

        let modules = text(try await agent.run(["cat", "/proc/modules"]).stdout)
        for module in ["virtio_balloon", "vmw_vsock_virtio_transport"] {
            let loaded = modules.split(separator: "\n").contains { $0.hasPrefix(module + " ") }
            check("module.\(module)", loaded, loaded ? "loaded" : "missing")
        }

        let dropped = try await agent.dropCaches()
        check("drop_caches", dropped.availableAfter >= dropped.availableBefore / 2,
              "available \(formatSize(dropped.availableBefore)) -> \(formatSize(dropped.availableAfter))")
        stats = try await agent.stats()

        shutdownStarted = ContinuousClock.now
        try await agent.shutdown()
    } catch let error as DMXError {
        problems.append("\(error.code): \(error.message)")
    }
    if shutdownStarted == nil { await machine.stop() }

    let exit = await machine.waitUntilStopped()
    let shutdownMs = shutdownStarted.map { milliseconds(ContinuousClock.now - $0) }
    watchdog.cancel()
    if await watchdog.value { problems.append("timed out after \(timeout)") }
    if case .failed(let error) = exit { problems.append("\(error.code): \(error.message)") }

    let lines = capture.finish()
    problems += lines.filter { $0.contains("dmx-init:") || $0.contains("dmx-agent:") }

    let ok = problems.isEmpty
    return SelftestReport(
        ok: ok,
        bootMs: bootMs,
        shutdownMs: shutdownMs,
        cpus: machine.spec.cpus,
        maxMemory: formatSize(machine.spec.maxMemory),
        agent: hello,
        uname: uname,
        clockOffsetMs: offsetMs,
        guestUsedMb: stats.map { Int($0.memory.used >> 20) },
        stats: stats,
        checks: checks,
        problems: problems,
        console: ok ? nil : lines
    )
}

private func milliseconds(_ d: Duration) -> Int {
    Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
}

/// Collects guest console output from a background reader.
private final class ConsoleCapture: @unchecked Sendable {
    let pipe = Pipe()
    private let echo: Bool
    private let lock = NSLock()
    private var data = Data()

    init(echo: Bool) { self.echo = echo }

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            if self.echo { FileHandle.standardError.write(chunk) }
            self.lock.lock()
            self.data.append(chunk)
            self.lock.unlock()
        }
    }

    func finish() -> [String] {
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
