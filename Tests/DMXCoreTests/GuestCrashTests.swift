import Foundation
import Testing
@testable import DMXCore

@Suite struct GuestCrashTests {
    @Test func backoffDoublesUpToAMinute() {
        let delays = (1...9).map { GuestCrashes.delay(streak: $0) }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60, 60].map { Duration.seconds($0) })
        #expect(GuestCrashes.delay(streak: 10_000) == .seconds(60))
    }

    @Test func aStableVMStartsTheCountAgain() {
        var crashes = GuestCrashes()
        #expect(crashes.crashed(reason: "a", uptime: .seconds(5)) == .seconds(1))
        #expect(crashes.crashed(reason: "b", uptime: .seconds(5)) == .seconds(2))
        #expect(crashes.crashed(reason: "c", uptime: nil) == .seconds(4))
        #expect(crashes.streak == 3)
        #expect(crashes.crashed(reason: "d", uptime: GuestCrashes.stableAfter) == .seconds(1))
        #expect(crashes.streak == 1)
        #expect(crashes.last?.reason == "d")
    }

    @Test func consoleTailIsTheCrashedBootOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dmx-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let console = dir.appendingPathComponent("console.log")
        // The crashed boot began in the rotation before.
        try Data("old boot\n--- dmx VM boot 1 ---\nfirst\n--- dmx VM boot 2 ---\nsecond starts\n".utf8)
            .write(to: URL(fileURLWithPath: console.path + ".1"))
        try Data("Kernel panic - not syncing: sysrq triggered crash\n".utf8).write(to: console)
        let tail = GuestCrashes.consoleTail(console)
        #expect(tail.hasPrefix("\n--- dmx VM boot 2 ---\nsecond starts\n"))
        #expect(tail.hasSuffix("sysrq triggered crash\n"))
        #expect(!tail.contains("first"))

        let record = String(decoding: GuestCrashes.record(reason: "kernel reset", uptime: .seconds(3), consoleLog: console), as: UTF8.self)
        #expect(record.hasPrefix("=== guest crash "))
        #expect(record.contains(": kernel reset, up 3.0 s ===\n"))

        // Without a marker, only the newest bytes.
        try Data(repeating: UInt8(ascii: "x"), count: 100).write(to: console)
        try FileManager.default.removeItem(atPath: console.path + ".1")
        #expect(GuestCrashes.consoleTail(console, limit: 10) == String(repeating: "x", count: 10))
        #expect(GuestCrashes.consoleTail(dir.appendingPathComponent("missing.log")) == "")
    }
}
