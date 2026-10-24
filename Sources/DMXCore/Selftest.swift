import CryptoKit
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
    /// Guest memory in use (total - free - buffers - cached + shmem), in MiB, after dropping caches.
    public let guestUsedMb: Int?
    public let stats: AgentStats?
    /// Host memory of the VM process, read after dropping caches, before shutdown.
    public let host: HostFootprint?
    public let reclaim: ReclaimReport?
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
    let machine = try Machine(spec: spec, paths: paths, console: capture.pipe.fileHandleForWriting)

    let started = ContinuousClock.now
    capture.start()
    try machine.start()

    let watchdog = Task { @MainActor () -> Bool in
        do { try await Task.sleep(for: timeout) } catch { return false }
        await machine.stop()
        return true
    }

    var problems: [String] = []
    var checks: [SelftestCheck] = []
    var hello: AgentHello?, uname: String?, offsetMs: Double?, stats: AgentStats?
    var host: HostFootprint?
    var reclaim: ReclaimReport?
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

        // Bound drivers, whether built in or loaded as modules: /sys/bus/virtio/drivers/<driver>/virtioN.
        let bound = text(try await agent.run(["find", "/sys/bus/virtio/drivers", "-mindepth", "2", "-maxdepth", "2", "-name", "virtio*"]).stdout)
            .split(separator: "\n").map { $0.split(separator: "/").dropLast().last.map(String.init) ?? "" }
        for driver in ["virtio_console", "virtio_rng", "virtio_balloon", "vmw_vsock_virtio_transport", "virtio_net"] {
            check("driver.\(driver)", bound.contains(driver), bound.contains(driver) ? "bound" : "no device bound")
        }

        // PSCI CPU_OFF then CPU_ON: the CPU must come back with its reset state, MMU off.
        if machine.spec.cpus > 1 {
            let cpu = "/sys/devices/system/cpu/cpu\(machine.spec.cpus - 1)/online"
            let hotplug = try await agent.run(["sh", "-c", "echo 0 > \(cpu) && echo 1 > \(cpu) && cat /sys/devices/system/cpu/online"])
            let online = text(hotplug.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            check("cpu_hotplug", hotplug.exit.code == 0 && online == "0-\(machine.spec.cpus - 1)", "cpu \(machine.spec.cpus - 1) off and on, online \(online.debugDescription)")
        }

        let dropped = try await agent.dropCaches()
        check("drop_caches", dropped.availableAfter >= dropped.availableBefore / 2,
              "available \(formatSize(dropped.availableBefore)) -> \(formatSize(dropped.availableAfter))")
        stats = try await agent.stats()
        host = machine.hostFootprint()
        check("host_footprint", host != nil, host.map { "pid \($0.pid), \($0.footprintMb) MB (peak \($0.peakFootprintMb) MB)" } ?? "VM process not found")

        if let idle = host {
            let r = try await measureReclaim(machine: machine, agent: agent, idle: idle)
            reclaim = r
            check("reclaim", r.returnedMs != nil,
                  "1 GB touched and freed: \(r.afterFreeMb) MB -> \(r.afterReclaimMb) MB \(r.returnedMs.map { "in \($0) ms" } ?? "(not within 10 s)"), \(r.reports) reports")
        }

        // Network, offline: ICMP to the gateway, and 4 MB over HTTP from the host's loopback
        // (192.168.127.254 in the guest) through the user space NAT. After the footprint
        // measurements, so network buffers do not count in them.
        let ping = try await agent.run(["ping", "-c", "1", "-W", "2", "192.168.127.1"])
        check("net_icmp", ping.exit.code == 0, "ping the gateway: exit \(ping.exit.code.map(String.init) ?? "by signal")")
        var body = Data(count: 4 << 20)
        body.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        let port = try serveOnce(body)
        let get = try await agent.run(["sh", "-c", "wget -q -O - http://192.168.127.254:\(port)/ | sha256sum"])
        let want = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        check("net_tcp", text(get.stdout).hasPrefix(want), "4 MB over HTTP from the host: \(text(get.stdout + get.stderr).prefix(80).debugDescription)")

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
        host: host,
        reclaim: reclaim,
        checks: checks,
        problems: problems,
        console: ok ? nil : lines
    )
}

public struct ReclaimReport: Encodable, Sendable {
    public let idleMb: Int
    public let afterFreeMb: Int
    public let afterReclaimMb: Int
    /// From freeing the memory in the guest until the footprint came back near idle, if it did.
    public let returnedMs: Int?
    /// Free page reports the guest made and the bytes they covered, since boot.
    public let reports: Int
    public let reportedMb: Int
}

/// Touches 1 GB in the guest (a tmpfs file of random data), deletes it, and waits up to 10 s for
/// free page reporting to bring the host footprint back within 32 MB of `idle`.
@MainActor
private func measureReclaim(machine: Machine, agent: AgentClient, idle: HostFootprint) async throws -> ReclaimReport {
    _ = try await agent.run(["sh", "-c", "head -c 1073741824 /dev/urandom > /run/fill"])
    let afterFill = machine.hostFootprint() ?? idle
    _ = try await agent.run(["rm", "/run/fill"])
    let freed = ContinuousClock.now
    var returnedMs: Int?
    var last = afterFill
    while ContinuousClock.now - freed < .seconds(10) {
        try await Task.sleep(for: .milliseconds(100))
        guard let now = machine.hostFootprint() else { break }
        last = now
        if now.footprint <= idle.footprint + (32 << 20) {
            returnedMs = milliseconds(ContinuousClock.now - freed)
            break
        }
    }
    let stats = machine.freePageReports
    return ReclaimReport(idleMb: idle.footprintMb, afterFreeMb: afterFill.footprintMb, afterReclaimMb: last.footprintMb,
                         returnedMs: returnedMs, reports: stats.reports, reportedMb: Int(stats.bytes >> 20))
}

/// Answers one HTTP request on 127.0.0.1 with `body`, from a background thread; returns the port.
/// Gives up after 30 s without a connection.
private func serveOnce(_ body: Data) throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, length) == 0 && listen(fd, 1) == 0 && getsockname(fd, $0, &length) == 0
        }
    }
    guard fd >= 0, bound else {
        if fd >= 0 { close(fd) }
        throw DMXError("selftest_failed", "cannot listen on 127.0.0.1: \(String(cString: strerror(errno)))")
    }
    let response = Data("HTTP/1.0 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
    Thread.detachNewThread {
        defer { close(fd) }
        var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, 30_000) == 1 else { return }
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var request = [UInt8](repeating: 0, count: 4096)
        _ = read(client, &request, request.count)
        var sent = 0
        response.withUnsafeBytes { bytes in
            while sent < bytes.count {
                let n = write(client, bytes.baseAddress! + sent, bytes.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }
    return UInt16(bigEndian: address.sin_port)
}

func milliseconds(_ d: Duration) -> Int {
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
