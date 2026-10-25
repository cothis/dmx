import Foundation

/// virtio-fs (device 26, virtio 1.x section 5.11): FUSE requests on virtqueues, answered by a
/// `FUSEServer` on one host directory. Queue 0 is the high priority queue (FORGET, INTERRUPT),
/// queue 1 the only request queue. Metadata requests run on the vCPU thread that kicked the queue,
/// the rest on a few worker threads; they finish in any order. READ and WRITE move data between
/// the file and guest memory directly, so the host keeps no data buffers whatever the traffic.
/// No DAX window: file data the guest reads sits in its page cache.
final class VirtioFS: VirtioDevice, @unchecked Sendable {
    let deviceID: UInt32 = 26
    let features: UInt64 = 0
    /// hiprio, requests. The guest caps a request at the queue size minus 4 pages.
    let queueSizes: [UInt16] = [64, 256]
    let tag: String
    let server: FUSEServer

    /// Hands slow requests to `workers`, at most `slots` at a time.
    private let intake = DispatchQueue(label: "dmx.fs")
    private let workers = DispatchQueue(label: "dmx.fs.worker", attributes: .concurrent)
    private let slots = DispatchSemaphore(value: 8)
    private let inflight = DispatchGroup()
    private let lock = NSLock()
    private var transport: VirtioMMIO?
    private var stopped = false
    /// Larger requests than this (other than WRITE's data) are refused: names, symlink targets
    /// and fixed structs fit easily.
    private static let maxArgs = 16 << 10

    /// Tells guest/init where to mount each share: `dmx.share=<tag>:<rw|ro>:<path>`, with the
    /// tags Machine gives the devices (dmx0, dmx1, ...).
    static func kernelArgs(_ shares: [Share]) -> [String] {
        shares.enumerated().map { "dmx.share=dmx\($0):\($1.readOnly ? "ro" : "rw"):\($1.path)" }
    }

    init(tag: String, server: FUSEServer) {
        self.tag = tag
        self.server = server
    }

    // MARK: VirtioDevice

    /// struct virtio_fs_config: tag[36], le32 num_request_queues.
    func readConfig(offset: Int, size: Int) -> UInt64 {
        var config = Array(tag.utf8.prefix(36))
        config += [UInt8](repeating: 0, count: 36 - config.count)
        config += [1, 0, 0, 0]
        guard offset >= 0, size <= 8, offset + size <= config.count else { return 0 }
        return config[offset..<(offset + size)].reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    func activate(_ transport: VirtioMMIO, features: UInt64) {
        lock.lock()
        self.transport = transport
        lock.unlock()
    }

    func reset() {
        lock.lock()
        transport = nil
        lock.unlock()
        // The guest's FUSE session ended; it starts over with INIT and new node ids.
        intake.async {
            self.inflight.wait()
            self.server.closeAll()
        }
    }

    /// Metadata requests run right here on the vCPU thread that kicked the queue: the guest task
    /// waits for them anyway, and handing them to another thread and back cost more than the
    /// syscalls (two thread wakeups per request, worse on a busy host). Reads, writes, fsync and
    /// directory listings go to the workers, so a slow disk never holds a vCPU.
    func notify(queue index: Int) {
        lock.lock()
        let transport = stopped ? nil : self.transport
        lock.unlock()
        guard let transport, index < transport.queues.count else { return }
        var chains: [VirtqueueChain] = []
        transport.lock.lock()
        while let chain = transport.queues[index].pop() { chains.append(chain) }
        transport.lock.unlock()
        var slow: [VirtqueueChain] = []
        for chain in chains {
            if Self.quick(chain) {
                inflight.enter()
                complete(chain, written: process(chain), queue: index, transport: transport)
                inflight.leave()
            } else {
                slow.append(chain)
            }
        }
        if !slow.isEmpty { intake.async { [slow] in self.dispatch(slow, queue: index, transport: transport) } }
    }

    private static let quickOps: Set<UInt32> = Set([
        FUSE.Opcode.lookup, .forget, .batchForget, .getattr, .setattr, .readlink, .symlink, .mknod, .mkdir,
        .unlink, .rmdir, .rename, .rename2, .link, .create, .statfs, .release, .releasedir, .flush,
        .initialize, .opendir, .interrupt, .access, .getxattr, .listxattr, .setxattr, .removexattr,
    ].map(\.rawValue))

    private static func quick(_ chain: VirtqueueChain) -> Bool {
        guard let first = chain.readable.first, first.count >= 8 else { return false }
        return quickOps.contains(UInt32(littleEndian: first.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
    }

    /// The VM stopped: waits for requests in progress, then closes every file the guest had open.
    func stop() {
        intake.sync {
            lock.lock()
            stopped = true
            transport = nil
            lock.unlock()
        }
        inflight.wait()
        server.closeAll()
    }

    // MARK: Requests

    private func dispatch(_ chains: [VirtqueueChain], queue index: Int, transport: VirtioMMIO) {
        lock.lock()
        let stopped = self.stopped
        lock.unlock()
        guard !stopped else { return }
        for chain in chains {
            slots.wait()
            inflight.enter()
            workers.async {
                let written = self.process(chain)
                self.complete(chain, written: written, queue: index, transport: transport)
                self.slots.signal()
                self.inflight.leave()
            }
        }
    }

    private func complete(_ chain: VirtqueueChain, written: Int, queue: Int, transport: VirtioMMIO) {
        lock.lock()
        let current = self.transport === transport
        lock.unlock()
        guard current else { return }  // reset since: the chain belongs to a queue that is gone
        transport.lock.lock()
        transport.queues[queue].push(chain, written: written)
        transport.lock.unlock()
        transport.signalUsed()
    }

    /// Runs one request; returns how many bytes of reply went into the chain.
    private func process(_ chain: VirtqueueChain) -> Int {
        let readable = chain.readable.map { iovec(iov_base: $0.baseAddress, iov_len: $0.count) }
        let writable = chain.writable.map { iovec(iov_base: $0.baseAddress, iov_len: $0.count) }
        let readableBytes = readable.reduce(0) { $0 + $1.iov_len }
        guard readableBytes >= FUSE.inHeaderSize else { return 0 }

        var header = FUSEReader(gather(readable, from: 0, count: FUSE.inHeaderSize))
        let length = Int((try? header.u32()) ?? 0)
        let opcode = (try? header.u32()) ?? 0
        let unique = (try? header.u64()) ?? 0
        let nodeid = (try? header.u64()) ?? 0
        let caller = FUSEServer.Caller(uid: (try? header.u32()) ?? 0, gid: (try? header.u32()) ?? 0)

        let isWrite = opcode == FUSE.Opcode.write.rawValue
        let argsLength = isWrite ? 40 : min(max(length, FUSE.inHeaderSize), readableBytes) - FUSE.inHeaderSize
        let reply: FUSEServer.Reply
        if argsLength > Self.maxArgs || (isWrite && readableBytes < FUSE.inHeaderSize + 40) {
            reply = .error(Linux.EINVAL)
        } else {
            let args = gather(readable, from: FUSE.inHeaderSize, count: argsLength)
            let input = isWrite ? slice(readable, from: FUSE.inHeaderSize + 40, count: Int.max) : []
            let output = slice(writable, from: FUSE.outHeaderSize, count: Int.max)
            reply = server.handle(opcode: opcode, node: nodeid, caller: caller, args: args, input: input, output: output)
        }

        var body = Data(), direct = 0, error: Int32 = 0
        switch reply {
        case .none: return 0
        case .error(let e): error = e
        case .data(let d): body = d
        case .direct(let n): direct = n
        }
        let capacity = chain.writableCapacity
        guard capacity >= FUSE.outHeaderSize else { return 0 }
        if FUSE.outHeaderSize + body.count > capacity {
            body = Data()
            error = Linux.ERANGE
        }
        var out = FUSEWriter(capacity: FUSE.outHeaderSize + body.count)
        out.u32(UInt32(FUSE.outHeaderSize + body.count + direct))
        out.u32(UInt32(bitPattern: -error))
        out.u64(unique)
        out.data.append(body)
        _ = chain.write(out.data)
        return FUSE.outHeaderSize + body.count + direct
    }
}

/// Copies `count` bytes starting `offset` bytes into `buffers`.
private func gather(_ buffers: [iovec], from offset: Int, count: Int) -> Data {
    var data = Data(capacity: count)
    for b in slice(buffers, from: offset, count: count) {
        data.append(b.iov_base!.assumingMemoryBound(to: UInt8.self), count: b.iov_len)
    }
    return data
}

/// Chains go to worker threads. Their buffers point into guest RAM, which stays mapped until
/// `Machine` is gone, and `VirtioFS.stop()` waits for every request before that.
extension VirtqueueChain: @unchecked Sendable {}
