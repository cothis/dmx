import Foundation

/// virtio-mem (device 24, virtio 1.2 section 5.15): guest RAM above what the guest boots with,
/// plugged in blocks as the host asks. The kernel builds its struct page memmap (64 bytes per
/// 16 KB page, 4 MB per GB) for all RAM it knows at boot and touches all of it, so a guest
/// booted with its whole ceiling pays for the ceiling. Memory it gets through this device costs
/// memmap only once plugged, and unplugging gives the memmap back as well as the pages.
///
/// The host only sets `requestedSize`; the guest driver plugs or unplugs blocks until its
/// plugged size matches, and unplugs only memory it could free (ZONE_MOVABLE makes that likely).
/// Unplugged blocks are released to macOS: the guest promised not to touch them
/// (VIRTIO_MEM_F_UNPLUGGED_INACCESSIBLE), and a block plugged again faults in as zeros.
final class VirtioMem: VirtioDevice, @unchecked Sendable {
    static let unpluggedInaccessible: UInt64 = 1 << 1
    /// Plug granularity. Linux plugs at least a pageblock (32 MB with 16K pages, which is also
    /// its largest allocation) and adds memory to the kernel in 128 MB memory blocks.
    static let blockSize: UInt64 = 32 << 20
    /// Linux's memory block size with 16K pages (a sparsemem section). The region is aligned to
    /// it, or the driver cannot use the partial blocks at its ends.
    static let linuxBlockSize: UInt64 = 128 << 20

    let deviceID: UInt32 = 24
    let features: UInt64 = VirtioMem.unpluggedInaccessible
    let queueSizes: [UInt16] = [16]  // guestq: the driver sends one request at a time

    /// Guest-physical start and size of the hotpluggable region.
    let address: UInt64
    let regionSize: UInt64

    private let queue = DispatchQueue(label: "dmx.virtio-mem")
    private let release: (UInt64, UInt64) -> Void
    private let lock = NSLock()
    private var transport: VirtioMMIO?
    private var plugged: [Bool]
    private var pluggedBlocks = 0
    private var requested: UInt64 = 0
    private var events: (plugs: Int, unplugs: Int) = (0, 0)

    /// `release(address, length)` returns a guest-physical range to the host.
    init(address: UInt64, size: UInt64, release: @escaping (UInt64, UInt64) -> Void) {
        precondition(address % Self.linuxBlockSize == 0 && size % Self.linuxBlockSize == 0)
        self.address = address
        self.regionSize = size
        self.release = release
        plugged = Array(repeating: false, count: Int(size / Self.blockSize))
    }

    /// What the host asked for, what the guest has plugged, and how many requests it made.
    var state: (requested: UInt64, plugged: UInt64, plugs: Int, unplugs: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (requested, UInt64(pluggedBlocks) * Self.blockSize, events.plugs, events.unplugs)
    }

    /// Asks the guest to plug or unplug memory until `bytes` of the region are plugged. Rounded
    /// up to whole Linux memory blocks: a partly plugged one costs its whole memmap anyway.
    func setRequested(_ bytes: UInt64) {
        let size = min(alignUp(bytes, Self.linuxBlockSize), regionSize)
        lock.lock()
        guard size != requested else { return lock.unlock() }
        requested = size
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
        // Blocks stay plugged: a driver that comes back finds plugged_size > 0 and unplugs all.
        lock.lock()
        transport = nil
        lock.unlock()
    }

    func readConfig(offset: Int, size: Int) -> UInt64 {
        lock.lock()
        let fields: [UInt64] = [
            Self.blockSize,
            0,  // node_id and padding
            address,
            regionSize,
            regionSize,  // usable_region_size: all of it, always
            UInt64(pluggedBlocks) * Self.blockSize,
            requested,
        ]
        lock.unlock()
        guard offset >= 0, size > 0, size <= 8, offset + size <= fields.count * 8 else { return 0 }
        var value: UInt64 = 0
        for i in 0..<size {
            let byte = offset + i
            value |= (fields[byte / 8] >> (8 * UInt64(byte % 8)) & 0xff) << (8 * UInt64(i))
        }
        return value
    }

    func notify(queue index: Int) {
        queue.async { self.drain() }
    }

    private enum Request: UInt16 { case plug = 0, unplug = 1, unplugAll = 2, state = 3 }
    private enum Response: UInt16 { case ack = 0, nack = 1, busy = 2, error = 3 }

    private func drain() {
        lock.lock()
        let transport = self.transport
        lock.unlock()
        guard let transport else { return }
        var used = false
        while true {
            transport.lock.lock()
            let chain = transport.queues[0].pop()
            transport.lock.unlock()
            guard let chain else { break }
            // struct virtio_mem_req: le16 type, 3 × le16 padding, le64 addr, le16 nb_blocks.
            let request = chain.readableBytes
            var response = Data(count: 10)  // struct virtio_mem_resp: le16 type, padding, le16 state
            if request.count >= 18 {
                let type = request.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self)) }
                let addr = request.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
                let count = request.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 16, as: UInt16.self)) }
                let (result, state) = handle(Request(rawValue: type), addr: addr, count: Int(count))
                response.withUnsafeMutableBytes {
                    $0.storeBytes(of: result.rawValue.littleEndian, toByteOffset: 0, as: UInt16.self)
                    $0.storeBytes(of: state.littleEndian, toByteOffset: 8, as: UInt16.self)
                }
            } else {
                response.withUnsafeMutableBytes { $0.storeBytes(of: Response.error.rawValue.littleEndian, as: UInt16.self) }
            }
            let written = chain.write(response)
            transport.lock.lock()
            transport.queues[0].push(chain, written: written)
            transport.lock.unlock()
            used = true
        }
        if used { transport.signalUsed() }
    }

    /// Returns the response and, for a state request, VIRTIO_MEM_STATE_*.
    private func handle(_ request: Request?, addr: UInt64, count: Int) -> (Response, UInt16) {
        lock.lock()
        defer { lock.unlock() }
        if request == .unplugAll {
            for (index, isPlugged) in plugged.enumerated() where isPlugged { releaseBlocks(index, 1) }
            plugged = plugged.map { _ in false }
            pluggedBlocks = 0
            events.unplugs += 1
            return (.ack, 0)
        }
        guard let request, count > 0, addr >= address, (addr - address) % Self.blockSize == 0,
              (addr - address) / Self.blockSize + UInt64(count) <= UInt64(plugged.count) else { return (.error, 0) }
        let first = Int((addr - address) / Self.blockSize)
        let range = first..<(first + count)
        switch request {
        case .plug:
            guard !plugged[range].contains(true) else { return (.error, 0) }
            guard UInt64(pluggedBlocks + count) * Self.blockSize <= requested else { return (.nack, 0) }
            for i in range { plugged[i] = true }
            pluggedBlocks += count
            events.plugs += 1
            return (.ack, 0)
        case .unplug:
            guard !plugged[range].contains(false) else { return (.error, 0) }
            for i in range { plugged[i] = false }
            pluggedBlocks -= count
            releaseBlocks(first, count)
            events.unplugs += 1
            return (.ack, 0)
        case .state:
            let on = plugged[range].filter { $0 }.count
            return (.ack, on == count ? 0 : on == 0 ? 1 : 2)  // plugged, unplugged, mixed
        case .unplugAll:
            return (.ack, 0)  // handled above
        }
    }

    private func releaseBlocks(_ first: Int, _ count: Int) {
        release(address + UInt64(first) * Self.blockSize, UInt64(count) * Self.blockSize)
    }
}
