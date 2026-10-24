import Foundation

/// The data disk: a raw image file on the host, created sparse. `size` is a ceiling, not a
/// reservation: APFS allocates blocks only as the guest writes them, and the guest's discards
/// punch them out again.
public struct DataDisk: Sendable {
    public var url: URL
    /// Size of a new image. An existing image keeps its size.
    public var size: UInt64

    public init(url: URL, size: UInt64) {
        self.url = url
        self.size = size
    }

    /// Apparent size and the bytes the host has allocated, or nil if there is no image yet.
    public static func usage(_ url: URL) -> DiskUsage? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return DiskUsage(path: url.path, sizeMb: Int(st.st_size >> 20), allocatedMb: Int((UInt64(st.st_blocks) * 512) >> 20))
    }
}

public struct DiskUsage: Codable, Sendable {
    public let path: String
    /// What the guest sees (the file's apparent size).
    public let sizeMb: Int
    /// What it costs on the host's disk.
    public let allocatedMb: Int
}

/// virtio-blk (device 2, virtio 1.x section 5.2) on a raw image file. Requests run off the vCPU
/// thread, up to `maxInFlight` at once, straight between the file and guest RAM. A flush is
/// `F_BARRIERFSYNC`: the guest's writes reach the disk in the order it flushed them, so ext4's
/// journal holds after a power cut, though the last writes before it may be lost. A guest fsync
/// costs 3 to 7 ms this way, 10 to 17 with `F_FULLFSYNC` (durable even then); plain `fsync`
/// would not order anything on the SSD. Discard and write-zeroes punch holes (`F_PUNCHHOLE`), so space the guest frees goes back to
/// macOS.
final class VirtioBlock: VirtioDevice, @unchecked Sendable {
    static let sizeMaxFeature: UInt64 = 1 << 1
    static let segMaxFeature: UInt64 = 1 << 2
    static let blockSizeFeature: UInt64 = 1 << 6
    static let flushFeature: UInt64 = 1 << 9
    static let discardFeature: UInt64 = 1 << 13
    static let writeZeroesFeature: UInt64 = 1 << 14

    /// Logical block size offered to the guest. 4K, like APFS blocks, so every request and
    /// every discard is 4K aligned and can punch whole host blocks.
    static let blockSize: UInt32 = 4096
    static let queueSize: UInt16 = 256
    /// Without indirect descriptors a request takes its segments plus header and status.
    static let maxSegments = UInt32(queueSize) - 2
    static let maxSegmentSize: UInt32 = 1 << 20
    /// Per discard or write-zeroes request, in 512-byte sectors (2 GB), and ranges per request.
    static let maxDiscardSectors: UInt32 = 1 << 22
    static let maxDiscardRanges: UInt32 = 64
    static let id = "dmx-data"

    let deviceID: UInt32 = 2
    let features: UInt64 = sizeMaxFeature | segMaxFeature | blockSizeFeature | flushFeature | discardFeature | writeZeroesFeature
    let queueSizes: [UInt16] = [queueSize]

    /// Bytes the guest sees, a multiple of `blockSize`.
    let capacity: UInt64
    private var fd: Int32
    /// The host file system's block size; holes are punched in whole blocks.
    private let hostBlock: UInt64
    private let config: [UInt8]
    /// Takes requests off the virtqueue in order and hands them to `workers`.
    private let queue = DispatchQueue(label: "dmx.blk")
    /// Writes bypass the host cache, so each waits for the SSD; several in flight keep small
    /// writes from queueing behind each other (mkfs, journal commits).
    private let workers = DispatchQueue(label: "dmx.blk.io", attributes: .concurrent)
    static let maxInFlight = 8
    private let inFlight = DispatchSemaphore(value: maxInFlight)
    private let lock = NSLock()
    private var transport: VirtioMMIO?

    /// Opens the image, creating it sparse if missing. Holds an exclusive lock on it until
    /// `close()`, so two VMs never write the same disk.
    init(_ disk: DataDisk) throws {
        let path = disk.url.path
        try FileManager.default.createDirectory(at: disk.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw DMXError("disk_error", "cannot open \(path): \(String(cString: strerror(errno)))") }
        func fail(_ error: DMXError) -> DMXError {
            Darwin.close(file)
            return error
        }
        guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
            throw fail(DMXError("disk_in_use", "\(path) is in use by another dmx VM",
                                hint: "run `dmx status`; stop the VM using it (`dmx stop`) or use another DMX_HOME"))
        }
        var st = stat()
        guard fstat(file, &st) == 0 else { throw fail(DMXError("disk_error", "cannot stat \(path): \(String(cString: strerror(errno)))")) }
        if st.st_size == 0 {
            // ftruncate on APFS makes a sparse file: nothing is allocated until written.
            guard ftruncate(file, off_t(disk.size)) == 0 else {
                throw fail(DMXError("disk_error", "cannot size \(path) to \(formatSize(disk.size)): \(String(cString: strerror(errno)))"))
            }
            st.st_size = off_t(disk.size)
        }
        // The guest caches the disk itself. Through the host's cache every byte written stayed
        // charged to dmx's footprint a second time (512 MB written: +1 GB), and writes ran at a
        // third of the speed.
        _ = fcntl(file, F_NOCACHE, 1)
        fd = file
        capacity = UInt64(st.st_size) / UInt64(Self.blockSize) * UInt64(Self.blockSize)
        var fs = statfs()
        hostBlock = fstatfs(file, &fs) == 0 && fs.f_bsize > 0 ? UInt64(fs.f_bsize) : 4096
        config = Self.makeConfig(capacity: capacity)
    }

    // Not `close()`: the last reference may go away in a block on `queue`, which cannot sync on itself.
    deinit { if fd >= 0 { Darwin.close(fd) } }

    /// Waits for requests in flight, then closes the image and drops its lock.
    func close() {
        queue.sync {
            workers.sync(flags: .barrier) {}
            if fd >= 0 { Darwin.close(fd) }
            fd = -1
        }
    }

    /// Config space (virtio 1.x 5.2.4), little endian.
    private static func makeConfig(capacity: UInt64) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 60)
        func put<T: FixedWidthInteger>(_ offset: Int, _ value: T) {
            withUnsafeBytes(of: value.littleEndian) { c.replaceSubrange(offset..<offset + $0.count, with: $0) }
        }
        put(0, capacity / 512)          // capacity, in 512-byte sectors whatever blk_size says
        put(8, maxSegmentSize)          // size_max
        put(12, maxSegments)            // seg_max
        put(20, blockSize)              // blk_size
        put(36, maxDiscardSectors)      // max_discard_sectors
        put(40, maxDiscardRanges)       // max_discard_seg
        put(44, blockSize / 512)        // discard_sector_alignment
        put(48, maxDiscardSectors)      // max_write_zeroes_sectors
        put(52, maxDiscardRanges)       // max_write_zeroes_seg
        put(56, UInt8(1))               // write_zeroes_may_unmap
        return c
    }

    func readConfig(offset: Int, size: Int) -> UInt64 {
        guard offset >= 0, size <= 8, offset + size <= config.count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<size { value |= UInt64(config[offset + i]) << (8 * UInt64(i)) }
        return value
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
    }

    func notify(queue index: Int) {
        queue.async { self.drain() }
    }

    private func drain() {
        lock.lock()
        let transport = self.transport
        lock.unlock()
        guard let transport, fd >= 0 else { return }
        while true {
            transport.lock.lock()
            let chain = transport.queues[0].pop()
            transport.lock.unlock()
            guard let chain else { return }
            inFlight.wait()
            workers.async { [self] in
                let written = handle(chain)
                transport.lock.lock()
                transport.queues[0].push(chain, written: written)
                transport.lock.unlock()
                transport.signalUsed()
                inFlight.signal()
            }
        }
    }

    // MARK: Requests

    private enum Status: UInt8 { case ok = 0, ioError = 1, unsupported = 2 }

    /// Runs one request; returns the bytes written into the chain (data read, plus status).
    private func handle(_ chain: VirtqueueChain) -> Int {
        // The status byte is the last writable byte; the 16-byte header leads the readable ones.
        guard let last = chain.writable.last, last.count > 0 else { return 0 }
        let status = last.baseAddress!.advanced(by: last.count - 1)
        let header = gather(chain.readable, count: 16)
        guard header.count == 16 else {
            status.storeBytes(of: Status.ioError.rawValue, as: UInt8.self)
            return 1
        }
        let type = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) }
        let sector = header.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
        var written = 0
        let result: Status
        switch type {
        case 0:  // IN: read into the writable buffers, all but the status byte
            let iov = slices(chain.writable, dropFirst: 0, dropLast: 1)
            let length = iov.reduce(0) { $0 + $1.iov_len }
            result = inBounds(sector, length) && transfer(iov, at: sector * 512, write: false) ? .ok : .ioError
            if result == .ok { written = length }
        case 1:  // OUT: write the readable buffers after the header
            let iov = slices(chain.readable, dropFirst: 16, dropLast: 0)
            let length = iov.reduce(0) { $0 + $1.iov_len }
            result = inBounds(sector, length) && transfer(iov, at: sector * 512, write: true) ? .ok : .ioError
        case 4:  // FLUSH
            result = fcntl(fd, F_BARRIERFSYNC) == 0 ? .ok : .ioError
        case 8:  // GET_ID: up to 20 bytes, no terminator needed
            let id = Array(Self.id.utf8.prefix(20))
            var data = Data(id)
            data.append(contentsOf: [UInt8](repeating: 0, count: 20 - id.count))
            var trimmed = VirtqueueChain(head: chain.head)
            trimmed.writable = slices(chain.writable, dropFirst: 0, dropLast: 1).map {
                UnsafeMutableRawBufferPointer(start: $0.iov_base, count: $0.iov_len)
            }
            written = trimmed.write(data)
            result = .ok
        case 11, 13:  // DISCARD, WRITE_ZEROES: ranges of {sector u64, sectors u32, flags u32}
            // One range more than allowed is enough to refuse the request; the guest picks the size.
            let ranges = gather(chain.readable, count: 16 * (Int(Self.maxDiscardRanges) + 2)).dropFirst(16)
            var ok = ranges.count % 16 == 0 && ranges.count / 16 <= Int(Self.maxDiscardRanges)
            var offset = ranges.startIndex
            while ok, offset < ranges.endIndex {
                let (start, count) = ranges.withUnsafeBytes { raw in
                    (UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset - ranges.startIndex, as: UInt64.self)),
                     UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset - ranges.startIndex + 8, as: UInt32.self)))
                }
                let length = Int(count) * 512
                ok = count <= Self.maxDiscardSectors && inBounds(start, length)
                    && (type == 11 ? discard(start * 512, UInt64(length)) : writeZeroes(start * 512, UInt64(length)))
                offset += 16
            }
            result = ok ? .ok : .ioError
        default:
            result = .unsupported
        }
        status.storeBytes(of: result.rawValue, as: UInt8.self)
        return written + 1
    }

    private func inBounds(_ sector: UInt64, _ length: Int) -> Bool {
        let (start, overflow) = sector.multipliedReportingOverflow(by: 512)
        return !overflow && start <= capacity && UInt64(length) <= capacity - start
    }

    /// The first `count` bytes of a list of buffers.
    private func gather(_ buffers: [UnsafeMutableRawBufferPointer], count: Int) -> Data {
        var data = Data()
        for buffer in buffers where data.count < count {
            data.append(contentsOf: UnsafeRawBufferPointer(rebasing: buffer[0..<min(buffer.count, count - data.count)]))
        }
        return data
    }

    /// The buffers as iovecs, without their first `dropFirst` and last `dropLast` bytes.
    private func slices(_ buffers: [UnsafeMutableRawBufferPointer], dropFirst: Int, dropLast: Int) -> [iovec] {
        let total = buffers.reduce(0) { $0 + $1.count }
        guard total >= dropFirst + dropLast else { return [] }
        let end = total - dropLast
        var iov: [iovec] = [], position = 0
        for buffer in buffers {
            let lower = max(dropFirst, position), upper = min(end, position + buffer.count)
            if upper > lower {
                iov.append(iovec(iov_base: buffer.baseAddress!.advanced(by: lower - position), iov_len: upper - lower))
            }
            position += buffer.count
        }
        return iov
    }

    /// preadv/pwritev until every byte moved; short transfers resume where they stopped.
    private func transfer(_ vectors: [iovec], at offset: UInt64, write: Bool) -> Bool {
        var iov = vectors, index = 0, position = off_t(offset)
        while index < iov.count {
            let count = Int32(min(iov.count - index, Int(IOV_MAX)))
            let n = iov.withUnsafeMutableBufferPointer { buffer in
                write ? pwritev(fd, buffer.baseAddress! + index, count, position)
                      : preadv(fd, buffer.baseAddress! + index, count, position)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }  // an error, or the image shrank under us
            position += off_t(n)
            var left = n
            while left > 0, index < iov.count {
                if left >= iov[index].iov_len {
                    left -= iov[index].iov_len
                    index += 1
                } else {
                    iov[index].iov_base = iov[index].iov_base.advanced(by: left)
                    iov[index].iov_len -= left
                    left = 0
                }
            }
            while index < iov.count && iov[index].iov_len == 0 { index += 1 }
        }
        return true
    }

    /// Deallocates the whole host blocks inside the range. Discard is a hint: partial blocks at
    /// the edges are left alone, and a file system without holes simply keeps the blocks.
    private func discard(_ offset: UInt64, _ length: UInt64) -> Bool {
        _ = punchHole(offset, length)
        return true
    }

    /// Makes the range read as zeros: holes for whole host blocks, written zeros at the edges.
    private func writeZeroes(_ offset: UInt64, _ length: UInt64) -> Bool {
        let start = alignUp(offset, hostBlock), end = (offset + length) / hostBlock * hostBlock
        guard start < end, punchHole(start, end - start) else { return writeZeroBytes(offset, length) }
        return writeZeroBytes(offset, start - offset) && writeZeroBytes(end, offset + length - end)
    }

    private func punchHole(_ offset: UInt64, _ length: UInt64) -> Bool {
        let start = alignUp(offset, hostBlock), end = (offset + length) / hostBlock * hostBlock
        guard start < end else { return true }
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(start), fp_length: off_t(end - start))
        return fcntl(fd, F_PUNCHHOLE, &hole) == 0
    }

    /// Only for block edges, or where the host file system cannot punch holes.
    private func writeZeroBytes(_ offset: UInt64, _ length: UInt64) -> Bool {
        guard length > 0 else { return true }
        var zeros = [UInt8](repeating: 0, count: Int(min(length, 1 << 20)))
        return zeros.withUnsafeMutableBytes { buffer in
            var done: UInt64 = 0
            while done < length {
                let n = Int(min(length - done, UInt64(buffer.count)))
                guard transfer([iovec(iov_base: buffer.baseAddress, iov_len: n)], at: offset + done, write: true) else { return false }
                done += UInt64(n)
            }
            return true
        }
    }
}
