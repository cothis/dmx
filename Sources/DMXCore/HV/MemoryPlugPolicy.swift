import Foundation

/// Decides how much of the ceiling the guest has plugged (`VirtioMem`), from the balloon's stats
/// queue: MemTotal and MemAvailable straight from the guest kernel, no agent involved, so it runs
/// the same under `dmx boot` and the daemon.
///
/// The guest keeps at least `headroom` available: plugged but free memory costs only its memmap
/// (4 MB per GB), since free page reporting hands its pages back. A burst faster than the poll
/// eats into the headroom while the host catches up, so the step adds what the guest would take
/// in `lookahead` at the rate it took memory since the last poll: plugging must happen before the
/// guest runs short, because adding memory needs memory (its memmap) and CPU time from a guest
/// that is then busy reclaiming. When more than `headroom + unplugSlack` stays available for
/// `unplugAfter`, the guest is asked to unplug down to `headroom` and gives back what it can free
/// (ZONE_MOVABLE: almost all of it).
///
/// The guest is asked when it ran: an idle guest sits in WFI and allocates nothing, so it is not
/// woken every tick, only every `maxQuiet`. Ran means the process's CPU time (the vCPU threads
/// run the guest) grew by `busyCPU` in one tick or in all ticks since the guest was last asked.
final class MemoryPlugPolicy: @unchecked Sendable {
    static let headroom: UInt64 = 1 << 30
    static let unplugSlack: UInt64 = 512 << 20
    static let unplugAfter: TimeInterval = 30
    static let lookahead = 0.5
    static let interval: DispatchTimeInterval = .milliseconds(100)
    static let maxQuiet: TimeInterval = 10
    /// CPU seconds that count as running: 1 % of a core within a tick, or 20 ms in all (an idle
    /// 10 vCPU guest uses ~1 ms per second, and zeroing 20 ms worth of pages is ~200 MB).
    static let busyCPU = (tick: 0.001, total: 0.02)

    // virtio_balloon.h stat tags
    private static let memTotal: UInt16 = 5, memAvailable: UInt16 = 6

    private let plug: VirtioMem
    private let balloon: VirtioBalloon
    private let boot: UInt64
    private let queue = DispatchQueue(label: "dmx.memory-plug", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var asked = (at: Date.distantPast, cpu: 0.0)
    private var cpuMark = processCPUTime()
    /// MemTotal - MemAvailable at the last answer, and when it came.
    private var last: (used: UInt64, at: Date)?
    private var excessSince: Date?

    init(plug: VirtioMem, balloon: VirtioBalloon, boot: UInt64) {
        self.plug = plug
        self.balloon = balloon
        self.boot = boot
        balloon.onStats = { [weak self] stats in
            guard let self else { return }
            queue.async { self.decide(stats) }
        }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        balloon.onStats = nil
    }

    private func tick() {
        let cpu = processCPUTime(), now = Date()
        let ran = cpu - cpuMark > Self.busyCPU.tick || cpu - asked.cpu > Self.busyCPU.total
        cpuMark = cpu
        guard ran || now.timeIntervalSince(asked.at) >= Self.maxQuiet else { return }
        if balloon.requestStats() { asked = (now, cpu) }
    }

    private func decide(_ stats: [UInt16: UInt64]) {
        guard var available = stats[Self.memAvailable], let total = stats[Self.memTotal] else { return }
        // Pages in the balloon count as allocated in the guest, but the host asked for them under
        // pressure and the guest takes them back before it OOM-kills (DEFLATE_ON_OOM). Plugging
        // more for them would let the balloon and the plug chase each other up to the ceiling.
        available += balloon.size.actual
        let state = plug.state
        let present = boot + state.plugged
        // Growth of what the guest uses, not the fall of MemAvailable: unplugging lowers that too.
        let used = total > available ? total - available : 0, now = Date()
        let rate = last.map { used > $0.used ? Double(used - $0.used) / max(now.timeIntervalSince($0.at), 0.05) : 0 } ?? 0
        last = (used, now)

        let enough = Self.headroom + UInt64(min(rate * Self.lookahead, 64e9))
        if available < enough {
            excessSince = nil
            let want = present + enough - available
            if want > boot + state.requested { plug.setRequested(want - boot) }
            return
        }
        guard available > Self.headroom + Self.unplugSlack, state.requested > 0 else { excessSince = nil; return }
        let since = excessSince ?? Date()
        excessSince = since
        guard Date().timeIntervalSince(since) >= Self.unplugAfter else { return }
        excessSince = nil
        let excess = available - Self.headroom
        let want = present > boot + excess ? present - excess - boot : 0
        // setRequested rounds up to whole memory blocks: the guest removes a block's memmap only
        // once all of it is unplugged.
        if want < state.requested { plug.setRequested(want) }
    }
}

/// CPU time of this process in seconds; the vCPU threads run the guest, so it includes the guest's.
private func processCPUTime() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(usage.ru_utime) + s(usage.ru_stime)
}
