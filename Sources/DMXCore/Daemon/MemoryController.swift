import Foundation

/// The daemon's memory policy for the running VM. Free page reporting already hands back what
/// the guest frees, within about 2 s; this decides when the guest should free more.
///
/// - Idle: 30 s after the last exec started or ended, with the guest's CPU nearly idle all along,
///   the guest reclaims its clean page cache down to 16 MB (`memory.reclaim`, file pages only), so
///   the cache of a build or a big read is not charged to the Mac until the VM stops. Once per
///   idle spell: the reclaim takes the file pages of running programs too (dockerd and containerd
///   fault ~40 MB back within seconds), so trimming again whenever the cache regrew read them back
///   from disk every few seconds: 1.0–1.2 % of a core with dockerd idle, 0.8 % trimming once.
/// - Idle sweep, at the same moment: free page reporting goes down from 512 KB blocks to the
///   Mac's page size, and the slab caches free their empty slabs. Bursts of connections, processes or
///   small files leave tens of MB free in blocks under 512 KB, which reporting skips (and
///   compaction does not merge); this hands them back within seconds. Once the guest is in use
///   again, reporting goes back to 512 KB blocks, so a busy guest does not hand back, and fault in
///   again, single pages it keeps reusing.
/// - Host pressure warning: the same trim at once, and after 5 s of idle instead of 30.
/// - Host pressure critical: the guest also pushes cold anonymous and tmpfs pages into zram, and the
///   hotplug policy removes spare memory with 256 MB headroom, following its use as it changes.
///   The balloon covers boot memory and blocks that cannot be unplugged. Back at warning
///   the cap loosens to 1 GB (macOS often swings between the two, and inflating again costs CPU:
///   the guest zeroes every page it hands over, ~1.5 s of CPU per 8 GB); back at normal the balloon
///   deflates. With DEFLATE_ON_OOM the guest takes balloon pages back rather than OOM-kill, so a
///   busy guest is slowed, not broken.
/// - zram swap (lz4, a quarter of the ceiling) is turned on the first time the guest is squeezed
///   or uses more than half its ceiling, not at boot: its per-page metadata costs memory idle.
@MainActor
final class MemoryController {
    enum Pressure: String, Codable, Sendable, Comparable {
        case normal, warning, critical
        static func < (a: Pressure, b: Pressure) -> Bool { a.rank < b.rank }
        private var rank: Int { self == .normal ? 0 : self == .warning ? 1 : 2 }
    }

    static let idleTrimAfter: Duration = .seconds(30)
    static let idleTrimAfterUnderPressure: Duration = .seconds(5)
    /// The guest counts as idle below this share of one CPU (the daemon's CPU time includes the
    /// vCPU threads; an idle 10 vCPU guest uses about 0.1 %).
    static let idleCPU = 0.05
    /// Clean cache the guest keeps when trimmed (the hottest, by its LRU), and how much more it
    /// must have before a trim is worth a call.
    static let keepCache: UInt64 = 16 << 20
    static let trimSlack: UInt64 = 32 << 20
    /// Free memory the balloon leaves the guest beyond what it uses, under critical pressure and
    /// at warning after it, and how far the target must move before the guest is asked again.
    static let criticalHeadroom: UInt64 = 256 << 20
    static let warningHeadroom: UInt64 = 1 << 30
    static let balloonStep: UInt64 = 64 << 20
    /// How long after a sweep the guest's CPU (shrinking slabs, then reporting what was freed
    /// 2 s later) does not count as use. Otherwise the sweep would end itself, and repeat.
    static let sweepSettle: Duration = .seconds(10)

    private var source: DispatchSourceMemoryPressure?
    private var hostPressure: Pressure
    private var simulated: Pressure?
    /// The level the policy acted on last.
    private var level = Pressure.normal

    private var machine: Machine?
    private var agent: AgentClient?
    private var loop: Task<Void, Never>?
    private var nap: Task<Void, Never>?
    private var lastActivity = ContinuousClock.now
    private var trims = 0
    private var swapOn = false
    /// Keep the reduced headroom at warning after critical even when unplugging needed no balloon.
    private var squeezed = false
    private var lastTrim: (reason: String, at: ContinuousClock.Instant, freedMb: Int, ms: Int)?
    /// Set by an idle sweep until the guest is used again: when, and the reporting order to go
    /// back to (nil if the guest did not take the change).
    private var swept: (at: ContinuousClock.Instant, restore: Int?)?
    private var sweeps = 0
    /// When the guest was last trimmed for being idle; again only after it is used.
    private var idleTrimmed: ContinuousClock.Instant?

    var pressure: Pressure { simulated ?? hostPressure }

    init() {
        hostPressure = Self.readHostPressure()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [unowned self] in
            MainActor.assumeIsolated {
                let event = source.data
                hostPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
                wake()
            }
        }
        source.resume()
        self.source = source
    }

    /// Starts the policy for a VM whose agent answers.
    func attach(machine: Machine, agent: AgentClient) {
        detach()
        self.machine = machine
        self.agent = agent
        level = .normal
        swapOn = false
        squeezed = false
        trims = 0
        lastTrim = nil
        swept = nil
        sweeps = 0
        idleTrimmed = nil
        lastActivity = .now
        loop = Task { await run(machine: machine, agent: agent) }
    }

    /// The VM stopped or is stopping.
    func detach() {
        loop?.cancel()
        nap?.cancel()
        loop = nil
        machine = nil
        agent = nil
    }

    /// An exec or a forwarded connection started or ended: the guest is in use.
    func noteActivity() { lastActivity = .now }

    /// Acts as if the host's pressure were `level` (nil: the real level again). For tests.
    func simulate(_ level: Pressure?) {
        simulated = level
        log("memory: pressure \(level.map { "simulated as \($0.rawValue)" } ?? "follows the host again")")
        wake()
    }

    func status(guest: GuestMemory?) -> MemoryStatus {
        let balloon = machine?.balloonSize
        return MemoryStatus(
            hostPressure: pressure.rawValue, pressureSimulated: simulated != nil,
            balloonMb: balloon.map { Int($0.actual >> 20) }, balloonTargetMb: balloon.map { Int($0.target >> 20) },
            plug: machine?.memoryPlugState.map(MemoryPlugReport.init),
            guestPageSize: machine.map { Int($0.guestPageSize) },
            guestCacheMb: guest.map { Int($0.cache >> 20) },
            guestSwapMb: guest.map { Int(($0.swapTotal - min($0.swapFree, $0.swapTotal)) >> 20) },
            reportedMb: machine.map { Int($0.freePageReports.bytes >> 20) },
            trims: trims, sweeps: sweeps,
            lastTrim: lastTrim.map {
                TrimRecord(reason: $0.reason, secondsAgo: Int((ContinuousClock.now - $0.at).components.seconds),
                           freedMb: $0.freedMb, ms: $0.ms)
            })
    }

    // MARK: Policy

    private func wake() { nap?.cancel() }

    private func run(machine: Machine, agent: AgentClient) async {
        var cpuMark = (cpu: processCPUSeconds(), at: ContinuousClock.now)
        while !Task.isCancelled {
            let interval: Duration = pressure == .normal ? .seconds(5) : .seconds(2)
            let nap = Task { _ = try? await Task.sleep(for: interval) }
            self.nap = nap
            await nap.value
            guard !Task.isCancelled, let stats = try? await agent.stats(), !Task.isCancelled else { continue }
            let cpu = processCPUSeconds(), now = ContinuousClock.now
            let busy = (cpu - cpuMark.cpu) / max(seconds(now - cpuMark.at), 0.001)
            cpuMark = (cpu, now)
            await tick(stats.memory, quiet: busy < Self.idleCPU, machine: machine, agent: agent)
        }
    }

    private func tick(_ memory: GuestMemory, quiet: Bool, machine: Machine, agent: AgentClient) async {
        // A busy guest is in use, exec or not; but not for the sweep's own work just after it.
        if !quiet, swept.map({ ContinuousClock.now - $0.at >= Self.sweepSettle }) ?? true { lastActivity = .now }
        hostPressure = Self.readHostPressure()
        let current = pressure
        let rising = current > level
        if current != level {
            log("memory: host pressure \(current.rawValue)\(simulated != nil ? " (simulated)" : "")")
            level = current
        }

        // Half the ceiling, not of MemTotal: with virtio-mem that is what is plugged, which grows with use.
        if !swapOn, current == .critical || memory.used > machine.spec.maxMemory / 2 {
            do {
                let size = try await agent.swapOn()
                swapOn = true
                log("memory: zram swap on, \(size >> 20) MB (guest uses \(memory.used >> 20) MB, pressure \(current.rawValue))")
            } catch {
                swapOn = true  // not again for this VM: the guest may simply have no zram
                log("memory: zram swap not turned on: \((error as? DMXError)?.message ?? "\(error)")")
            }
        }

        let after = current == .normal ? Self.idleTrimAfter : Self.idleTrimAfterUnderPressure
        let idle = ContinuousClock.now - lastActivity >= after
        if rising && current == .critical {
            // Everything the guest can give: file cache, and cold anonymous and tmpfs pages into zram.
            await trim(agent, bytes: memory.cache + memory.used / 2, swappiness: nil, reason: "host pressure critical")
        } else if rising {
            await trim(agent, bytes: trimmable(memory), swappiness: 0, reason: "host pressure \(current.rawValue)")
        } else if idle, idleTrimmed.map({ lastActivity > $0 }) ?? true, memory.cache > Self.keepCache + Self.trimSlack {
            await trim(agent, bytes: trimmable(memory), swappiness: 0, reason: "idle")
            idleTrimmed = .now
        }

        if idle, swept == nil {
            await sweep(agent)
        } else if let swept, lastActivity > swept.at {
            self.swept = nil
            if let order = swept.restore { await setReportingOrder(agent, order, reason: "in use") }
        }

        // Reduce present memory first; balloon pages would obstruct unplugging. Without a
        // hotplug device (small ceilings), keep the balloon-only fallback.
        if current == .critical { squeezed = true }
        if current == .normal { squeezed = false }
        let now = machine.balloonSize.target
        let headroom: UInt64? = switch current {
        case .critical: Self.criticalHeadroom
        case .warning where squeezed: Self.warningHeadroom
        default: nil
        }
        if machine.setMemoryPressureHeadroom(headroom) { return }
        let target = headroom.map { memory.total > memory.used + $0 ? memory.total - memory.used - $0 : 0 } ?? 0
        let delta = target > now ? target - now : now - target
        if delta >= Self.balloonStep || (target == 0 && now != 0) {
            machine.setBalloonTarget(target)
            log("memory: balloon target \(target >> 20) MB (guest uses \(memory.used >> 20) MB, pressure \(current.rawValue))")
        }
    }

    private func trimmable(_ memory: GuestMemory) -> UInt64 {
        memory.cache > Self.keepCache ? memory.cache - Self.keepCache : 0
    }

    private func trim(_ agent: AgentClient, bytes: UInt64, swappiness: Int?, reason: String) async {
        guard bytes > 0 else { return }
        let started = ContinuousClock.now
        do {
            let result = try await agent.reclaim(bytes: bytes, swappiness: swappiness)
            let ms = Int(seconds(ContinuousClock.now - started) * 1000)
            let freed = Int((result.freeAfter > result.freeBefore ? result.freeAfter - result.freeBefore : 0) >> 20)
            trims += 1
            lastTrim = (reason, .now, freed, ms)
            log("memory: guest reclaimed \(freed) MB in \(ms) ms (\(reason), asked \(bytes >> 20) MB\(swappiness == 0 ? " of cache" : ""))")
        } catch {
            log("memory: reclaim failed (\(reason)): \((error as? DMXError)?.message ?? "\(error)")")
        }
    }

    /// Hands back what the guest freed in blocks too small for free page reporting (see the type's
    /// comment). Reporting runs about 2 s after the next free, which the slab shrink provides.
    private func sweep(_ agent: AgentClient) async {
        let started = ContinuousClock.now
        // A host page can only be released when the whole range is free: reporting individual
        // 4K guest pages on a 16K Mac cannot return them, so do not spend CPU reporting them.
        let order = Machine.reportingOrder(pageSize: machine?.guestPageSize ?? 4096, blockSize: UInt64(getpagesize()))
        let previous = await setReportingOrder(agent, order, reason: "idle")
        swept = (.now, previous)
        do {
            let slabs = try await agent.shrinkSlabs()
            let ms = Int(seconds(ContinuousClock.now - started) * 1000)
            let freed = Int((slabs.freeAfter > slabs.freeBefore ? slabs.freeAfter - slabs.freeBefore : 0) >> 20)
            sweeps += 1
            log("memory: idle sweep in \(ms) ms, empty slabs freed \(freed) MB")
        } catch {
            log("memory: shrinking slabs failed: \((error as? DMXError)?.message ?? "\(error)")")
        }
    }

    /// Returns the order it replaced, nil if the guest refused.
    @discardableResult
    private func setReportingOrder(_ agent: AgentClient, _ order: Int, reason: String) async -> Int? {
        do {
            let previous = try await agent.setReportingOrder(order)
            log("memory: free page reporting from \(((machine?.guestPageSize ?? 4096) << order) >> 10) KB blocks (\(reason))")
            return previous
        } catch {
            log("memory: free page reporting order not changed (\(reason)): \((error as? DMXError)?.message ?? "\(error)")")
            return nil
        }
    }

    static func readHostPressure() -> Pressure {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return .normal }
        return value >= 4 ? .critical : value >= 2 ? .warning : .normal
    }
}

/// What the memory controller does, in `dmx status`.
public struct MemoryStatus: Codable, Sendable {
    /// `normal`, `warning` or `critical`: macOS's memory pressure level, as the policy sees it.
    public let hostPressure: String
    /// True while a test overrides the level (daemon method `simulate_pressure`).
    public let pressureSimulated: Bool
    /// The balloon: what the guest gave back on request, and what was asked. nil while stopped.
    public let balloonMb: Int?
    public let balloonTargetMb: Int?
    /// Boot RAM, hotplug region requested/present, and request counts. nil without virtio-mem.
    public let plug: MemoryPlugReport?
    /// Linux base page size in bytes, read from its Image header. Absent on older daemons.
    public let guestPageSize: Int?
    /// Clean page cache the guest holds, and swap (zram) in use.
    public let guestCacheMb: Int?
    public let guestSwapMb: Int?
    /// Returned by free page reporting since the VM booted.
    public let reportedMb: Int?
    public let trims: Int
    /// Idle sweeps since the VM booted: free page reporting from 16 KB blocks, empty slabs freed.
    /// Optional so a CLI can read the status of a daemon from before sweeps.
    public let sweeps: Int?
    public let lastTrim: TrimRecord?
}

public struct TrimRecord: Codable, Sendable {
    /// `idle`, `host pressure warning` or `host pressure critical`.
    public let reason: String
    public let secondsAgo: Int
    /// How much more the guest had available afterwards.
    public let freedMb: Int
    public let ms: Int
}

/// CPU time of this process, in seconds. The vCPU threads run the guest, so it includes the guest's.
private func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(usage.ru_utime) + s(usage.ru_stime)
}
