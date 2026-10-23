import Foundation

public struct SelftestReport: Encodable, Sendable {
    public let ok: Bool
    /// Host clock from `vm.start()` until the guest init printed its first report line.
    public let bootMs: Int?
    public let cpus: Int
    public let maxMemory: String
    public let guest: [String: String]
    public let problems: [String]
    /// Raw console output, included only when the run failed.
    public let console: [String]?
}

/// Boots the guest with `dmx.selftest=1`; guest/init prints a report and powers off.
@MainActor
public func runSelftest(paths: Paths, spec: MachineSpec, timeout: Duration, echo: Bool) async throws -> SelftestReport {
    var spec = spec
    spec.kernelArgs += ["quiet", "dmx.selftest=1"]

    let capture = ConsoleCapture(echo: echo)
    let console = Console(fromGuest: capture.pipe.fileHandleForWriting)
    let machine = try Machine(spec: spec, paths: paths, console: console)

    let started = ContinuousClock.now
    capture.start(at: started)
    try await machine.start()

    let watchdog = Task { @MainActor () -> Bool in
        do { try await Task.sleep(for: timeout) } catch { return false }
        await machine.stop()
        return true
    }
    let exit = await machine.waitUntilStopped()
    watchdog.cancel()
    let timedOut = await watchdog.value

    let (lines, firstReport) = capture.finish()
    var guest: [String: String] = [:]
    var problems: [String] = []
    var inReport = false, sawEnd = false
    for line in lines {
        if line.contains("dmx-init:") { problems.append(line) }
        if line == "DMX-SELFTEST-BEGIN" { inReport = true; continue }
        if line == "DMX-SELFTEST-END" { sawEnd = true; break }
        guard inReport else { continue }
        var parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { continue }
        if parts[0] == "module" { parts[0] = "module." + parts.remove(at: 1) }
        let value = parts.dropFirst().joined(separator: " ")
        guest[parts[0]] = value
        if value.hasSuffix("missing") || value.hasSuffix("failed") { problems.append(line) }
    }
    if case .failed(let error) = exit { problems.append("\(error.code): \(error.message)") }
    if timedOut { problems.append("timed out after \(timeout)") }
    if !sawEnd { problems.append("guest never finished its report") }

    let ok = problems.isEmpty
    return SelftestReport(
        ok: ok,
        bootMs: firstReport.map { Int($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000) },
        cpus: machine.spec.cpus,
        maxMemory: formatSize(machine.spec.maxMemory),
        guest: guest,
        problems: problems,
        console: ok ? nil : lines
    )
}

/// Collects guest console output from a background reader.
private final class ConsoleCapture: @unchecked Sendable {
    let pipe = Pipe()
    private let echo: Bool
    private let lock = NSLock()
    private var data = Data()
    private var started: ContinuousClock.Instant?
    private var firstReport: Duration?

    init(echo: Bool) { self.echo = echo }

    func start(at instant: ContinuousClock.Instant) {
        started = instant
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            if self.echo { FileHandle.standardError.write(chunk) }
            self.lock.lock()
            self.data.append(chunk)
            if self.firstReport == nil, let started = self.started,
               self.data.range(of: Data("DMX-SELFTEST-BEGIN".utf8)) != nil {
                self.firstReport = ContinuousClock.now - started
            }
            self.lock.unlock()
        }
    }

    func finish() -> ([String], Duration?) {
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (lines, firstReport)
    }
}
