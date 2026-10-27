import Foundation
import Testing
@testable import DMXCore

@Suite struct VirtqueueTests {
    func withQueue(_ body: (GuestRAM, Virtqueue) throws -> Void) rethrows {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: 4096)
        defer { memory.deallocate() }
        let ram = GuestRAM(base: memory, guestBase: 0x1000, size: 4096)
        let queue = Virtqueue(maxSize: 8, ram: ram)
        queue.descriptors = 0x1000
        queue.driverArea = 0x1100
        queue.deviceArea = 0x1200
        queue.ready = true
        ram.store(queue.driverArea + 2, UInt16(1))
        ram.store(queue.descriptors, UInt64(0x1300))
        ram.store(queue.descriptors + 8, UInt32(16))
        ram.store(queue.descriptors + 12, UInt16(2))
        try body(ram, queue)
    }

    /// The largest frame dmx sends must fit what Linux always keeps posted on the 64-slot receive
    /// ring, or one frame can stall every frame behind it until the VM restarts.
    @Test func largestFrameFitsGuaranteedReceiveBuffers() {
        let net = VirtioNet()
        #expect(net.queueSizes[0] == 64)
        #expect(VirtioNet.headerSize + 14 + VirtioNet.mtu <= VirtioNet.guaranteedReceive)
        #expect(UserNet.mss(UserNet.FlowKey(guestPort: 1, remote: IPAddress(v4: 0x0808_0808), remotePort: 80)) + 40 == VirtioNet.mtu)
    }

    @Test func validChainCompletes() throws {
        try withQueue { ram, queue in
            let chain = try #require(queue.pop())
            #expect(chain.write(Data("hello".utf8)) == 5)
            queue.push(chain, written: 5)
            #expect(ram.load(0x1202, as: UInt16.self) == 1)
            #expect(ram.load(0x1208, as: UInt32.self) == 5)
            #expect(queue.pop() == nil)
        }
    }

    @Test func ringsCanEndAtRAMBoundaryWithoutEventIndex() throws {
        try withQueue { ram, queue in
            // EVENT_IDX is not offered, so neither ring needs its optional trailing event field.
            queue.driverArea = 0x2000 - 4 - 2 * UInt64(queue.size)
            ram.store(queue.driverArea + 2, UInt16(1))
            let chain = try #require(queue.pop())
            queue.deviceArea = 0x2000 - 4 - 8 * UInt64(queue.size)
            queue.push(chain, written: 0)
            #expect(ram.load(queue.deviceArea + 2, as: UInt16.self) == 1)
        }
    }

    @Test func guestAddressesCannotOverflow() {
        for address in [UInt64.max, UInt64.max - 1, UInt64.max - 15, 0x1fff] {
            for field in [0, 1, 2] {
                withQueue { _, queue in
                    if field == 0 { queue.descriptors = address }
                    if field == 1 { queue.driverArea = address }
                    if field == 2 { queue.deviceArea = address }
                    #expect(queue.pop() == nil)
                    queue.push(VirtqueueChain(head: 0), written: 0)
                    queue.push([(VirtqueueChain(head: 0), 0)])
                }
            }
        }
    }

    @Test func malformedQueueSizesAndIndicesAreRefused() {
        for size: UInt16 in [0, 3, 16] {
            withQueue { _, queue in
                queue.size = size
                #expect(queue.pop() == nil)
                queue.push(VirtqueueChain(head: 0), written: 0)
            }
        }
        withQueue { ram, queue in
            ram.store(queue.driverArea + 2, UInt16(9))
            #expect(queue.pop() == nil)
        }
        withQueue { ram, queue in
            ram.store(queue.driverArea + 4, UInt16.max)
            #expect(queue.pop() == nil)
        }
    }

    @Test func invalidCompletionCannotTrapOrAdvanceTheRing() {
        for written in [-1, Int(UInt32.max) + 1] {
            withQueue { ram, queue in
                queue.push(VirtqueueChain(head: 0), written: written)
                queue.push([(VirtqueueChain(head: 0), written)])
                #expect(ram.load(0x1202, as: UInt16.self) == 0)
            }
        }
    }
}
