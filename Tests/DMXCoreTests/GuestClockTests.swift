import Testing
@testable import DMXCore

@Suite struct GuestClockTests {
    typealias R = GuestClockWatch.Reading
    let start = R(awake: 100, elapsed: 100, wall: 1_800_000_000)

    @Test func nothingDueRightAfterASync() {
        let watch = GuestClockWatch(start)
        #expect(watch.due(R(awake: 130, elapsed: 130, wall: 1_800_000_030)) == nil)
    }

    @Test func periodicOnceAMinute() {
        let watch = GuestClockWatch(start)
        let later = R(awake: 160, elapsed: 160, wall: 1_800_000_060)
        #expect(watch.due(later) == .periodic)
        #expect(watch.due(later)?.known == false)
    }

    /// The Mac slept an hour: the awake clock, like the guest's counter, did not move then.
    @Test func sleepIsSeenAtOnce() {
        let watch = GuestClockWatch(start)
        let woke = R(awake: 110, elapsed: 3710, wall: 1_800_003_610)
        #expect(watch.due(woke) == .slept(3600))
        #expect(watch.due(woke)?.known == true)
    }

    @Test func hostClockStepsAreSeenBothWays() {
        let watch = GuestClockWatch(start)
        #expect(watch.due(R(awake: 105, elapsed: 105, wall: 1_800_000_065)) == .stepped(60))
        #expect(watch.due(R(awake: 105, elapsed: 105, wall: 1_799_999_995)) == .stepped(-10))
    }

    @Test func noiseBelowTheToleranceIsIgnored() {
        let watch = GuestClockWatch(start)
        #expect(watch.due(R(awake: 110, elapsed: 110.5, wall: 1_800_000_010.9)) == nil)
    }

    @Test func aSyncStartsTheCountAgain() {
        var watch = GuestClockWatch(start)
        let woke = R(awake: 110, elapsed: 3710, wall: 1_800_003_610)
        watch.synced(woke)
        #expect(watch.due(R(awake: 120, elapsed: 3720, wall: 1_800_003_620)) == nil)
    }

    /// A quick call is taken at the middle of its round trip; a slow one never overcorrects.
    @Test func estimates() {
        let ms: Int64 = 1_000_000
        // 10 ms round trip, guest read 105 ms past the send time: about 100 ms ahead.
        #expect(GuestClockWatch.estimate(arrival: 105 * ms, roundTrip: 10 * ms)! == (100 * ms, true))
        // Guest 100 ms ahead, the request waited 1.9 s on its way: back by 50 ms, not by the ~1 s the middle says.
        #expect(GuestClockWatch.estimate(arrival: 2_000 * ms, roundTrip: 1_950 * ms)! == (50 * ms, false))
        // A range [-1.0 s, +0.9 s] that holds zero: no change.
        #expect(GuestClockWatch.estimate(arrival: 900 * ms, roundTrip: 1_900 * ms) == nil)
        // An hour behind after sleep, 1.5 s wait: moved forward by what is certain, not by more.
        #expect(GuestClockWatch.estimate(arrival: -3_600_000 * ms + 1_500 * ms, roundTrip: 1_500 * ms)! == (-3_598_500 * ms, false))
        // 5 s ahead, 1 s wait: back by 4 s at most.
        #expect(GuestClockWatch.estimate(arrival: 5_500 * ms, roundTrip: 1_000 * ms)! == (4_500 * ms, false))
    }

    @Test func liveReadingsAgree() {
        let watch = GuestClockWatch()
        #expect(watch.due() == nil)
    }
}
