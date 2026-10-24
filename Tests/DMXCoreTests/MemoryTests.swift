import Foundation
import Testing
@testable import DMXCore

@Suite struct MemoryTests {
    @Test func kernelPageSizesAndReporting() {
        #expect(Machine.pageSize(kernelFlags: 10) == 4096)
        #expect(Machine.pageSize(kernelFlags: 12) == 16384)
        #expect(Machine.pageSize(kernelFlags: 14) == 65536)
        #expect(Machine.pageSize(kernelFlags: 0) == 4096)
        // The same 512K busy and 16K idle ranges across 4K/16K Linux kernels on this Mac.
        #expect(Machine.reportingOrder(pageSize: 4096, blockSize: 512 << 10) == 7)
        #expect(Machine.reportingOrder(pageSize: 16384, blockSize: 512 << 10) == 5)
        #expect(Machine.reportingOrder(pageSize: 4096, blockSize: 16 << 10) == 2)
        #expect(Machine.reportingOrder(pageSize: 16384, blockSize: 16 << 10) == 0)
        #expect(Machine.reportingOrder(pageSize: 65536, blockSize: 16 << 10) == 0)
    }

    /// A late daemon pressure callback must not touch devices after Machine starts teardown.
    @Test func pressureAfterStopIsIgnored() {
        let ram = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 16)
        defer { ram.deallocate() }
        let balloon = VirtioBalloon(ram: GuestRAM(base: ram, guestBase: 0, size: 16)) { _, _ in }
        let plug = VirtioMem(address: 1 << 30, size: 1 << 30) { _, _ in }
        let policy = MemoryPlugPolicy(plug: plug, balloon: balloon, boot: 1 << 30)
        balloon.setTarget(256 << 20)
        policy.stop()
        policy.setPressureHeadroom(256 << 20)
        policy.stop() // drains the queued callback
        #expect(balloon.size.target == 256 << 20)
    }

    /// A newer CLI must still read status from a daemon without hotplug fields.
    @Test func olderDaemonStatus() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let memory = try decoder.decode(MemoryStatus.self, from: Data(#"{"host_pressure":"normal","pressure_simulated":false,"trims":0}"#.utf8))
        #expect(memory.plug == nil)
        #expect(memory.hostPressure == "normal")
    }

    /// Requested/plugged sizes describe only the hotplug region, not boot RAM.
    @Test func hotplugWireFormat() throws {
        let report = MemoryPlugReport((boot: 1 << 30, requested: 256 << 20, plugged: 512 << 20, plugs: 4, unplugs: 2))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(object["boot_mb"] == 1024)
        #expect(object["requested_mb"] == 256)
        #expect(object["plugged_mb"] == 512)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(MemoryPlugReport.self, from: data)
        #expect(decoded.bootMb + decoded.pluggedMb == 1536)
        #expect(decoded.unplugs == 2)
    }
}
