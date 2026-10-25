import Foundation

/// The FUSE wire protocol as virtio-fs carries it (Linux `include/uapi/linux/fuse.h`), and the
/// macOS to Linux translations a server on macOS needs: errno numbers, open flags and stat
/// layouts differ between the two. All integers are little endian (the guest is arm64).
enum FUSE {
    static let rootID: UInt64 = 1
    static let inHeaderSize = 40
    static let outHeaderSize = 16
    /// Protocol 7.33: everything dmx uses (max_pages, cache_symlinks, rename2, killpriv_v2)
    /// without the request extensions of later minors.
    static let major: UInt32 = 7
    static let minor: UInt32 = 33

    enum Opcode: UInt32 {
        case lookup = 1, forget, getattr, setattr, readlink, symlink
        case mknod = 8, mkdir, unlink, rmdir, rename, link, open, read, write, statfs, release
        case fsync = 20, setxattr, getxattr, listxattr, removexattr, flush, initialize, opendir, readdir, releasedir
        case fsyncdir, getlk, setlk, setlkw, access, create, interrupt, bmap, destroy, ioctl, poll, notifyReply
        case batchForget, fallocate, readdirplus, rename2, lseek, copyFileRange
        case setupMapping, removeMapping, syncfs, tmpfile, statx
    }

    /// FUSE_INIT flags (the first 32 bits; dmx needs none of flags2).
    enum InitFlag {
        static let asyncRead: UInt32 = 1 << 0
        static let atomicOTrunc: UInt32 = 1 << 3
        static let bigWrites: UInt32 = 1 << 5
        static let autoInvalData: UInt32 = 1 << 12
        static let doReaddirplus: UInt32 = 1 << 13
        static let readdirplusAuto: UInt32 = 1 << 14
        static let asyncDIO: UInt32 = 1 << 15
        static let parallelDirops: UInt32 = 1 << 18
        static let maxPages: UInt32 = 1 << 22
        static let cacheSymlinks: UInt32 = 1 << 23
        static let handleKillprivV2: UInt32 = 1 << 28
    }

    /// fuse_setattr_in.valid
    enum SetattrValid {
        static let mode: UInt32 = 1 << 0
        static let uid: UInt32 = 1 << 1
        static let gid: UInt32 = 1 << 2
        static let size: UInt32 = 1 << 3
        static let atime: UInt32 = 1 << 4
        static let mtime: UInt32 = 1 << 5
        static let fh: UInt32 = 1 << 6
        static let atimeNow: UInt32 = 1 << 7
        static let mtimeNow: UInt32 = 1 << 8
        static let killSUIDGID: UInt32 = 1 << 11
    }

    /// fuse_write_in.write_flags and fuse_open_in.open_flags
    static let writeKillSUIDGID: UInt32 = 1 << 2
    static let openKillSUIDGID: UInt32 = 1 << 0

    static let getattrFH: UInt32 = 1
    static let attrSize = 88
    static let entrySize = 40 + attrSize
}

/// Linux values the guest sends or expects.
enum Linux {
    // Open flags (asm-generic, which arm64 uses except for the directory bits below).
    static let O_ACCMODE: UInt32 = 0o3
    static let O_CREAT: UInt32 = 0o100
    static let O_EXCL: UInt32 = 0o200
    static let O_TRUNC: UInt32 = 0o1000
    static let O_APPEND: UInt32 = 0o2000
    static let O_DSYNC: UInt32 = 0o10000
    static let O_DIRECT: UInt32 = 0o200000  // arm64
    static let O_SYNC: UInt32 = 0o4010000

    static let RENAME_NOREPLACE: UInt32 = 1
    static let RENAME_EXCHANGE: UInt32 = 2

    static let ENOENT: Int32 = 2, EIO: Int32 = 5, EBADF: Int32 = 9, EACCES: Int32 = 13, EEXIST: Int32 = 17
    static let ENOTDIR: Int32 = 20, EISDIR: Int32 = 21, EINVAL: Int32 = 22, ENFILE: Int32 = 23
    static let EROFS: Int32 = 30, ERANGE: Int32 = 34, ENAMETOOLONG: Int32 = 36, ENOSYS: Int32 = 38
    static let EPERM: Int32 = 1, ESTALE: Int32 = 116, ENODATA: Int32 = 61, EOPNOTSUPP: Int32 = 95

    static let XATTR_CREATE: UInt32 = 1
    static let XATTR_REPLACE: UInt32 = 2

    /// macOS errno to Linux. 1 to 34 match except 11 (EDEADLK on macOS, EAGAIN on Linux).
    static func errno(_ e: Int32) -> Int32 {
        switch e {
        case 1...10, 12...34: return e
        case Darwin.EDEADLK: return 35
        case Darwin.EAGAIN: return 11
        case Darwin.EINPROGRESS: return 115
        case Darwin.EALREADY: return 114
        case Darwin.ENOTSOCK: return 88
        case Darwin.EDESTADDRREQ: return 89
        case Darwin.EMSGSIZE: return 90
        case Darwin.EPROTOTYPE: return 91
        case Darwin.ENOPROTOOPT: return 92
        case Darwin.EPROTONOSUPPORT: return 93
        case Darwin.ENOTSUP, Darwin.EOPNOTSUPP: return 95
        case Darwin.EADDRINUSE: return 98
        case Darwin.EADDRNOTAVAIL: return 99
        case Darwin.ENETDOWN: return 100
        case Darwin.ENETUNREACH: return 101
        case Darwin.ECONNABORTED: return 103
        case Darwin.ECONNRESET: return 104
        case Darwin.ENOBUFS: return 105
        case Darwin.EISCONN: return 106
        case Darwin.ENOTCONN: return 107
        case Darwin.ETIMEDOUT: return 110
        case Darwin.ECONNREFUSED: return 111
        case Darwin.ELOOP: return 40
        case Darwin.ENAMETOOLONG: return 36
        case Darwin.EHOSTUNREACH: return 113
        case Darwin.ENOTEMPTY: return 39
        case Darwin.EUSERS: return 87
        case Darwin.EDQUOT: return 122
        case Darwin.ESTALE: return 116
        case Darwin.ENOLCK: return 37
        case Darwin.ENOSYS: return 38
        case Darwin.EOVERFLOW: return 75
        case Darwin.ECANCELED: return 125
        case Darwin.EIDRM: return 43
        case Darwin.ENOMSG: return 42
        case Darwin.EILSEQ: return 84
        case Darwin.ENOATTR: return 61  // ENODATA
        case Darwin.EBADMSG: return 74
        case Darwin.EMULTIHOP: return 72
        case Darwin.ENODATA: return 61
        case Darwin.ENOLINK: return 67
        case Darwin.ENOSR: return 63
        case Darwin.ENOSTR: return 60
        case Darwin.EPROTO: return 71
        case Darwin.ETIME: return 62
        case Darwin.EFTYPE: return 22
        default: return EIO
        }
    }

    /// A macOS dev_t (8-bit major, 24-bit minor) in Linux's encoding.
    static func dev(_ d: Int32) -> UInt32 {
        let major = (UInt32(bitPattern: d) >> 24) & 0xff, minor = UInt32(bitPattern: d) & 0xff_ffff
        return (minor & 0xff) | (major << 8) | ((minor & ~0xff) << 12)
    }
}

/// Reads little endian fields from a request, front to back.
struct FUSEReader {
    let data: Data
    var offset: Int

    init(_ data: Data, at offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    mutating func u32() throws -> UInt32 { try value(UInt32.self) }
    mutating func u64() throws -> UInt64 { try value(UInt64.self) }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw FUSEError(Linux.EINVAL) }
        defer { offset += n }
        return data.subdata(in: data.startIndex + offset..<data.startIndex + offset + n)
    }

    mutating func skip(_ n: Int) throws {
        guard remaining >= n else { throw FUSEError(Linux.EINVAL) }
        offset += n
    }

    private mutating func value<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw FUSEError(Linux.EINVAL) }
        let v = data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
        offset += size
        return v
    }

    /// A NUL-terminated string. Linux names are bytes; macOS file systems want UTF-8.
    mutating func string() throws -> String {
        let bytes = data.withUnsafeBytes { Array($0[offset...]) }
        guard let end = bytes.firstIndex(of: 0) else { throw FUSEError(Linux.EINVAL) }
        offset += end + 1
        guard let s = String(validating: bytes[..<end], as: UTF8.self) else { throw FUSEError(Linux.EINVAL) }
        return s
    }

    /// A directory entry name: one path component, never `.` or `..`.
    mutating func name() throws -> String {
        let s = try string()
        guard !s.isEmpty, s != ".", s != "..", !s.contains("/") else { throw FUSEError(Linux.EINVAL) }
        guard s.utf8.count <= 255 else { throw FUSEError(Linux.ENAMETOOLONG) }
        return s
    }
}

/// Builds a reply body.
struct FUSEWriter {
    var data = Data()

    init(capacity: Int = 128) { data.reserveCapacity(capacity) }

    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func zeros(_ n: Int) { data.append(contentsOf: repeatElement(0, count: n)) }
    mutating func bytes(_ s: String) { data.append(contentsOf: s.utf8) }
    mutating func pad8() { zeros((8 - data.count % 8) % 8) }
}

/// A Linux errno to answer a request with.
struct FUSEError: Error {
    let errno: Int32
    init(_ errno: Int32) { self.errno = errno }
    /// The current macOS errno, translated.
    static var last: FUSEError { FUSEError(Linux.errno(Darwin.errno)) }
}
