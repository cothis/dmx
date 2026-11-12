import Foundation
import Testing
@testable import DMXCore

@Suite struct DeviceStopTests {
    /// A stop barrier must wait for an already running device callback before RAM can go away.
    @Test func netStopWaitsForDeviceWork() {
        let net = VirtioNet()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        net.queue.async { entered.signal(); release.wait() }
        entered.wait()
        DispatchQueue.global().async { net.stop(); returned.signal() }
        let early = returned.wait(timeout: .now() + .milliseconds(100))
        release.signal()
        #expect(early == .timedOut)
        if early == .timedOut { #expect(returned.wait(timeout: .now() + 2) == .success) }
    }
    @Test func balloonStopWaitsForReleaseAndRejectsLaterWork() {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: 65536, alignment: 4096)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: 65536)
        defer { memory.deallocate() }
        let ram = GuestRAM(base: memory, guestBase: 0x1000, size: 65536)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        let balloon = VirtioBalloon(ram: ram) { _, _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
        }
        let transport = VirtioMMIO(device: balloon, ram: ram) { _ in }
        let q = transport.queues[2] // free-page reports without the stats feature
        q.descriptors = 0x1000; q.driverArea = 0x3000; q.deviceArea = 0x4000; q.ready = true
        ram.store(q.descriptors, UInt64(0x5000))
        ram.store(q.descriptors + 8, UInt32(16384))
        ram.store(q.descriptors + 12, UInt16(2))
        ram.store(q.driverArea + 2, UInt16(1))
        balloon.activate(transport, features: 0)
        balloon.notify(queue: 2)
        #expect(entered.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async { balloon.stop(); returned.signal() }
        let early = returned.wait(timeout: .now() + .milliseconds(100))
        release.signal()
        #expect(early == .timedOut)
        if early == .timedOut { #expect(returned.wait(timeout: .now() + 2) == .success) }
        #expect(balloon.stats.reports == 1)
        // A terminal device cannot be reactivated by an old callback.
        balloon.activate(transport, features: 0)
        ram.store(q.driverArea + 6, UInt16(0))
        ram.store(q.driverArea + 2, UInt16(2))
        balloon.notify(queue: 2)
        balloon.stop()
        #expect(balloon.stats.reports == 1)
    }

}
