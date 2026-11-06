import Foundation

/// When the guest clock needs setting again. The guest counts time with the virtual counter,
/// which on Apple silicon runs with `mach_absolute_time` and so stands still while the Mac
/// sleeps (a locked Mac sleeps soon after): the guest wakes up behind by however long the Mac
/// slept, and nothing in the guest knows better. Nor does it follow the host's clock when that
/// is set or slewed. So the daemon sets the guest clock at boot, as soon as it sees that the Mac
/// slept or its clock jumped, and once every `interval` for drift.
struct GuestClockWatch: Sendable {
    /// One reading of the host's clocks. `awake` stops during sleep (SuspendingClock, like the
    /// guest's counter), `elapsed` does not (ContinuousClock), `wall` is the time of day.
    struct Reading: Sendable {
        var awake: Double
        var elapsed: Double
        var wall: Double

        static var now: Reading {
            Reading(awake: seconds(SuspendingClock.now - suspendingOrigin),
                    elapsed: seconds(ContinuousClock.now - continuousOrigin),
                    wall: Date().timeIntervalSince1970)
        }
    }

    /// Regular resync period; one agent call, so cheap.
    static let interval = 60.0
    /// Offsets slewed rather than stepped: ntpd's step threshold.
    static let slewBelow = Duration.milliseconds(128)
    /// A measurement whose round trip took longer than this waited behind another call.
    static let trustedRoundTrip: Int64 = 100_000_000
    /// After a failed sync, requests do not wait for another one for this long; the 15 s check
    /// still tries.
    static let retryAfterFailure = Duration.seconds(15)
    /// A gap smaller than this between the clocks is measurement noise, not sleep or a step.
    static let tolerance = 1.0

    private(set) var last: Reading

    init(_ now: Reading = .now) { last = now }

    enum Reason: Equatable, Sendable {
        /// The Mac slept this many seconds since the last sync: the guest is that far behind.
        case slept(Double)
        /// The Mac's clock was set or slewed by more than the tolerance.
        case stepped(Double)
        case periodic

        /// Whether the guest clock is known to be off, which is worth a call before a request.
        /// After sleep the guest is behind by the time slept, so the change is a step either way.
        var known: Bool { self != .periodic }

        var description: String {
            switch self {
            case .slept(let s): "the Mac slept for \(Int(s.rounded())) s"
            case .stepped(let s): "the Mac's clock moved by \(Int(s.rounded())) s"
            case .periodic: "periodic"
            }
        }
    }

    /// Why the guest clock should be set now, or nil if it need not be.
    func due(_ now: Reading = .now) -> Reason? {
        let elapsed = now.elapsed - last.elapsed
        let slept = elapsed - (now.awake - last.awake)
        if slept > Self.tolerance { return .slept(slept) }
        let stepped = now.wall - last.wall - elapsed
        if abs(stepped) > Self.tolerance { return .stepped(stepped) }
        if elapsed >= Self.interval { return .periodic }
        return nil
    }

    mutating func synced(_ now: Reading = .now) { last = now }

    /// The offset (guest minus host, ns) to correct, from a measurement that read `arrival` =
    /// guest clock minus the host's send time, in a call taking `roundTrip`. The request spent
    /// between 0 and `roundTrip` on its way, so the true offset lies in [arrival - roundTrip,
    /// arrival]. A quick call is taken at its middle, as NTP does (off by at most 50 ms). A slow
    /// one, which waited behind another call, is corrected only by the end of that range nearest
    /// zero, so it never overcorrects, and nil if the range holds zero. `exact` is false then:
    /// the daemon measures again soon.
    static func estimate(arrival: Int64, roundTrip: Int64) -> (offset: Int64, exact: Bool)? {
        if roundTrip <= trustedRoundTrip { return (arrival - roundTrip / 2, true) }
        if arrival - roundTrip > 0 { return (arrival - roundTrip, false) }
        if arrival < 0 { return (arrival, false) }
        return nil
    }
}

private let suspendingOrigin = SuspendingClock.now
private let continuousOrigin = ContinuousClock.now
