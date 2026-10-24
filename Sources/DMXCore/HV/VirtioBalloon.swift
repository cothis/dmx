import Foundation

/// virtio-balloon (device 5, virtio 1.x section 5.5) with free page reporting. The guest reports
/// blocks of free pages on the reporting queue; `release` hands them back to macOS. The balloon
/// itself (inflate/deflate) is how the daemon's memory controller squeezes the guest under host
/// pressure (`setTarget`); pages it inflates are released the same way.
final class VirtioBalloon: VirtioDevice, @unchecked Sendable {
    static let deflateOnOOM: UInt64 = 1 << 2
    static let reporting: UInt64 = 1 << 5

    let deviceID: UInt32 = 5
    let features: UInt64 = VirtioBalloon.deflateOnOOM | VirtioBalloon.reporting
    /// inflateq, deflateq, reporting_vq: absent queues (stats, free page hints) take no index.
    let queueSizes: [UInt16] = [64, 64, 32]

    private let queue = DispatchQueue(label: "dmx.balloon")
    private let release: (UInt64, UInt64) -> Void
    private let ramBase: UInt64
    private let ram: UnsafeMutableRawPointer
    private let lock = NSLock()
    private var transport: VirtioMMIO?
    private var targetPages: UInt32 = 0  // config num_pages: how many 4K pages the guest should give up
    private var actualPages: UInt32 = 0  // config actual: how many it has
    private(set) var reportedBytes: UInt64 = 0
    private(set) var reports = 0

    /// `release(address, length)` returns a guest-physical range to the host.
    init(ram: GuestRAM, release: @escaping (UInt64, UInt64) -> Void) {
        self.ram = ram.base
        self.ramBase = ram.guestBase
        self.release = release
    }

    var stats: (reports: Int, bytes: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (reports, reportedBytes)
    }

    /// The balloon size asked for and the size the guest reports, in bytes.
    var size: (target: UInt64, actual: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (UInt64(targetPages) << 12, UInt64(actualPages) << 12)
    }

    /// Asks the guest to grow or shrink its balloon to `bytes`. The guest takes free pages first
    /// and reclaims for the rest; with DEFLATE_ON_OOM it gives pages back rather than OOM-kill.
    func setTarget(_ bytes: UInt64) {
        lock.lock()
        targetPages = UInt32(min(bytes >> 12, UInt64(UInt32.max)))
        let transport = self.transport
        lock.unlock()
        transport?.signalConfigChange()
    }

    func activate(_ transport: VirtioMMIO, features: UInt64) {
        lock.lock()
        self.transport = transport
        lock.unlock()
    }

    func reset() {
        lock.lock()
        transport = nil
        actualPages = 0
        lock.unlock()
    }

    func readConfig(offset: Int, size: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        switch offset {
        case 0: return UInt64(targetPages)
        case 4: return UInt64(actualPages)
        default: return 0
        }
    }

    func writeConfig(offset: Int, size: Int, value: UInt64) {
        guard offset == 4 else { return }
        lock.lock()
        actualPages = UInt32(truncatingIfNeeded: value)
        lock.unlock()
    }

    func notify(queue index: Int) {
        queue.async { self.drain(index) }
    }

    private func drain(_ index: Int) {
        lock.lock()
        let transport = self.transport
        lock.unlock()
        guard let transport, index < transport.queues.count else { return }

        var chains: [VirtqueueChain] = []
        transport.lock.lock()
        while let chain = transport.queues[index].pop() { chains.append(chain) }
        transport.lock.unlock()
        guard !chains.isEmpty else { return }

        for chain in chains {
            switch index {
            case 0:  // inflate: arrays of 32-bit 4K page frame numbers
                // Host pages are 16K, so release contiguous runs rather than single 4K frames.
                let pfns = chain.readableBytes.withUnsafeBytes { raw in
                    stride(from: 0, to: raw.count - 3, by: 4).map {
                        UInt64(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
                    }
                }.sorted()
                var runStart: UInt64?, runEnd: UInt64 = 0
                for pfn in pfns {
                    if let start = runStart, pfn == runEnd { runEnd += 1; _ = start; continue }
                    if let start = runStart { release(start << 12, (runEnd - start) << 12) }
                    runStart = pfn
                    runEnd = pfn + 1
                }
                if let start = runStart { release(start << 12, (runEnd - start) << 12) }
            case 2:  // free page reports: each buffer is a free block, already off the guest's lists
                var bytes: UInt64 = 0
                for buffer in chain.writable + chain.readable {
                    let address = ramBase + UInt64(ram.distance(to: buffer.baseAddress!))
                    release(address, UInt64(buffer.count))
                    bytes += UInt64(buffer.count)
                }
                lock.lock()
                reports += 1
                reportedBytes += bytes
                lock.unlock()
            default:
                break  // deflate: nothing to do, the guest may simply use the pages again
            }
        }

        transport.lock.lock()
        for chain in chains { transport.queues[index].push(chain, written: 0) }
        transport.lock.unlock()
        transport.signalUsed()
    }
}
