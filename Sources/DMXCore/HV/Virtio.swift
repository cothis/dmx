import Foundation
import Synchronization

/// Guest RAM as seen from the host. Guest physical addresses from virtqueues are checked
/// against it before use, since the guest controls them.
struct GuestRAM: @unchecked Sendable {
    let base: UnsafeMutableRawPointer
    let guestBase: UInt64
    let size: UInt64

    func pointer(_ address: UInt64, _ length: Int) -> UnsafeMutableRawPointer? {
        guard address >= guestBase, length >= 0,
              address - guestBase <= size, UInt64(length) <= size - (address - guestBase) else { return nil }
        return base.advanced(by: Int(address - guestBase))
    }

    func load<T: FixedWidthInteger>(_ address: UInt64, as: T.Type) -> T? {
        pointer(address, MemoryLayout<T>.size).map { T(littleEndian: $0.loadUnaligned(as: T.self)) }
    }

    func store<T: FixedWidthInteger>(_ address: UInt64, _ value: T) {
        pointer(address, MemoryLayout<T>.size)?.storeBytes(of: value.littleEndian, as: T.self)
    }
}

/// A descriptor chain the driver made available: buffers the device reads, then buffers it
/// writes, in order.
struct VirtqueueChain {
    let head: UInt16
    var readable: [UnsafeMutableRawBufferPointer] = []
    var writable: [UnsafeMutableRawBufferPointer] = []

    var readableBytes: Data {
        var data = Data()
        for buffer in readable { data.append(contentsOf: buffer) }
        return data
    }

    var writableCapacity: Int { writable.reduce(0) { $0 + $1.count } }

    /// Copies as much of `data` as fits into the writable buffers; returns the byte count.
    func write(_ data: Data) -> Int {
        var offset = 0
        for buffer in writable where offset < data.count {
            let n = min(buffer.count, data.count - offset)
            data.withUnsafeBytes { buffer.baseAddress!.copyMemory(from: $0.baseAddress! + offset, byteCount: n) }
            offset += n
        }
        return offset
    }
}

/// A split virtqueue (virtio 1.x, section 2.7). Not thread safe; its device serializes access.
final class Virtqueue: @unchecked Sendable {
    let maxSize: UInt16
    var size: UInt16
    var ready = false
    var descriptors: UInt64 = 0
    var driverArea: UInt64 = 0   // the available ring
    var deviceArea: UInt64 = 0   // the used ring
    private var nextAvail: UInt16 = 0
    private var nextUsed: UInt16 = 0
    private let ram: GuestRAM

    init(maxSize: UInt16, ram: GuestRAM) {
        self.maxSize = maxSize
        self.size = maxSize
        self.ram = ram
    }

    func reset() {
        ready = false
        size = maxSize
        descriptors = 0; driverArea = 0; deviceArea = 0
        nextAvail = 0; nextUsed = 0
    }

    /// The next chain the driver made available, or nil if there is none (or it is malformed).
    func pop() -> VirtqueueChain? {
        guard ready, let availIdx = ram.load(driverArea + 2, as: UInt16.self), availIdx != nextAvail else { return nil }
        atomicMemoryFence(ordering: .acquiring)
        guard let head = ram.load(driverArea + 4 + 2 * UInt64(nextAvail % size), as: UInt16.self) else { return nil }
        nextAvail &+= 1

        var chain = VirtqueueChain(head: head)
        var index = head
        for _ in 0..<size {
            let entry = descriptors + 16 * UInt64(index)
            guard index < size,
                  let address = ram.load(entry, as: UInt64.self),
                  let length = ram.load(entry + 8, as: UInt32.self),
                  let flags = ram.load(entry + 12, as: UInt16.self),
                  let next = ram.load(entry + 14, as: UInt16.self),
                  let pointer = ram.pointer(address, Int(length)) else { return nil }
            let buffer = UnsafeMutableRawBufferPointer(start: pointer, count: Int(length))
            if flags & 2 != 0 { chain.writable.append(buffer) } else { chain.readable.append(buffer) }
            guard flags & 1 != 0 else { return chain }
            index = next
        }
        return nil  // a loop in the descriptor table
    }

    /// Hands a chain back to the driver with the number of bytes the device wrote.
    func push(_ chain: VirtqueueChain, written: Int) {
        let slot = deviceArea + 4 + 8 * UInt64(nextUsed % size)
        ram.store(slot, UInt32(chain.head))
        ram.store(slot + 4, UInt32(written))
        nextUsed &+= 1
        atomicMemoryFence(ordering: .releasing)
        ram.store(deviceArea + 2, nextUsed)
    }

    /// Hands several chains back with one index update, so the driver sees all of them or none:
    /// a frame spread over mergeable receive buffers must not show up in part.
    func push(_ chains: [(chain: VirtqueueChain, written: Int)]) {
        for (chain, written) in chains {
            let slot = deviceArea + 4 + 8 * UInt64(nextUsed % size)
            ram.store(slot, UInt32(chain.head))
            ram.store(slot + 4, UInt32(written))
            nextUsed &+= 1
        }
        atomicMemoryFence(ordering: .releasing)
        ram.store(deviceArea + 2, nextUsed)
    }
}

/// What a virtio device implements; the MMIO transport does the rest.
protocol VirtioDevice: AnyObject, Sendable {
    var deviceID: UInt32 { get }
    /// Device feature bits. The transport adds VIRTIO_F_VERSION_1.
    var features: UInt64 { get }
    var queueSizes: [UInt16] { get }
    func readConfig(offset: Int, size: Int) -> UInt64
    func writeConfig(offset: Int, size: Int, value: UInt64)
    /// The driver accepted `features` and set DRIVER_OK; queues are ready.
    func activate(_ transport: VirtioMMIO, features: UInt64)
    /// The driver added buffers to `queue`. Runs on a vCPU thread, so hand slow work off.
    func notify(queue: Int)
    func reset()
}

extension VirtioDevice {
    func readConfig(offset: Int, size: Int) -> UInt64 { 0 }
    func writeConfig(offset: Int, size: Int, value: UInt64) {}
}

/// The virtio-mmio transport, version 2 (virtio 1.x, section 4.2).
final class VirtioMMIO: MMIODevice, @unchecked Sendable {
    static let size: UInt64 = 0x200
    static let versionOne: UInt64 = 1 << 32

    let device: VirtioDevice
    let queues: [Virtqueue]
    /// Devices lock this while they touch their queues.
    let lock = NSLock()
    private let irq: (Bool) -> Void
    private var status: UInt32 = 0
    private var interruptStatus: UInt32 = 0
    private var deviceFeaturesSel: UInt32 = 0
    private var driverFeaturesSel: UInt32 = 0
    private var driverFeatures: UInt64 = 0
    private var queueSel: UInt32 = 0

    init(device: VirtioDevice, ram: GuestRAM, irq: @escaping (Bool) -> Void) {
        self.device = device
        self.irq = irq
        queues = device.queueSizes.map { Virtqueue(maxSize: $0, ram: ram) }
    }

    /// Tells the driver that used buffers are waiting (interrupt status bit 0).
    func signalUsed() {
        lock.lock()
        defer { lock.unlock() }
        interruptStatus |= 1
        irq(true)
    }

    private var selected: Virtqueue? { Int(queueSel) < queues.count ? queues[Int(queueSel)] : nil }

    func read(offset: UInt64, size: Int) -> UInt64 {
        if offset >= 0x100 { return device.readConfig(offset: Int(offset - 0x100), size: size) }
        lock.lock()
        defer { lock.unlock() }
        let features = device.features | Self.versionOne
        switch offset {
        case 0x000: return 0x7472_6976           // "virt"
        case 0x004: return 2                      // version
        case 0x008: return UInt64(device.deviceID)
        case 0x00c: return 0x0078_6d64           // vendor "dmx"
        case 0x010: return deviceFeaturesSel < 2 ? (features >> (32 * UInt64(deviceFeaturesSel))) & 0xffff_ffff : 0
        case 0x034: return UInt64(selected?.maxSize ?? 0)
        case 0x044: return selected?.ready == true ? 1 : 0
        case 0x060: return UInt64(interruptStatus)
        case 0x070: return UInt64(status)
        case 0x0fc: return 0                      // config generation
        default: return 0
        }
    }

    func write(offset: UInt64, size: Int, value: UInt64) {
        if offset >= 0x100 { return device.writeConfig(offset: Int(offset - 0x100), size: size, value: value) }
        let v = UInt32(truncatingIfNeeded: value)
        if offset == 0x050 { return device.notify(queue: Int(v)) }
        lock.lock()
        var activate = false, reset = false, lower = false
        switch offset {
        case 0x014: deviceFeaturesSel = v
        case 0x020:
            if driverFeaturesSel < 2 {
                let shift = 32 * UInt64(driverFeaturesSel)
                driverFeatures = driverFeatures & ~(0xffff_ffff << shift) | UInt64(v) << shift
            }
        case 0x024: driverFeaturesSel = v
        case 0x030: queueSel = v
        case 0x038: if let q = selected, v > 0, v <= q.maxSize, v & (v - 1) == 0 { q.size = UInt16(v) }
        case 0x044: selected?.ready = v == 1
        case 0x064:
            interruptStatus &= ~v
            lower = interruptStatus == 0
        case 0x070:
            if v == 0 {
                reset = true
                status = 0; interruptStatus = 0; driverFeatures = 0; queueSel = 0
                for q in queues { q.reset() }
                lower = true
            } else {
                activate = v & 4 != 0 && status & 4 == 0  // DRIVER_OK set now
                status = v
            }
        case 0x080...0x0a4:
            guard let q = selected else { break }
            switch offset {
            case 0x080: setLow(&q.descriptors, v)
            case 0x084: setHigh(&q.descriptors, v)
            case 0x090: setLow(&q.driverArea, v)
            case 0x094: setHigh(&q.driverArea, v)
            case 0x0a0: setLow(&q.deviceArea, v)
            case 0x0a4: setHigh(&q.deviceArea, v)
            default: break
            }
        default: break
        }
        // Lowered under the lock: lowered after it, the line could go down just after
        // `signalUsed` raised it for a new buffer, and the guest would never look again.
        if lower { irq(false) }
        let accepted = driverFeatures
        lock.unlock()
        if reset { device.reset() }
        if activate { device.activate(self, features: accepted) }
    }

    private func setLow(_ field: inout UInt64, _ v: UInt32) { field = field & ~0xffff_ffff | UInt64(v) }
    private func setHigh(_ field: inout UInt64, _ v: UInt32) { field = field & 0xffff_ffff | UInt64(v) << 32 }
}
