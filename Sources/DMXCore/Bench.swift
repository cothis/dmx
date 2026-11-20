import Darwin
import Foundation

/// `dmx bench`: the comparison people can run on their own Mac. For each engine, one at a time,
/// it measures the host memory charged to the engine (`ri_phys_footprint`, guest RAM included)
/// while idle, warm `docker run --rm` times, and memory over time while a container writes 2 GiB
/// into its tmpfs and frees it. The method is docs/benchmark.md's protocol; scripts/benchmark.py
/// stays for the full release comparison (CPU-bound work, a fresh VM with fixed settings).
public enum Bench {
    /// One engine to measure. dmx's process is found from its status; any other engine names the
    /// processes its memory is charged to, because nothing in the Docker API says which they are.
    public struct EngineSpec: Sendable, Equatable {
        public let name: String
        public let socket: URL
        public let pids: [Int32]

        /// `NAME=unix:///path/to/docker.sock,PID[,PID...]`.
        public init(parsing text: String) throws {
            let hint = "write --engine NAME=unix:///path/to/docker.sock,PID[,PID...]; see docs/benchmark.md#dmx-bench for each engine's processes"
            guard let eq = text.firstIndex(of: "="), eq != text.startIndex else {
                throw DMXError("bad_engine_spec", "cannot read \"\(text)\" as NAME=SOCKET,PID...", hint: hint)
            }
            let name = String(text[..<eq])
            let parts = text[text.index(after: eq)...].split(separator: ",").map(String.init)
            guard name.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }), name.lowercased() != "dmx" else {
                throw DMXError("bad_engine_spec", "\"\(name)\" cannot name another engine (letters, digits, - _ . only, and not dmx)", hint: hint)
            }
            guard let uri = parts.first, uri.hasPrefix("unix:///") else {
                throw DMXError("bad_engine_spec", "\(name)'s socket must be a unix:/// URI", hint: hint)
            }
            let pids = parts.dropFirst().compactMap { Int32($0) }.filter { $0 > 0 }
            guard !pids.isEmpty, pids.count == parts.count - 1 else {
                throw DMXError("bad_engine_spec", "\(name) needs the PIDs its VM and helpers run as", hint: hint)
            }
            self.init(name: name, socket: URL(fileURLWithPath: String(uri.dropFirst("unix://".count))), pids: pids)
        }

        public init(name: String, socket: URL, pids: [Int32]) {
            self.name = name
            self.socket = socket
            self.pids = Array(Set(pids)).sorted()
        }
    }

    public struct Options: Sendable {
        public var engines: [EngineSpec] = []
        /// Seconds after the pull at which idle memory is read; the last one is the steady state.
        public var idleSamples: [Int] = [35, 50, 65, 80, 95]
        public var runs = 5
        /// How long memory is followed after the container frees its 2 GiB.
        public var followSeconds = 30.0
        public init() {}
    }

    public struct Process: Encodable, Sendable {
        public let pid: Int32
        public let command: String
        public let footprintMb: Double
    }

    public struct Sample: Encodable, Sendable {
        public let atS: Double
        public let footprintMb: Double
    }

    public struct Idle: Encodable, Sendable {
        public let samples: [Sample]
        /// The last reading, after dmx's idle trim has come and gone.
        public let steadyMb: Double
        public let minMb: Double
        public let cpuPercentOfOneCore: Double
    }

    public struct Runs: Encodable, Sendable {
        public let samplesMs: [Double]
        public let medianMs: Double
    }

    public struct TakeAndFree: Encodable, Sendable {
        public let baselineMb: Double
        public let holdingMb: Double
        public let peakMb: Double
        /// Footprint 10 s after the container freed the memory, the README's "after" column.
        public let afterTenSecondsMb: Double
        public let afterEndMb: Double
        /// Seconds until the footprint was back within 64 MB of the baseline; nil if it never was.
        public let backToBaselineS: Double?
        /// Every 100 ms; `at_s` is relative to the moment the container freed the 2 GiB.
        public let timeline: [Sample]
    }

    public struct EngineReport: Encodable, Sendable {
        public var name: String
        public var socket: String
        public var ok = false
        public var serverVersion: String?
        public var cpus: Int?
        /// RAM the guest kernel has now (Docker's MemTotal). dmx plugs RAM in as the guest needs
        /// it, so for dmx this is less than its ceiling.
        public var memoryMb: Int?
        /// dmx's configured memory ceiling; nil for other engines, whose MemTotal is their VM size.
        public var memoryCeiling: String?
        public var containersRunning: Int?
        public var processes: [Process] = []
        public var idle: Idle?
        public var runTrue: Runs?
        public var takeAndFree: TakeAndFree?
        public var error: DMXError?
    }

    public struct Host: Encodable, Sendable {
        public let macos: String
        public let cores: Int
        public let memoryGb: Int
        public let loadStart: Double
        public var loadEnd: Double = 0
    }

    public struct Report: Encodable, Sendable {
        public var ok = false
        public let dmxVersion = DMXCore.dmxVersion
        public let at: String
        public var host: Host
        public let image: String
        public let method = "https://github.com/cothis/dmx/blob/main/docs/benchmark.md#dmx-bench"
        public var engines: [EngineReport] = []
        public var warnings: [String] = []
    }

    /// The image of the comparison protocol, pinned by digest (scripts/image-matrix.json).
    public static let image = "library/alpine@sha256:e311ae748be7f56ae5cba304bc488f0786df68ee507513f654a5cc8597cffb42"

    public static func run(paths: Paths, options: Options, progress: @escaping @Sendable (String) -> Void) async throws -> Report {
        let docker = paths.dockerBin.appendingPathComponent("docker")
        guard FileManager.default.isExecutableFile(atPath: docker.path) else {
            throw DMXError("docker_tools_missing", "dmx bench drives engines with dmx's docker CLI, which is not installed",
                           hint: "run `dmx tools install`, then `dmx bench` again")
        }
        let dmxSocket = canonical(paths.dockerSocket)
        var seen = Set<String>()
        for engine in options.engines {
            guard seen.insert(engine.name.lowercased()).inserted else {
                throw DMXError("bad_engine_spec", "\(engine.name) is named twice", hint: "give each --engine its own name")
            }
            if canonical(engine.socket) == dmxSocket {
                throw DMXError("bad_engine_spec", "\(engine.socket.path) is dmx's own socket, not \(engine.name)'s",
                               hint: "dmx is always measured; point --engine at the other engine's socket (docs/benchmark.md#dmx-bench)")
            }
            for pid in engine.pids where footprint(pid) == nil {
                throw DMXError("bad_engine_spec", "\(engine.name): no process \(pid) of this user to measure",
                               hint: "list the engine's processes with `ps -axo pid,comm`; see docs/benchmark.md#dmx-bench")
            }
        }
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("dmx-bench-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: config) }

        var report = Report(at: ISO8601DateFormatter().string(from: Date()),
                            host: Host(macos: ProcessInfo.processInfo.operatingSystemVersionString,
                                       cores: ProcessInfo.processInfo.activeProcessorCount,
                                       memoryGb: Int(ProcessInfo.processInfo.physicalMemory >> 30), loadStart: loadAverage()),
                            image: image)

        // The idle window lasts 105 s; a shorter idle timeout stops dmx's VM inside it.
        if let config = try? Config.load(paths), config.idleTimeoutSeconds > 0, config.idleTimeoutSeconds < 110 {
            let warning = "dmx's idle_timeout is \(config.idleTimeoutSeconds) s, inside the 105 s idle window: the idle numbers are of a stopped VM; "
                + "`dmx config set idle_timeout 5m` for the measurement"
            report.warnings.append(warning)
            progress(warning)
        }
        // dmx first. Its daemon is the one process its VM is charged to; asking starts it.
        var dmx = EngineReport(name: "dmx", socket: paths.dockerSocket.path)
        do {
            guard let client = try await DaemonClient.connect(paths: paths, start: true) else {
                throw DMXError("daemon_unreachable", "dmx's daemon did not start", hint: "run `dmx doctor`")
            }
            let pid = client.hello.pid
            dmx.memoryCeiling = try? await client.status(timeout: .seconds(10)).maxMemory ?? Config.load(paths).memory
            client.close()
            let cli = DockerCLI(docker: docker, socket: paths.dockerSocket, config: config)
            dmx = await measure(dmx, cli: cli, pids: [pid], options: options, progress: progress)
        } catch {
            dmx.error = asDMXError(error)
        }
        report.engines.append(dmx)
        for engine in options.engines {
            let cli = DockerCLI(docker: docker, socket: engine.socket, config: config)
            report.engines.append(await measure(EngineReport(name: engine.name, socket: engine.socket.path),
                                                cli: cli, pids: engine.pids, options: options, progress: progress))
        }
        report.host.loadEnd = loadAverage()
        report.ok = report.engines.allSatisfy(\.ok)
        return report
    }

    static func measure(_ start: EngineReport, cli: DockerCLI, pids: [Int32], options: Options,
                        progress: @escaping @Sendable (String) -> Void) async -> EngineReport {
        var r = start
        let name = r.name
        // Its own name: the cleanup removes by name, and must never meet someone else's container.
        let container = "dmx-bench-\(getpid())-\(UUID().uuidString.prefix(8).lowercased())-\(name)"
        do {
            progress("\(name): asking the engine")
            let info = try JSONDecoder().decode(JSONValue.self, from: Data(try await cli.run(["info", "--format", "{{json .}}"], timeout: 180).utf8))
            r.serverVersion = info["ServerVersion"]?.string
            r.cpus = info["NCPU"]?.int
            r.memoryMb = info["MemTotal"]?.int.map { $0 >> 20 }
            r.containersRunning = info["ContainersRunning"]?.int
            if let running = r.containersRunning, running > 0 {
                progress("\(name): \(running) container(s) already running; their memory is in every number")
            }
            progress("\(name): pulling \(image)")
            _ = try await cli.run(["pull", "--quiet", "--platform", "linux/arm64", image], timeout: 600)
            r.processes = pids.map { pid in Process(pid: pid, command: command(pid), footprintMb: footprint(pid)?.mb ?? 0) }

            // Idle: a whole window, not one reading. dmx trims an idle guest 30 s after the last
            // activity, and dockerd reads some files back afterwards (docs/benchmark.md, protocol 3).
            let settled = ContinuousClock.now
            var samples: [Sample] = []
            for at in options.idleSamples {
                try await Task.sleep(until: settled + .seconds(at))
                let mb = try total(pids)
                samples.append(Sample(atS: Double(at), footprintMb: mb))
                progress("\(name): idle at \(at) s: \(Int(mb)) MB")
            }
            let cpuStart = try cpuSeconds(pids), cpuAt = ContinuousClock.now
            try await Task.sleep(for: .seconds(10))
            let cpu = 100 * (try cpuSeconds(pids) - cpuStart) / seconds(ContinuousClock.now - cpuAt)
            r.idle = Idle(samples: samples, steadyMb: samples.last?.footprintMb ?? 0,
                          minMb: samples.map(\.footprintMb).min() ?? 0, cpuPercentOfOneCore: (cpu * 100).rounded() / 100)

            var times: [Double] = []
            for _ in 0..<options.runs {
                // As scripts/benchmark.py: `docker run` is timed, the removal after it is not.
                let t = ContinuousClock.now
                _ = try await cli.run(["run", "--pull", "never", "--platform", "linux/arm64", "--network", "none",
                                       "--name", container, "--label", "dmx.bench=\(container)", image, "true"], timeout: 120)
                times.append((seconds(ContinuousClock.now - t) * 100_000).rounded() / 100)
                _ = try await cli.run(["rm", "-fv", container], timeout: 60)
            }
            r.runTrue = Runs(samplesMs: times, medianMs: median(times))
            progress("\(name): docker run alpine true, median \(Int(median(times))) ms")

            progress("\(name): a container takes 2 GiB and frees it")
            r.takeAndFree = try await takeAndFree(cli: cli, pids: pids, container: container, follow: options.followSeconds)
            if let t = r.takeAndFree {
                progress("\(name): \(Int(t.baselineMb)) MB before, \(Int(t.holdingMb)) MB holding, \(Int(t.afterTenSecondsMb)) MB 10 s after freeing")
            }
            r.ok = true
        } catch {
            r.error = asDMXError(error)
            progress("\(name): \(r.error!.message)")
        }
        // What this run made and an error left behind, found by its label: a container that took
        // the name meanwhile is not this run's.
        if let ids = try? await cli.run(["ps", "-aq", "--filter", "label=dmx.bench=\(container)"], timeout: 30) {
            for id in ids.split(separator: "\n") where !id.isEmpty { _ = try? await cli.run(["rm", "-fv", String(id)], timeout: 60) }
        }
        return r
    }

    static func takeAndFree(cli: DockerCLI, pids: [Int32], container: String, follow: Double) async throws -> TakeAndFree {
        let sampler = Sampler(pids: pids)
        sampler.start()
        defer { sampler.stop() }
        try await Task.sleep(for: .seconds(3))
        let baseline = try total(pids)
        _ = try await cli.run(["run", "-d", "--pull", "never", "--platform", "linux/arm64", "--name", container, "--label", "dmx.bench=\(container)",
                               "--network", "none", "--memory", "3g", "--cpus", "2", "--pids-limit", "256",
                               "--tmpfs", "/data:size=3g", image, "sh", "-c",
                               "dd if=/dev/zero of=/data/big bs=1M count=2048 2>/dev/null && echo filled; "
                               + "while [ ! -e /tmp/release ]; do sleep 0.1; done; rm /data/big; echo freed"], timeout: 120)
        let deadline = ContinuousClock.now + .seconds(90)
        while try await !cli.run(["logs", container], timeout: 30).contains("filled") {
            guard ContinuousClock.now < deadline else {
                throw DMXError("bench_failed", "the container did not write its 2 GiB within 90 s", hint: "run `docker logs \(container)`")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(3))
        let holding = try total(pids)
        _ = try await cli.run(["exec", container, "touch", "/tmp/release"], timeout: 60)
        guard try await cli.run(["wait", container], timeout: 60).trimmingCharacters(in: .whitespacesAndNewlines) == "0" else {
            throw DMXError("bench_failed", "the container failed to free its memory", hint: "run `docker logs \(container)`")
        }
        let freedAt = sampler.elapsed()
        _ = try await cli.run(["rm", "-fv", container], timeout: 60)
        try await Task.sleep(for: .seconds(follow))
        sampler.stop()
        let points = sampler.points.map { Sample(atS: (($0.at - freedAt) * 10).rounded() / 10, footprintMb: $0.mb) }
        let after = points.filter { $0.atS >= 0 }
        return TakeAndFree(baselineMb: baseline, holdingMb: holding, peakMb: points.map(\.footprintMb).max() ?? holding,
                           afterTenSecondsMb: after.first { $0.atS >= 10 }?.footprintMb ?? after.last?.footprintMb ?? holding,
                           afterEndMb: after.last?.footprintMb ?? holding,
                           backToBaselineS: after.first { $0.footprintMb <= baseline + 64 }?.atS,
                           timeline: points)
    }

    // MARK: - Reading the host

    struct Usage { let mb: Double; let cpuS: Double }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// `ri_phys_footprint` and CPU time of a process of this user; CPU time is in Mach ticks.
    static func footprint(_ pid: Int32) -> Usage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        let ticks = Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom)
        return Usage(mb: (Double(info.ri_phys_footprint) / 1_048_576 * 100).rounded() / 100, cpuS: ticks / 1e9)
    }

    static func total(_ pids: [Int32]) throws -> Double {
        try pids.reduce(0) { sum, pid in
            guard let u = footprint(pid) else {
                throw DMXError("bench_process_gone", "process \(pid) exited while it was being measured",
                               hint: "the engine restarted or stopped; run `dmx bench` again once it is up")
            }
            return sum + u.mb
        }
    }

    static func cpuSeconds(_ pids: [Int32]) throws -> Double {
        try pids.reduce(0) { sum, pid in
            guard let u = footprint(pid) else { throw DMXError("bench_process_gone", "process \(pid) exited while it was being measured", hint: "the engine restarted or stopped; run `dmx bench` again once it is up") }
            return sum + u.cpuS
        }
    }

    /// A socket path with every link followed, also when the last one points at nothing yet
    /// (`dmx install` links Docker Desktop's path to dmx's socket, which exists only while dmx runs),
    /// and its directory in its real form (/var is /private/var).
    static func canonical(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        for _ in 0..<16 {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { break }
            path = target.hasPrefix("/") ? target : URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(target).path
            path = URL(fileURLWithPath: path).standardizedFileURL.path
        }
        let file = URL(fileURLWithPath: path)
        guard let real = realpath(file.deletingLastPathComponent().path, nil) else { return path }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real)).appendingPathComponent(file.lastPathComponent).path
    }

    static func command(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "?" }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }

    static func loadAverage() -> Double {
        var load = [Double](repeating: 0, count: 3)
        return getloadavg(&load, 3) > 0 ? (load[0] * 100).rounded() / 100 : 0
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    static func asDMXError(_ error: Error) -> DMXError {
        (error as? DMXError) ?? DMXError("bench_failed", "\(error)", hint: "run `dmx doctor`, then `dmx bench` again")
    }

    /// Reads the engine's footprint every 100 ms on its own thread, so docker commands do not
    /// delay the samples.
    final class Sampler: @unchecked Sendable {
        let pids: [Int32]
        private let lock = NSLock()
        private var _points: [(at: Double, mb: Double)] = []
        private var running = false
        private let started = ContinuousClock.now
        private var thread: Thread?

        init(pids: [Int32]) { self.pids = pids }

        var points: [(at: Double, mb: Double)] { lock.withLock { _points } }

        func elapsed() -> Double { Bench.seconds(ContinuousClock.now - started) }

        func start() {
            lock.withLock { running = true }
            let t = Thread { [self] in
                while lock.withLock({ running }) {
                    if let mb = try? Bench.total(pids) {
                        let at = elapsed()
                        lock.withLock { _points.append((at, mb)) }
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            thread = t
            t.start()
        }

        func stop() { lock.withLock { running = false } }
    }
}

/// The docker CLI dmx installs, pointed at one engine, with an empty config of its own so the
/// user's credential helpers, contexts and plugins play no part.
struct DockerCLI: Sendable {
    let docker: URL
    let socket: URL
    let config: URL

    /// The CLI set up to talk to this engine only; not started.
    func process(_ args: [String]) -> Foundation.Process {
        let process = Foundation.Process()
        process.executableURL = docker
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["DOCKER_HOST"] = "unix://" + socket.path
        env["DOCKER_CONFIG"] = config.path
        env["DOCKER_CLI_HINTS"] = "false"
        env.removeValue(forKey: "DOCKER_CONTEXT")
        process.environment = env
        return process
    }

    func run(_ args: [String], timeout: Double) async throws -> String {
        let docker = docker, socket = socket
        let cli = self
        return try await onThread {
            let process = cli.process(args)
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch {
                throw DMXError("docker_failed", "cannot run \(docker.path): \(error.localizedDescription)", hint: "run `dmx tools install`")
            }
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.setEventHandler { process.terminate() }
            timer.schedule(deadline: .now() + timeout)
            timer.resume()
            // Read both pipes before waiting, so a full pipe cannot stall the process.
            let errData = LockedData()
            let errReader = Thread { errData.set(err.fileHandleForReading.readDataToEndOfFile()) }
            errReader.start()
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()
            while !errData.done { Thread.sleep(forTimeInterval: 0.01) }
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errData.value.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let killed = process.terminationReason == .uncaughtSignal
                throw DMXError(killed ? "docker_timeout" : "docker_failed",
                               "docker \(args.prefix(2).joined(separator: " ")) against \(socket.path) "
                               + (killed ? "did not finish within \(Int(timeout)) s" : "failed: \(message)"),
                               hint: "check the engine with `DOCKER_HOST=unix://\(socket.path) docker info`")
            }
            return String(decoding: outData, as: UTF8.self)
        }
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false
    func set(_ d: Data) { lock.withLock { data = d; finished = true } }
    var done: Bool { lock.withLock { finished } }
    var value: Data { lock.withLock { data } }
}
