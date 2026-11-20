import ArgumentParser
import DMXCore
import Foundation

struct BenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Measure dmx, and any engine running beside it, the way the README's numbers were measured.",
        discussion: """
            For each engine in turn: host memory charged to it while idle (35 to 95 s after pulling a \
            pinned alpine), idle CPU, five warm `docker run alpine true`, and memory every 100 ms \
            while a container writes 2 GiB into its tmpfs and frees it. Takes about three minutes per \
            engine. dmx is always measured; another engine needs its socket and the processes its VM \
            runs as, for example --engine orbstack=unix://$HOME/.orbstack/run/docker.sock,1234 \
            (docs/benchmark.md#dmx-bench lists them). Quit other heavy apps first: the numbers are the Mac's too.
            """
    )
    @OptionGroup var global: GlobalOptions

    @Option(name: .customLong("engine"), help: "Another engine: NAME=unix:///path/docker.sock,PID[,PID...]. Repeat for more.")
    var engines: [String] = []

    @Option(help: "Also write the memory-over-time graph as SVG to this file.")
    var svg: String?

    @MainActor
    func run() async throws {
        let quiet = global.json
        try await report(global) {
            var options = Bench.Options()
            options.engines = try engines.map(Bench.EngineSpec.init(parsing:))
            let result = try await Bench.run(paths: Paths(), options: options, progress: { if !quiet { printProgress($0) } })
            if let svg {
                do {
                    try Bench.svg(result).write(to: URL(fileURLWithPath: svg), atomically: true, encoding: .utf8)
                } catch {
                    throw DMXError("write_failed", "cannot write \(svg): \(error.localizedDescription)", hint: "pass --svg a path in a directory you can write")
                }
            }
            return (result, describeBench(result, svg: svg), result.ok)
        }
    }
}

func describeBench(_ r: Bench.Report, svg: String?) -> String {
    func mb(_ v: Double?) -> String { v.map { "\(Int($0.rounded())) MB" } ?? "-" }
    let rows: [(String, (Bench.EngineReport) -> String)] = [
        ("Idle (steady, at 95 s)", { mb($0.idle?.steadyMb) }),
        ("Idle (lowest)", { mb($0.idle?.minMb) }),
        ("Idle CPU, one core", { $0.idle.map { String(format: "%.2f %%", $0.cpuPercentOfOneCore) } ?? "-" }),
        ("Holding 2 GiB", { mb($0.takeAndFree?.holdingMb) }),
        ("10 s after freeing it", { mb($0.takeAndFree?.afterTenSecondsMb) }),
        ("Back within 64 MB", { e in e.takeAndFree.map { t in t.backToBaselineS.map { String(format: "%.1f s", $0) } ?? "not within \(Int(t.timeline.last?.atS ?? 0)) s" } ?? "-" }),
        ("Warm docker run", { $0.runTrue.map { "\(Int($0.medianMs.rounded())) ms" } ?? "-" }),
    ]
    let width = 24, column = 16
    var lines = ["".padding(toLength: width, withPad: " ", startingAt: 0) + r.engines.map { $0.name.padding(toLength: column, withPad: " ", startingAt: 0) }.joined()]
    for (label, value) in rows {
        lines.append(label.padding(toLength: width, withPad: " ", startingAt: 0) + r.engines.map { value($0).padding(toLength: column, withPad: " ", startingAt: 0) }.joined())
    }
    for e in r.engines {
        let settings = [e.serverVersion.map { "dockerd \($0)" }, e.cpus.map { "\($0) CPUs" }, e.memoryMb.map { "\($0) MB" + (e.memoryCeiling.map { " now, \($0) ceiling" } ?? "") },
                        e.containersRunning.flatMap { $0 > 0 ? "\($0) containers already running" : nil }].compactMap { $0 }
        lines.append("\(e.name): " + settings.joined(separator: ", ") + "; processes " + e.processes.map { "\($0.command) (\($0.pid))" }.joined(separator: ", "))
        if let error = e.error { lines.append("\(e.name) failed: \(error.message)" + (error.hint.map { "\n  hint: \($0)" } ?? "")) }
    }
    for w in r.warnings { lines.append("warning: \(w)") }
    lines.append(String(format: "host load %.2f -> %.2f; method: %@", r.host.loadStart, r.host.loadEnd, r.method))
    if let svg { lines.append("graph: \(svg)") }
    return lines.joined(separator: "\n")
}
