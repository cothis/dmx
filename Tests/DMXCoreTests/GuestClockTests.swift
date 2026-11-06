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

    @Test func liveReadingsAgree() {
        let watch = GuestClockWatch()
        #expect(watch.due() == nil)
    }
}
