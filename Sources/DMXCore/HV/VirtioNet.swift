import Foundation

/// virtio-net (device 1, virtio 1.x section 5.1): one receive and one transmit queue. Frames go to
/// and come from `UserNet`, dmx's user space NAT, so the host needs no network interface, root or
/// entitlement (see docs/network.md). All state lives on one serial queue, shared with `UserNet`.
///
/// The MTU is 65520, like passt's: a 64 KB TCP segment crosses as one frame, without TSO or
/// segmentation on either side. Checksums are skipped both ways (CSUM, GUEST_CSUM): the NAT ends
/// every TCP and UDP flow, so nothing would check them. Mergeable receive buffers let a large
/// frame span several small guest buffers instead of the guest preallocating 64 KB per slot.
final class VirtioNet: VirtioDevice, @unchecked Sendable {
    static let csum: UInt64 = 1 << 0         // the guest may leave its checksums to us
    static let guestCsum: UInt64 = 1 << 1    // the guest accepts frames we mark DATA_VALID
    static let mtuFeature: UInt64 = 1 << 3
    static let macFeature: UInt64 = 1 << 5
    static let mergeableRx: UInt64 = 1 << 15
    static let mtu = 65520
    /// `virtio_net_hdr_v1`: with VIRTIO_F_VERSION_1 always 12 bytes, `num_buffers` included.
    static let headerSize = 12
    /// Frames waiting for guest receive buffers. TCP produces data only below this; ARP, ICMP
    /// and UDP replies may go over it up to `outboxLimit`, then they are dropped like on a wire.
    static let outboxHigh = 512 << 10
    static let outboxLimit = 4 << 20

    let deviceID: UInt32 = 1
    let features: UInt64 = VirtioNet.csum | VirtioNet.guestCsum | VirtioNet.mtuFeature
        | VirtioNet.macFeature | VirtioNet.mergeableRx
    let queueSizes: [UInt16] = [256, 256]  // receiveq (to the guest), transmitq (from it)

    let queue = DispatchQueue(label: "dmx.net")
    private(set) var net: UserNet!
    private var transport: VirtioMMIO?
    private var accepted: UInt64 = 0
    /// Ethernet frames for the guest, oldest first, and their total size.
    private var outbox: [[UInt8]] = []
    private var outboxHead = 0
    private var outboxBytes = 0
    /// Receive chains taken from the ring for a frame that did not fit yet.
    private var spare: [VirtqueueChain] = []
    /// One transmitted frame, gathered from its descriptors; reused, so it stays at the largest frame.
    private var txFrame: [UInt8] = []

    init() {
        net = UserNet(queue: queue, device: self)
    }

    /// Whether frames we send may skip their TCP/UDP checksums (the guest negotiated GUEST_CSUM).
    var checksumsOptional: Bool { accepted & Self.guestCsum != 0 }

    /// Whether there is room for frames that can wait, such as TCP data.
    var hasRoom: Bool { outboxBytes < Self.outboxHigh }

    // MARK: VirtioDevice

    func readConfig(offset: Int, size: Int) -> UInt64 {
        // mac[6], status (no STATUS feature), max_virtqueue_pairs, mtu
        var config = UserNet.guestMAC + [0, 0, 1, 0]
        config += [UInt8(Self.mtu & 0xff), UInt8(Self.mtu >> 8)]
        var value: UInt64 = 0
        for i in 0..<size where offset + i < config.count {
            value |= UInt64(config[offset + i]) << (8 * UInt64(i))
        }
        return value
    }

    func activate(_ transport: VirtioMMIO, features: UInt64) {
        queue.async {
            self.transport = transport
            self.accepted = features
            self.deliver()
        }
    }

    func reset() {
        queue.async {
            self.transport = nil
            self.accepted = 0
            self.spare.removeAll()
            self.clearOutbox()
            self.net.reset()
        }
    }

    func notify(queue index: Int) {
        queue.async {
            if index == 0 { self.deliver() } else { self.transmit() }
        }
    }

    /// The VM stopped: closes every host socket.
    func stop() {
        queue.async {
            self.transport = nil
            self.clearOutbox()
            self.net.reset()
        }
    }

    // MARK: Frames

    /// Queues an Ethernet frame for the guest. Called by `UserNet`, on `queue`.
    func send(_ frame: [UInt8]) {
        guard transport != nil, outboxBytes + frame.count <= Self.outboxLimit else { return }
        outbox.append(frame)
        outboxBytes += frame.count
        deliver()
    }

    private func clearOutbox() {
        outbox.removeAll()
        outboxHead = 0
        outboxBytes = 0
    }

    /// Frames the guest sent: each goes to the NAT while its buffers are still in guest RAM.
    private func transmit() {
        guard let transport else { return }
        var chains: [VirtqueueChain] = []
        transport.lock.lock()
        while let chain = transport.queues[1].pop() { chains.append(chain) }
        transport.lock.unlock()
        guard !chains.isEmpty else { return }

        for chain in chains {
            txFrame.removeAll(keepingCapacity: true)
            for buffer in chain.readable { txFrame.append(contentsOf: buffer) }
            guard txFrame.count > Self.headerSize else { continue }
            txFrame.withUnsafeBytes { net.receive(UnsafeRawBufferPointer(rebasing: $0[Self.headerSize...])) }
        }
        transport.lock.lock()
        for chain in chains { transport.queues[1].push(chain, written: 0) }
        transport.lock.unlock()
        transport.signalUsed()
        deliver()
    }

    /// Copies waiting frames into the guest's receive buffers, each behind a virtio-net header.
    private func deliver() {
        guard let transport, outboxHead < outbox.count else { return }
        let mergeable = accepted & Self.mergeableRx != 0
        let wasFull = !hasRoom
        var used = false
        transport.lock.lock()
        while outboxHead < outbox.count {
            let frame = outbox[outboxHead]
            let length = Self.headerSize + frame.count
            var capacity = spare.reduce(0) { $0 + $1.writableCapacity }
            while capacity < length, mergeable || spare.isEmpty, let chain = transport.queues[0].pop() {
                spare.append(chain)
                capacity += chain.writableCapacity
            }
            if capacity < length {
                if mergeable || spare.isEmpty { break }  // wait for the guest to add buffers
                // Without mergeable buffers one chain must hold the frame: drop what never fits.
                outboxHead += 1
                outboxBytes -= frame.count
                continue
            }
            var header = [UInt8](repeating: 0, count: Self.headerSize)
            if accepted & Self.guestCsum != 0 { header[0] = 2 }  // VIRTIO_NET_HDR_F_DATA_VALID
            var cursor = 0, buffers = 0
            // Count the chains first: the header that leads the frame carries their number.
            var remaining = length
            for chain in spare where remaining > 0 { remaining -= chain.writableCapacity; buffers += 1 }
            header[10] = UInt8(buffers & 0xff)
            header[11] = UInt8(buffers >> 8)
            var filled: [(chain: VirtqueueChain, written: Int)] = []
            header.withUnsafeBytes { h in
                frame.withUnsafeBytes { f in
                    for chain in spare.prefix(buffers) {
                        let n = chain.write(from: [h, f], skipping: cursor)
                        filled.append((chain, n))
                        cursor += n
                    }
                }
            }
            // All at once: the guest may be polling the ring right now, and a frame whose first
            // buffer it sees before the others is dropped ("buffers missing").
            transport.queues[0].push(filled)
            spare.removeFirst(buffers)
            outboxHead += 1
            outboxBytes -= frame.count
            used = true
        }
        if outboxHead == outbox.count {
            clearOutbox()
        } else if outboxHead >= 64 && outboxHead >= outbox.count / 2 {
            outbox.removeFirst(outboxHead)
            outboxHead = 0
        }
        transport.lock.unlock()
        if used { transport.signalUsed() }
        if wasFull && hasRoom { net.resume() }
    }
}

extension VirtqueueChain {
    /// Fills the writable buffers from `sources` taken as one byte string, starting `skipping`
    /// bytes into it. Returns the number of bytes written.
    func write(from sources: [UnsafeRawBufferPointer], skipping: Int) -> Int {
        var skip = skipping, written = 0
        var source = 0, sourceOffset = 0
        while source < sources.count, skip > 0 {
            let n = min(skip, sources[source].count - sourceOffset)
            skip -= n
            sourceOffset += n
            if sourceOffset == sources[source].count { source += 1; sourceOffset = 0 }
        }
        for buffer in writable {
            var offset = 0
            while offset < buffer.count, source < sources.count {
                let s = sources[source]
                let n = min(buffer.count - offset, s.count - sourceOffset)
                if n > 0 { (buffer.baseAddress! + offset).copyMemory(from: s.baseAddress! + sourceOffset, byteCount: n) }
                offset += n
                sourceOffset += n
                written += n
                if sourceOffset == s.count { source += 1; sourceOffset = 0 }
            }
            if source == sources.count { break }
        }
        return written
    }
}
