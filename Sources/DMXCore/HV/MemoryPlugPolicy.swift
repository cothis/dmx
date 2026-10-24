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
/// Under host pressure the daemon lowers the headroom and skips that delay. Unplugging comes
/// before inflating the balloon, which would pin pages the unplug needs to migrate. The balloon
/// covers boot memory and blocks the guest cannot unplug after `unplugStall` without progress.
///
/// The guest is asked when it ran: an idle guest sits in WFI and allocates nothing, so it is not
/// woken every tick, only every `maxQuiet`. Ran means the process's CPU time (the vCPU threads
/// run the guest) grew by `busyCPU` in one tick or in all ticks since the guest was last asked.
final class MemoryPlugPolicy: @unchecked Sendable {
    static let headroom: UInt64 = 1 << 30
    static let unplugSlack: UInt64 = 512 << 20
    /// At 4K the memmap costs 16 MB/GB: a burst can leave >64 MB behind even after every data
    /// page was returned. Five seconds of surplus plus the reporting delay fits the 10 s goal.
    static let unplugAfter: TimeInterval = 5
    static let lookahead = 0.5
    static let interval: DispatchTimeInterval = .milliseconds(100)
    static let maxQuiet: TimeInterval = 10
    static let pressurePoll: TimeInterval = 1
    static let unplugStall: TimeInterval = 5
    static let balloonStep: UInt64 = 64 << 20
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
    private var stopped = false
    private var asked = (at: Date.distantPast, cpu: 0.0)
    private var cpuMark = processCPUTime()
    /// MemTotal - MemAvailable at the last answer, and when it came.
    private var last: (used: UInt64, at: Date)?
    private var excessSince: Date?
    private var pressureHeadroom: UInt64?
    private var unplugProgress: (plugged: UInt64, requested: UInt64, at: Date)?
    private var lastPlugged: UInt64?

    init(plug: VirtioMem, balloon: VirtioBalloon, boot: UInt64) {
        self.plug = plug
        self.balloon = balloon
        self.boot = boot
        balloon.onStats = { [weak self] stats in
            guard let self else { return }
            queue.async { if !self.stopped { self.decide(stats) } }
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
        balloon.onStats = nil
        // A controller tick can finish after the VM stopped. Drain pending device work before
        // Machine destroys guest RAM, and reject any pressure/stat callbacks queued later.
        queue.sync {
            stopped = true
            timer?.cancel()
            timer = nil
        }
    }

    /// nil restores the normal policy. Calls and stats are serialized on the policy queue.
    func setPressureHeadroom(_ bytes: UInt64?) {
        queue.async {
            guard !self.stopped, bytes != self.pressureHeadroom else { return }
            self.pressureHeadroom = bytes
            self.excessSince = nil
            self.unplugProgress = nil
            // A balloon left from critical pressure must not obstruct migration at warning,
            // or keep the guest squeezed after normal pressure returns.
            self.setBalloon(0)
            if self.balloon.requestStats() { self.asked = (Date(), processCPUTime()) }
        }
    }

    private func tick() {
        guard !stopped else { return }
        let cpu = processCPUTime(), now = Date()
        let ran = cpu - cpuMark > Self.busyCPU.tick || cpu - asked.cpu > Self.busyCPU.total
        cpuMark = cpu
        // Do not sleep past the unplug deadline after a large free. A quiet guest otherwise
        // waits ten seconds for fresh stats, on top of the surplus timer.
        let maxQuiet = pressureHeadroom == nil && excessSince == nil ? Self.maxQuiet : Self.pressurePoll
        guard ran || now.timeIntervalSince(asked.at) >= maxQuiet else { return }
        if balloon.requestStats() { asked = (now, cpu) }
    }

    private func decide(_ stats: [UInt16: UInt64]) {
        guard var available = stats[Self.memAvailable], let total = stats[Self.memTotal] else { return }
        // Pages in the balloon count as allocated in the guest, but the host asked for them under
        // pressure and the guest takes them back before it OOM-kills (DEFLATE_ON_OOM). Plugging
        // more for them would let the balloon and the plug chase each other up to the ceiling.
        available += balloon.size.actual
        let state = plug.state
        let changed = lastPlugged != state.plugged
        lastPlugged = state.plugged
        let present = boot + state.plugged
        // Growth of what the guest uses, not the fall of MemAvailable: unplugging lowers that too.
        let used = total > available ? total - available : 0, now = Date()
        let rate = last.map { used > $0.used ? Double(used - $0.used) / max(now.timeIntervalSince($0.at), 0.05) : 0 } ?? 0
        last = (used, now)

        let headroom = pressureHeadroom ?? Self.headroom
        let enough = headroom + UInt64(min(rate * Self.lookahead, 64e9))
        if available < enough {
            excessSince = nil
            let want = present + enough - available
            if want > boot + state.requested { plug.setRequested(want - boot) }
        } else if pressureHeadroom != nil {
            excessSince = nil
            requestUnplug(present: present, excess: available - enough)
        } else if available > Self.headroom + Self.unplugSlack, state.requested > 0, state.plugged <= state.requested {
            let since = excessSince ?? now
            excessSince = since
            if now.timeIntervalSince(since) >= Self.unplugAfter {
                excessSince = nil
                requestUnplug(present: present, excess: available - Self.headroom)
            }
        } else {
            excessSince = nil
        }

        guard pressureHeadroom != nil else { unplugProgress = nil; return }
        let pending = plug.state
        // Stats may describe memory that was just removed. Wait for a fresh answer before
        // using its free count as a balloon target in the smaller guest.
        if changed || pending.plugged != state.plugged || pending.requested != state.requested {
            setBalloon(0)
            return
        }
        if pending.plugged > pending.requested {
            if unplugProgress?.plugged != pending.plugged || unplugProgress?.requested != pending.requested {
                unplugProgress = (pending.plugged, pending.requested, now)
            }
            // Give migration a chance before the balloon starts holding pages. If a pinned
            // block stalls, the balloon can still reclaim the rest; growth keeps working.
            if now.timeIntervalSince(unplugProgress!.at) < Self.unplugStall {
                setBalloon(0)
                return
            }
        } else {
            unplugProgress = nil
        }
        setBalloon(available > headroom ? available - headroom : 0)
    }

    private func requestUnplug(present: UInt64, excess: UInt64) {
        let want = present > boot + excess ? present - excess - boot : 0
        // Round up to whole Linux memory blocks so removing one returns its whole memmap.
        let before = plug.state.requested
        if want < before {
            plug.setRequested(want)
            if pressureHeadroom != nil, plug.state.requested != before {
                log("memory: virtio-mem target \((boot + plug.state.requested) >> 20) MB under host pressure")
            }
        }
    }

    private func setBalloon(_ bytes: UInt64) {
        let now = balloon.size.target
        let delta = bytes > now ? bytes - now : now - bytes
        guard delta >= Self.balloonStep || (bytes == 0 && now != 0) else { return }
        balloon.setTarget(bytes)
        log("memory: balloon target \(bytes >> 20) MB (virtio-mem pressure policy)")
    }
}

/// CPU time of this process in seconds; the vCPU threads run the guest, so it includes the guest's.
private func processCPUTime() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(usage.ru_utime) + s(usage.ru_stime)
}
