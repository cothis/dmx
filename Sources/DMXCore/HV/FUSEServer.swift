import Foundation

/// The host side of one share: answers FUSE requests from the guest on a host directory tree.
/// Thread safe; virtio-fs hands it several requests at once.
///
/// What it guarantees, since the guest is less trusted than the host:
/// - Every host path it touches is beneath the share's root. A path is built only from names the
///   guest sent (one component each: never empty, `.`, `..` or containing `/`), relative to a
///   descriptor of the root, and opened with `O_NOFOLLOW_ANY`, so a symlink anywhere on the way
///   fails the call instead of being followed. The last component is acted on with `*at` calls
///   that do not follow it either. Symlinks reach the guest as links, which the guest kernel
///   resolves inside the guest.
/// - A read-only share refuses every request that would change the host (`EROFS`).
/// - Files are created and changed as the user running dmx. dmx never chowns, and drops setuid
///   and setgid bits from modes the guest sets, so the guest cannot plant a setuid program.
/// Not guaranteed: a symlink the guest creates may point anywhere on the host, and host programs
/// that follow it do so with the user's rights (the guest can write such files' contents into the
/// share just as well). The stored owner is read by path (macOS has no `getxattrat`), so a guest
/// racing renames could make dmx read that one attribute of a file outside the share; it is
/// written only through a descriptor. Directories the guest used recently stay open, so one the
/// host user moves out of the share stays reachable under its old node until the guest forgets
/// it, as an open file would.
///
/// Ownership: files owned by the host user appear owned by root (uid and gid 0) in the guest,
/// everything else by nobody (65534), unless the guest stored an owner: chown by guest root, and
/// files a non-root guest user creates, keep the guest's uid and gid in the host extended
/// attribute `com.dmx.owner` (like Docker's osxfs did with `com.docker.owner`). The guest kernel
/// checks permissions against the owner it sees (virtio-fs always mounts with
/// default_permissions), so a non-root container user can write where it was given ownership,
/// and programs that check owners (postgres, git, ssh) are satisfied. The host checks every
/// access again as the host user. Reading the attribute costs ~2 µs per file without one and
/// ~10 µs with one, so it is cached per node until the file's ctime changes.
///
/// Extended attributes: the guest sees and changes only `user.*` attributes, stored under the
/// same names on the host. Host attributes in other namespaces (quarantine, provenance, the stored
/// owner) stay invisible and unchangeable, and so does `security.capability`.
///
/// Unix sockets: a guest program that binds a socket in a share gets a host socket file at that
/// path, and other guest programs connect to it through the guest kernel. Host programs cannot
/// connect to it, nor guest programs to host sockets: the two kernels' sockets are not joined.
///
/// Inodes are tracked by host (device, inode) with the guest's lookup count, and found again by
/// path (parent node and name). If the host renames or replaces a file, the old node's path no
/// longer leads to the same inode and requests on it fail with `ESTALE`, which makes the guest
/// kernel look the path up again.
final class FUSEServer: @unchecked Sendable {
    let root: String
    let readOnly: Bool
    private let rootFD: Int32
    private let rootInode: Inode
    private let hostUID = getuid()
    /// Seconds the guest may cache names (also missing ones) and attributes without asking again.
    /// Host changes show up in the guest within this time; opens see them at once (`openNode`).
    /// With 0 for attributes, untarring 9,200 files took 65 s instead of 23 and `ls -lR` 3.2 s
    /// instead of 0.35.
    private let ttl: UInt64 = 1
    /// Open files and directories the guest may hold at once.
    private let handleLimit = 4096

    private struct Inode: Hashable {
        let dev: Int32
        let ino: UInt64
        init(_ st: stat) { dev = st.st_dev; ino = st.st_ino }
    }

    private final class Node {
        var parent: UInt64
        var name: String
        let inode: Inode
        var lookups: UInt64 = 0
        var children = 0
        /// Size and mtime the guest was last told, nil after it wrote; see `openNode`.
        var seen: Version?
        var refusedOpen = false
        /// The owner the guest was told, valid while the host ctime is `ownerChange`.
        var owner: (uid: UInt32, gid: UInt32)?
        var ownerChange: Change?
        init(parent: UInt64, name: String, inode: Inode) { self.parent = parent; self.name = name; self.inode = inode }
    }

    /// Attributes as the guest is told them: the host's, with the owner the guest sees.
    private struct Attr {
        var st: stat
        var uid: UInt32, gid: UInt32
    }

    /// The guest user a request runs as (from the FUSE in-header).
    struct Caller {
        var uid: UInt32 = 0, gid: UInt32 = 0
        static let root = Caller()
    }

    /// Holds the owner the guest set, as "uid:gid" in decimal.
    static let ownerAttribute = "com.dmx.owner"

    private struct Change: Equatable {
        let sec: Int, nsec: Int
        init(_ st: stat) { sec = st.st_ctimespec.tv_sec; nsec = st.st_ctimespec.tv_nsec }
    }

    private struct Version: Equatable {
        let size: Int64, sec: Int, nsec: Int
        init(_ st: stat) { size = st.st_size; sec = st.st_mtimespec.tv_sec; nsec = st.st_mtimespec.tv_nsec }
    }

    private final class Directory {
        let dir: UnsafeMutablePointer<DIR>
        let node: UInt64
        let lock = NSLock()
        var entries: [(name: String, ino: UInt64, type: UInt8)] = []
        var loaded = false
        init(dir: UnsafeMutablePointer<DIR>, node: UInt64) { self.dir = dir; self.node = node }
        deinit { closedir(dir) }
        var fd: Int32 { dirfd(dir) }
    }

    private enum Handle {
        case file(Int32, node: UInt64)
        case directory(Directory)
    }

    private let lock = NSLock()
    private var nodes: [UInt64: Node] = [:]
    private var byInode: [Inode: UInt64] = [:]
    private var nextNode: UInt64 = 2
    private var handles: [UInt64: Handle] = [:]
    private var nextHandle: UInt64 = 1
    private lazy var rootDir = DirFD(fd: rootFD, owned: false)
    private var dirCache: [UInt64: DirFD] = [:]
    private let dirCacheLimit = 256
    private var useClock: UInt64 = 0

    /// Opens the share's root; symlinks in `path` itself are followed (the user chose it).
    init(path: String, readOnly: Bool) throws {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            throw DMXError("share_missing", "cannot share \(path): \(String(cString: strerror(errno)))",
                           hint: "create the directory, or change the shares: `dmx config set shares ~`")
        }
        var st = stat()
        fstat(fd, &st)
        rootFD = fd
        rootInode = Inode(st)
        root = path
        self.readOnly = readOnly
        let node = Node(parent: 0, name: "", inode: rootInode)
        nodes[FUSE.rootID] = node
        byInode[rootInode] = FUSE.rootID
        Self.raiseFileLimit()
    }

    deinit {
        closeAll()
        close(rootFD)
    }

    /// The default limit of 256 descriptors would run out with a few guest builds open.
    private static func raiseFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let want = min(limit.rlim_max, rlim_t(OPEN_MAX))
        if limit.rlim_cur < want {
            limit.rlim_cur = want
            setrlimit(RLIMIT_NOFILE, &limit)
        }
    }

    /// Closes every open file and forgets every node but the root (VM stop, device reset).
    func closeAll() {
        lock.lock()
        let open = handles.values
        handles.removeAll()
        nodes = nodes.filter { $0.key == FUSE.rootID }
        byInode = [rootInode: FUSE.rootID]
        dirCache.removeAll()
        lock.unlock()
        for handle in open { release(handle) }
    }

    // MARK: Requests

    enum Reply {
        case none            // FORGET and friends: the guest expects no answer
        case error(Int32)    // a Linux errno
        case data(Data)
        case direct(Int)     // READ: this many bytes went straight into the guest's buffers
    }

    /// Answers one request from `caller`. `args` is what follows the in-header; for WRITE, only
    /// fuse_write_in, with the data in `input`. READ fills `output`, the guest buffers after the
    /// out-header.
    func handle(opcode raw: UInt32, node: UInt64, caller: Caller = .root, args: Data, input: [iovec], output: [iovec]) -> Reply {
        guard let opcode = FUSE.Opcode(rawValue: raw) else { return .error(Linux.ENOSYS) }
        var r = FUSEReader(args)
        do {
            if readOnly && Self.writes.contains(opcode) { throw FUSEError(Linux.EROFS) }
            switch opcode {
            case .initialize: return .data(try initialize(&r))
            case .destroy: closeAll(); return .data(Data())
            case .forget: forget(node, try r.u64()); return .none
            case .batchForget:
                let count = try r.u32()
                try r.skip(4)
                for _ in 0..<min(count, UInt32(r.remaining / 16)) { forget(try r.u64(), try r.u64()) }
                return .none
            case .interrupt: return .none
            case .lookup: return .data(try lookup(node, try r.name()))
            case .getattr:
                let flags = try r.u32()
                try r.skip(4)
                let fh = try r.u64()
                return .data(attrReply(seen(node, try getattr(node, fh: flags & FUSE.getattrFH != 0 ? fh : nil))))
            case .setattr: return .data(attrReply(seen(node, try setattr(node, caller, &r))))
            case .readlink: return .data(try readLink(node))
            case .symlink:
                let name = try r.name(), target = try r.string()
                guard !target.isEmpty, target.utf8.count < PATH_MAX else { throw FUSEError(Linux.EINVAL) }
                return .data(try create(in: node, name, caller) { fd, name in symlinkat(target, fd, name) })
            case .mknod: return .data(try makeNode(node, caller, &r))
            case .mkdir:
                let mode = try r.u32()
                try r.skip(4)
                let name = try r.name()
                return .data(try create(in: node, name, caller, mode: mode) { fd, name in mkdirat(fd, name, 0o700) })
            case .unlink: try remove(node, try r.name(), flags: 0); return .data(Data())
            case .rmdir: try remove(node, try r.name(), flags: AT_REMOVEDIR); return .data(Data())
            case .rename:
                let to = try r.u64()
                try renameNode(node, try r.name(), to, try r.name(), flags: 0)
                return .data(Data())
            case .rename2:
                let to = try r.u64(), flags = try r.u32()
                try r.skip(4)
                try renameNode(node, try r.name(), to, try r.name(), flags: flags)
                return .data(Data())
            case .link: return .data(try linkNode(try r.u64(), to: node, try r.name()))
            case .open:
                let flags = try r.u32(), openFlags = try r.u32()
                return .data(try openNode(node, flags: flags, dropSetID: openFlags & FUSE.openKillSUIDGID != 0))
            case .create: return .data(try create(node, caller, &r))
            case .read: return .direct(try readFile(&r, output))
            case .write: return .data(try writeFile(&r, input))
            case .statfs: return .data(try fsStats())
            case .release, .releasedir:
                let fh = try r.u64()
                lock.lock()
                let handle = handles.removeValue(forKey: fh)
                lock.unlock()
                if let handle { release(handle) }
                return .data(Data())
            case .flush: return .data(Data())  // nothing is buffered on the host
            case .fsync, .fsyncdir:
                let fh = try r.u64()
                let fd = try duplicateDescriptor(fh)
                defer { close(fd) }
                guard fsync(fd) == 0 else { throw FUSEError.last }
                return .data(Data())
            case .opendir: return .data(try openDir(node))
            case .readdir, .readdirplus: return .data(try readDir(&r, plus: opcode == .readdirplus))
            case .getxattr:
                let size = try r.u32()
                try r.skip(4)
                return .data(try getXattr(node, try r.string(), size: Int(size)))
            case .listxattr:
                let size = try r.u32()
                try r.skip(4)
                return .data(try listXattr(node, size: Int(size)))
            case .setxattr:
                let size = try r.u32(), flags = try r.u32()
                let name = try r.string()
                try setXattr(node, name, try r.bytes(Int(size)), flags: flags)
                return .data(Data())
            case .removexattr:
                try removeXattr(node, try r.string())
                return .data(Data())
            default:
                // Not offered: locks (the guest keeps them locally), fallocate, lseek, ioctl, poll,
                // copy_file_range, tmpfile, statx, syncfs, DAX. ENOSYS makes the guest stop asking
                // and fall back.
                return .error(Linux.ENOSYS)
            }
        } catch let error as FUSEError {
            return .error(error.errno)
        } catch {
            return .error(Linux.EIO)
        }
    }

    private static let writes: Set<FUSE.Opcode> = [
        .setattr, .symlink, .mknod, .mkdir, .unlink, .rmdir, .rename, .rename2, .link, .create, .write,
        .setxattr, .removexattr, .fallocate, .copyFileRange, .tmpfile,
    ]

    private func initialize(_ r: inout FUSEReader) throws -> Data {
        let major = try r.u32(), minor = try r.u32(), readahead = try r.u32(), flags = try r.u32()
        var w = FUSEWriter(capacity: 64)
        guard major == FUSE.major else {
            // A newer major: answer with ours and the kernel retries or gives up.
            w.u32(FUSE.major); w.zeros(60)
            return w.data
        }
        let wanted = FUSE.InitFlag.asyncRead | FUSE.InitFlag.atomicOTrunc | FUSE.InitFlag.bigWrites
            | FUSE.InitFlag.autoInvalData | FUSE.InitFlag.doReaddirplus | FUSE.InitFlag.readdirplusAuto
            | FUSE.InitFlag.asyncDIO | FUSE.InitFlag.parallelDirops | FUSE.InitFlag.maxPages
            | FUSE.InitFlag.cacheSymlinks | FUSE.InitFlag.handleKillprivV2
        w.u32(FUSE.major)
        w.u32(min(minor, FUSE.minor))
        w.u32(readahead)
        w.u32(flags & wanted)
        w.u16(32)            // max_background
        w.u16(24)            // congestion_threshold
        w.u32(1 << 20)       // max_write
        w.u32(1)             // time_gran: nanoseconds
        w.u16(256)           // max_pages; the kernel caps it at the queue size and max_write
        w.u16(0)             // map_alignment
        w.u32(0)             // flags2
        w.zeros(64 - w.data.count)
        return w.data
    }

    // MARK: Nodes

    private func node(_ id: UInt64) throws -> Node {
        lock.lock()
        defer { lock.unlock() }
        guard let node = nodes[id] else { throw FUSEError(Linux.ESTALE) }
        return node
    }

    /// The path of a node relative to the root ("" for the root), from the names in the table.
    private func path(_ id: UInt64) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        var names: [String] = []
        var id = id
        while id != FUSE.rootID {
            guard let node = nodes[id], names.count < 4096 else { throw FUSEError(Linux.ESTALE) }
            names.append(node.name)
            id = node.parent
        }
        return names.reversed().joined(separator: "/")
    }

    /// An open directory, closed when the last request using it is done (never the root's).
    private final class DirFD {
        let fd: Int32
        let owned: Bool
        var lastUse: UInt64 = 0
        init(fd: Int32, owned: Bool) { self.fd = fd; self.owned = owned }
        deinit { if owned { close(fd) } }
    }

    /// Opens a node that must be a directory, beneath the root and through no symlink. Recently
    /// used directories stay open, so most requests skip the path walk; a cached directory the
    /// host renames is still the node's (as with an open file), even if moved out of the share.
    private func openDirectory(_ id: UInt64) throws -> DirFD {
        if id == FUSE.rootID { return rootDir }
        lock.lock()
        useClock += 1
        if let dir = dirCache[id] {
            dir.lastUse = useClock
            lock.unlock()
            return dir
        }
        lock.unlock()
        let expected = try node(id).inode
        let fd = openat(rootFD, try path(id), O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw stale() }
        let dir = DirFD(fd: fd, owned: true)
        var st = stat()
        guard fstat(fd, &st) == 0, Inode(st) == expected else { throw FUSEError(Linux.ESTALE) }
        lock.lock()
        defer { lock.unlock() }
        if nodes[id] != nil {
            if dirCache.count >= dirCacheLimit, let oldest = dirCache.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                dirCache[oldest.key] = nil
            }
            dir.lastUse = useClock
            dirCache[id] = dir
        }
        return dir
    }

    /// Runs `body` with a directory node's descriptor, kept open until `body` returns.
    private func withDirectory<T>(_ id: UInt64, _ body: (Int32) throws -> T) throws -> T {
        let dir = try openDirectory(id)
        return try withExtendedLifetime(dir) { try body(dir.fd) }
    }

    /// Runs `body` with a node's parent directory and its name there, after checking that the
    /// name still leads to the node's inode. For the root: the root and ".".
    private func withNode<T>(_ id: UInt64, _ body: (Int32, String, stat) throws -> T) throws -> T {
        lock.lock()
        guard let node = nodes[id] else { lock.unlock(); throw FUSEError(Linux.ESTALE) }
        let (parentID, name, inode) = (node.parent, id == FUSE.rootID ? "." : node.name, node.inode)
        lock.unlock()
        let parent = id == FUSE.rootID ? rootDir : try openDirectory(parentID)
        var st = stat()
        guard fstatat(parent.fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw stale() }
        guard Inode(st) == inode else { throw FUSEError(Linux.ESTALE) }
        return try withExtendedLifetime(parent) { try body(parent.fd, name, st) }
    }

    /// A path that no longer resolves: ENOENT and ENOTDIR become ESTALE, so the guest kernel
    /// looks the name up again instead of failing.
    private func stale() -> FUSEError {
        let e = errno
        return FUSEError(e == ENOENT || e == ENOTDIR || e == ELOOP ? Linux.ESTALE : Linux.errno(e))
    }

    /// Counts a lookup of `name` in `parent` that found `st`, and returns the node's id.
    private func remember(_ parent: UInt64, _ name: String, _ a: Attr) -> UInt64 {
        let st = a.st
        let inode = Inode(st)
        lock.lock()
        defer { lock.unlock() }
        if let id = byInode[inode], let node = nodes[id] {
            node.lookups += 1
            node.seen = Version(st)
            node.owner = (a.uid, a.gid)
            node.ownerChange = Change(st)
            if id != FUSE.rootID, node.parent != parent || node.name != name, nodes[parent] != nil {
                // Found under another name: the host renamed it, or a hard link.
                let old = node.parent
                node.parent = parent
                node.name = name
                nodes[parent]!.children += 1
                nodes[old]?.children -= 1
                drop(old)
            }
            return id
        }
        let id = nextNode
        nextNode += 1
        let node = Node(parent: parent, name: name, inode: inode)
        node.lookups = 1
        node.seen = Version(st)
        node.owner = (a.uid, a.gid)
        node.ownerChange = Change(st)
        nodes[id] = node
        byInode[inode] = id
        nodes[parent]?.children += 1
        return id
    }

    /// Notes the attributes the guest is about to be told.
    private func seen(_ id: UInt64, _ a: Attr) -> Attr {
        lock.lock()
        nodes[id]?.seen = Version(a.st)
        lock.unlock()
        return a
    }

    private func forget(_ id: UInt64, _ count: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard id != FUSE.rootID, let node = nodes[id] else { return }
        node.lookups -= min(count, node.lookups)
        drop(id)
    }

    /// Removes nodes the guest no longer knows and that have no known children. Under `lock`.
    private func drop(_ id: UInt64) {
        var id = id
        while id != FUSE.rootID, let node = nodes[id], node.lookups == 0, node.children == 0 {
            nodes[id] = nil
            dirCache[id] = nil
            if byInode[node.inode] == id { byInode[node.inode] = nil }
            id = node.parent
            nodes[id]?.children -= 1
        }
    }

    /// Points a node at a new parent and name after a rename the guest asked for.
    private func moved(_ inode: Inode, to parent: UInt64, _ name: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let id = byInode[inode], id != FUSE.rootID, let node = nodes[id], nodes[parent] != nil else { return }
        let old = node.parent
        node.parent = parent
        node.name = name
        nodes[parent]!.children += 1
        nodes[old]?.children -= 1
        drop(old)
    }

    // MARK: Attributes

    /// The owner the guest sees when none is stored: root for the host user's files, else nobody.
    private func defaultOwner(_ st: stat) -> (uid: UInt32, gid: UInt32) {
        st.st_uid == hostUID ? (0, 0) : (65534, 65534)
    }

    /// `st` with the owner the guest sees, for `name` in directory `fd`, or `fd` itself without a name.
    private func attr(_ st: stat, _ fd: Int32, _ name: String?) -> Attr {
        let inode = Inode(st), change = Change(st)
        lock.lock()
        let node = byInode[inode].flatMap { nodes[$0] }
        let cached = node?.ownerChange == change ? node?.owner : nil
        lock.unlock()
        if let cached { return Attr(st: st, uid: cached.uid, gid: cached.gid) }
        let stored = if let name {
            withPath(fd, name) { path in
                storedOwner { listxattr(path, $0, $1, XATTR_NOFOLLOW) } get: { getxattr(path, Self.ownerAttribute, $0, $1, 0, XATTR_NOFOLLOW) }
            }
        } else {
            storedOwner { flistxattr(fd, $0, $1, 0) } get: { fgetxattr(fd, Self.ownerAttribute, $0, $1, 0, 0) }
        }
        let owner = stored ?? defaultOwner(st)
        if let node {
            lock.lock()
            node.owner = owner
            node.ownerChange = change
            lock.unlock()
        }
        return Attr(st: st, uid: owner.uid, gid: owner.gid)
    }

    /// Runs `body` with the host path of `name` in directory `fd`, built without allocating
    /// (this runs for every entry the guest is told about).
    private func withPath<T>(_ fd: Int32, _ name: String, _ body: (UnsafePointer<CChar>) -> T?) -> T? {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(MAXPATHLEN) + 2) { buffer in
            let base = buffer.baseAddress!
            guard fcntl(fd, F_GETPATH, base) == 0 else { return nil }
            if name != "." {
                var end = strlen(base)
                let fits: Bool = name.utf8.withContiguousStorageIfAvailable { bytes in
                    guard end + 1 + bytes.count < buffer.count else { return false }
                    base[end] = 0x2f  // "/"
                    end += 1
                    UnsafeMutableRawPointer(base + end).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
                    base[end + bytes.count] = 0
                    return true
                } ?? false
                guard fits else { return nil }
            }
            return body(base)
        }
    }

    private static let ownerName = Array(ownerAttribute.utf8)

    /// The owner in `ownerAttribute`, if any, through `list` (listxattr) and `get` (getxattr).
    /// Lists the names first: on APFS asking for a missing attribute takes ~10 µs, listing ~1.7 µs.
    private func storedOwner(list: (UnsafeMutablePointer<CChar>, Int) -> Int,
                             get: (UnsafeMutableRawPointer, Int) -> Int) -> (uid: UInt32, gid: UInt32)? {
        let present: Bool = withUnsafeTemporaryAllocation(of: CChar.self, capacity: 512) { names in
            let n = list(names.baseAddress!, names.count)
            if n < 0 { return errno == ERANGE }  // more names than fit here: ask for it directly
            return Self.ownerName.withUnsafeBytes { owner in
                var i = 0
                while i < n {
                    let length = strnlen(names.baseAddress! + i, n - i)
                    if length == owner.count && memcmp(names.baseAddress! + i, owner.baseAddress!, length) == 0 { return true }
                    i += length + 1
                }
                return false
            }
        }
        guard present else { return nil }
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { value in
            let m = get(value.baseAddress!, value.count)
            guard m > 0 else { return nil }
            let parts = String(decoding: value[..<m], as: UTF8.self).split(separator: ":")
            guard parts.count == 2, let uid = UInt32(parts[0]), let gid = UInt32(parts[1]) else { return nil }
            return (uid, gid)
        }
    }

    /// Stores the owner the guest gave `name` in `dirfd` (whose attributes are `st`), or removes
    /// the stored one when `owner` is the default. Written through a descriptor of the file, never
    /// a path. A file the host user cannot write gets owner write permission for the moment it
    /// takes, as root in the guest could chown it anyway. Sockets and devices keep no owner.
    private func storeOwner(_ dirfd: Int32, _ name: String, _ st: stat, _ owner: (uid: UInt32, gid: UInt32)) throws {
        let type = st.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR || type == S_IFLNK || type == S_IFIFO else { return }
        let remove = owner == defaultOwner(st)
        let value = Array("\(owner.uid):\(owner.gid)".utf8)
        func attempt() -> Int32 {
            let fd = openat(dirfd, name, O_RDONLY | (type == S_IFLNK ? O_SYMLINK : O_NOFOLLOW) | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return errno }
            defer { close(fd) }
            var now = stat()
            guard fstat(fd, &now) == 0, Inode(now) == Inode(st) else { return ESTALE }
            if remove {
                return fremovexattr(fd, Self.ownerAttribute, 0) == 0 || errno == ENOATTR ? 0 : errno
            }
            return fsetxattr(fd, Self.ownerAttribute, value, value.count, 0, 0) == 0 ? 0 : errno
        }
        var error = attempt()
        if error == EACCES, st.st_uid == hostUID, type != S_IFLNK {
            let mode = st.st_mode & 0o7777
            if fchmodat(dirfd, name, mode | S_IRUSR | S_IWUSR, AT_SYMLINK_NOFOLLOW) == 0 {
                error = attempt()
                fchmodat(dirfd, name, mode, AT_SYMLINK_NOFOLLOW)
            }
        }
        guard error == 0 else { throw FUSEError(error == ESTALE ? Linux.ESTALE : Linux.errno(error)) }
    }

    private func putAttr(_ w: inout FUSEWriter, _ a: Attr) {
        let st = a.st
        w.u64(st.st_ino)
        w.u64(UInt64(bitPattern: st.st_size))
        w.u64(UInt64(bitPattern: st.st_blocks))
        w.u64(UInt64(bitPattern: Int64(st.st_atimespec.tv_sec)))
        w.u64(UInt64(bitPattern: Int64(st.st_mtimespec.tv_sec)))
        w.u64(UInt64(bitPattern: Int64(st.st_ctimespec.tv_sec)))
        w.u32(UInt32(st.st_atimespec.tv_nsec))
        w.u32(UInt32(st.st_mtimespec.tv_nsec))
        w.u32(UInt32(st.st_ctimespec.tv_nsec))
        w.u32(UInt32(st.st_mode))  // S_IF* and permission bits are the same on Linux
        w.u32(UInt32(st.st_nlink))
        w.u32(a.uid)
        w.u32(a.gid)
        let type = st.st_mode & S_IFMT
        w.u32(type == S_IFCHR || type == S_IFBLK ? Linux.dev(st.st_rdev) : 0)
        w.u32(UInt32(max(st.st_blksize, 512)))
        w.u32(0)
    }

    private func attrReply(_ a: Attr) -> Data {
        var w = FUSEWriter(capacity: 16 + FUSE.attrSize)
        w.u64(ttl); w.u32(0); w.u32(0)
        putAttr(&w, a)
        return w.data
    }

    private func putEntry(_ w: inout FUSEWriter, _ id: UInt64, _ a: Attr) {
        w.u64(id); w.u64(0)          // nodeid, generation
        w.u64(ttl); w.u64(ttl)       // entry and attribute timeouts
        w.u32(0); w.u32(0)
        putAttr(&w, a)
    }

    private func entryReply(_ id: UInt64, _ a: Attr) -> Data {
        var w = FUSEWriter(capacity: FUSE.entrySize)
        putEntry(&w, id, a)
        return w.data
    }

    // MARK: Operations

    private func lookup(_ parent: UInt64, _ name: String) throws -> Data {
        var st = stat()
        var found: Attr?
        let error = try withDirectory(parent) { fd in
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return errno }
            found = attr(st, fd, name)
            return 0
        }
        guard error == 0, let found else {
            // Remembered by the guest for the same time as a name that exists.
            guard error == ENOENT else { throw FUSEError(Linux.errno(error)) }
            var w = FUSEWriter(capacity: FUSE.entrySize)
            w.u64(0); w.u64(0); w.u64(ttl); w.u64(0); w.u32(0); w.u32(0)
            w.zeros(FUSE.attrSize)
            return w.data
        }
        return entryReply(remember(parent, name, found), found)
    }

    private func getattr(_ id: UInt64, fh: UInt64?) throws -> Attr {
        var st = stat()
        if let fh, let fd = try? duplicateDescriptor(fh) {
            defer { close(fd) }
            guard fstat(fd, &st) == 0 else { throw FUSEError.last }
            return attr(st, fd, nil)
        }
        if id == FUSE.rootID {
            guard fstat(rootFD, &st) == 0 else { throw FUSEError.last }
            return attr(st, rootFD, nil)
        }
        return try withNode(id) { dirfd, name, st in attr(st, dirfd, name) }
    }

    private func setattr(_ id: UInt64, _ caller: Caller, _ r: inout FUSEReader) throws -> Attr {
        let valid = try r.u32()
        try r.skip(4)
        let fh = try r.u64(), size = try r.u64()
        try r.skip(8)
        let atime = try r.u64(), mtime = try r.u64()
        try r.skip(8)
        let atimensec = try r.u32(), mtimensec = try r.u32()
        try r.skip(4)
        let mode = try r.u32()
        try r.skip(4)
        let uid = try r.u32(), gid = try r.u32()
        let file = valid & FUSE.SetattrValid.fh != 0 ? try duplicateDescriptor(fh) : nil
        defer { if let file { close(file) } }

        func apply(_ dirfd: Int32, _ name: String) throws {
            if valid & FUSE.SetattrValid.mode != 0 {
                let m = mode_t(mode & 0o7777 & ~0o6000)
                let ok = file.map { fchmod($0, m) } ?? fchmodat(dirfd, name, m, AT_SYMLINK_NOFOLLOW)
                guard ok == 0 else { throw FUSEError.last }
            }
            if valid & FUSE.SetattrValid.size != 0 {
                guard size <= UInt64(Int64.max) else { throw FUSEError(Linux.EINVAL) }
                if let file {
                    guard ftruncate(file, off_t(size)) == 0 else { throw FUSEError.last }
                } else {
                    let fd = openat(dirfd, name, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard fd >= 0 else { throw FUSEError.last }
                    defer { close(fd) }
                    guard ftruncate(fd, off_t(size)) == 0 else { throw FUSEError.last }
                }
            }
            let times = FUSE.SetattrValid.atime | FUSE.SetattrValid.mtime | FUSE.SetattrValid.atimeNow | FUSE.SetattrValid.mtimeNow
            if valid & times != 0 {
                func spec(_ set: UInt32, _ now: UInt32, _ sec: UInt64, _ nsec: UInt32) -> timespec {
                    if valid & now != 0 { return timespec(tv_sec: 0, tv_nsec: Int(UTIME_NOW)) }
                    if valid & set != 0 { return timespec(tv_sec: Int(Int64(bitPattern: sec)), tv_nsec: Int(nsec)) }
                    return timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))
                }
                let ts = [spec(FUSE.SetattrValid.atime, FUSE.SetattrValid.atimeNow, atime, atimensec),
                          spec(FUSE.SetattrValid.mtime, FUSE.SetattrValid.mtimeNow, mtime, mtimensec)]
                let ok = file.map { futimens($0, ts) } ?? utimensat(dirfd, name, ts, AT_SYMLINK_NOFOLLOW)
                guard ok == 0 else { throw FUSEError.last }
            }
            if valid & (FUSE.SetattrValid.uid | FUSE.SetattrValid.gid) != 0 {
                // As in Linux: only root gives a file away; its owner may change the group to its
                // own. The guest kernel checks this first; checked again as the guest is less trusted.
                var st = stat()
                guard fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw FUSEError.last }
                let current = attr(st, dirfd, name)
                let owner = (uid: valid & FUSE.SetattrValid.uid != 0 ? uid : current.uid,
                             gid: valid & FUSE.SetattrValid.gid != 0 ? gid : current.gid)
                if caller.uid != 0 {
                    guard current.uid == caller.uid, owner.uid == current.uid,
                          owner.gid == current.gid || owner.gid == caller.gid else { throw FUSEError(Linux.EPERM) }
                }
                if owner != (current.uid, current.gid) { try storeOwner(dirfd, name, st, owner) }
            }
            if valid & FUSE.SetattrValid.killSUIDGID != 0 {
                var st = stat()
                if let file, fstat(file, &st) == 0 {
                    dropSetID(st) { fchmod(file, $0) }
                } else if file == nil, fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                    dropSetID(st) { fchmodat(dirfd, name, $0, AT_SYMLINK_NOFOLLOW) }
                }
            }
        }

        if id == FUSE.rootID {
            try apply(rootFD, ".")
        } else {
            try withNode(id) { dirfd, name, _ in try apply(dirfd, name) }
        }
        return try getattr(id, fh: file == nil ? nil : fh)
    }

    private func readLink(_ id: UInt64) throws -> Data {
        try withNode(id) { dirfd, name, _ in
            var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
            let n = readlinkat(dirfd, name, &buffer, buffer.count)
            guard n >= 0 else { throw FUSEError.last }
            return Data(buffer[..<n])
        }
    }

    /// Makes `name` in directory `parent` with `make`, stores a non-root caller as its owner, sets
    /// its mode, and looks it up.
    private func create(in parent: UInt64, _ name: String, _ caller: Caller, mode: UInt32? = nil, _ make: (Int32, String) -> Int32) throws -> Data {
        let a = try withDirectory(parent) { fd in
            guard make(fd, name) == 0 else { throw FUSEError.last }
            var st = stat()
            if caller.uid != 0 || caller.gid != 0, fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                try? storeOwner(fd, name, st, (caller.uid, caller.gid))
            }
            // The guest already applied its umask; the host's would apply again.
            if let mode, fchmodat(fd, name, mode_t(mode & 0o7777 & ~0o6000), AT_SYMLINK_NOFOLLOW) != 0 {
                throw FUSEError.last
            }
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw FUSEError.last }
            return attr(st, fd, name)
        }
        return entryReply(remember(parent, name, a), a)
    }

    /// Binds a Unix socket at `name` in `dirfd` and closes it, leaving the socket file. macOS has
    /// no bindat, so the bind runs in `dirfd` as this thread's working directory.
    private func makeSocket(_ dirfd: Int32, _ name: String) -> Int32 {
        var address = sockaddr_un()
        let path = Array(name.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { errno = ENAMETOOLONG; return -1 }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return -1 }
        defer { close(s) }
        guard pthread_fchdir_np(dirfd) == 0 else { return -1 }
        defer { _ = pthread_fchdir_np(-1) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    private func makeNode(_ parent: UInt64, _ caller: Caller, _ r: inout FUSEReader) throws -> Data {
        let mode = try r.u32()
        try r.skip(12)
        let name = try r.name()
        switch mode_t(mode) & S_IFMT {
        case S_IFREG:
            return try create(in: parent, name, caller, mode: mode) { fd, name in
                let f = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                return f < 0 ? -1 : close(f)
            }
        case S_IFIFO:
            return try create(in: parent, name, caller, mode: mode) { fd, name in mkfifoat(fd, name, 0o600) }
        case S_IFSOCK:
            // A guest bind(): the guest kernel keeps the socket; the host file marks the name.
            return try create(in: parent, name, caller, mode: mode) { fd, name in makeSocket(fd, name) }
        default:
            // Devices need root on the host.
            throw FUSEError(Linux.EPERM)
        }
    }

    private func remove(_ parent: UInt64, _ name: String, flags: Int32) throws {
        try withDirectory(parent) { fd in
            guard unlinkat(fd, name, flags) == 0 else { throw FUSEError.last }
        }
    }

    private func renameNode(_ from: UInt64, _ name: String, _ to: UInt64, _ newName: String, flags: UInt32) throws {
        var hostFlags: UInt32 = 0
        if flags & Linux.RENAME_NOREPLACE != 0 { hostFlags |= UInt32(RENAME_EXCL) }
        if flags & Linux.RENAME_EXCHANGE != 0 { hostFlags |= UInt32(RENAME_SWAP) }
        guard flags & ~(Linux.RENAME_NOREPLACE | Linux.RENAME_EXCHANGE) == 0 else { throw FUSEError(Linux.EINVAL) }
        var st = stat(), other = stat(), swapped = false
        try withDirectory(from) { source in
            try withDirectory(to) { target in
                guard fstatat(source, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw FUSEError.last }
                swapped = hostFlags & UInt32(RENAME_SWAP) != 0 && fstatat(target, newName, &other, AT_SYMLINK_NOFOLLOW) == 0
                guard renameatx_np(source, name, target, newName, hostFlags) == 0 else { throw FUSEError.last }
            }
        }
        moved(Inode(st), to: to, newName)
        if swapped { moved(Inode(other), to: from, name) }
    }

    private func linkNode(_ id: UInt64, to parent: UInt64, _ name: String) throws -> Data {
        let a = try withDirectory(parent) { fd in
            try withNode(id) { olddir, oldname, _ in
                guard linkat(olddir, oldname, fd, name, 0) == 0 else { throw FUSEError.last }
            }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw FUSEError.last }
            return attr(st, fd, name)
        }
        return entryReply(remember(parent, name, a), a)
    }

    private func hostFlags(_ linux: UInt32) -> Int32 {
        var flags: Int32
        switch linux & Linux.O_ACCMODE {
        case 0: flags = O_RDONLY
        case 1: flags = O_WRONLY
        default: flags = O_RDWR
        }
        if linux & Linux.O_TRUNC != 0 { flags |= O_TRUNC }
        if linux & Linux.O_SYNC == Linux.O_SYNC { flags |= O_SYNC } else if linux & Linux.O_DSYNC != 0 { flags |= O_DSYNC }
        // O_APPEND is left out: the guest kernel sends each write with its offset at the end.
        return flags
    }

    /// Registers an open descriptor; the caller closes it if this throws.
    private func addHandle(_ handle: Handle) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard handles.count < handleLimit else { throw FUSEError(Linux.ENFILE) }
        let fh = nextHandle
        nextHandle += 1
        handles[fh] = handle
        return fh
    }

    private func release(_ handle: Handle) {
        switch handle {
        case .file(let fd, _): close(fd)
        // A readdir may still hold this object after RELEASEDIR removes the handle. Its
        // destructor closes the stream only after that request has finished with it.
        case .directory: break
        }
    }

    /// The caller owns this duplicate and closes it. A bare fd would become a different host
    /// file if RELEASE ran during an I/O request and another thread reused its descriptor.
    func duplicateDescriptor(_ fh: UInt64) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let fd: Int32
        switch handles[fh] {
        case .file(let file, _): fd = file
        case .directory(let d): fd = d.fd
        case nil: throw FUSEError(Linux.EBADF)
        }
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw FUSEError.last }
        return copy
    }

    /// Opens a regular file. O_NONBLOCK so a FIFO the host put in its place cannot hang us; it is
    /// then refused because its inode is not the node's.
    private func openFile(_ dirfd: Int32, _ name: String, _ linux: UInt32, create mode: UInt32? = nil,
                          owner: (uid: UInt32, gid: UInt32)? = nil) throws -> (Int32, stat) {
        let flags = hostFlags(linux)
        if readOnly && (flags & O_ACCMODE != O_RDONLY || flags & O_TRUNC != 0) { throw FUSEError(Linux.EROFS) }
        var fd: Int32 = -1
        var created = false
        if let mode {
            fd = openat(dirfd, name, flags | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            created = fd >= 0
            if fd < 0 && (errno != EEXIST || linux & Linux.O_EXCL != 0) { throw FUSEError.last }
            if created, let owner {
                let value = Array("\(owner.uid):\(owner.gid)".utf8)
                _ = fsetxattr(fd, Self.ownerAttribute, value, value.count, 0, 0)
            }
            if created, fchmod(fd, mode_t(mode & 0o7777 & ~0o6000)) != 0 {
                let e = FUSEError.last
                close(fd)
                throw e
            }
        }
        if fd < 0 {
            fd = openat(dirfd, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw FUSEError.last }
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else { let e = FUSEError.last; close(fd); throw e }
        guard st.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw FUSEError(st.st_mode & S_IFMT == S_IFDIR ? Linux.EISDIR : Linux.ESTALE)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        // The guest's O_DIRECT is not passed on as F_NOCACHE: reads and writes go straight
        // between the file and guest buffers, and direct I/O on guest pages corrupts guest memory
        // when macOS is short of memory (see VirtioBlock.bounced). Through the Mac's file cache
        // they are copies into and out of the guest's pages, like every other device's.
        return (fd, st)
    }

    private func openReply(_ fh: UInt64) -> Data {
        var w = FUSEWriter(capacity: 16)
        w.u64(fh)
        // No FOPEN_KEEP_CACHE: the guest drops its cached pages of a file on each open, so it sees
        // what the host wrote since (close-to-open), on top of AUTO_INVAL_DATA's mtime checks.
        w.u32(0)
        w.u32(0)
        return w.data
    }

    /// Opens a file for the guest. The guest keeps a file's size for up to `ttl` and would
    /// read a file the host rewrote in place with its old size. If the file changed since the
    /// guest was last told its attributes, the open fails once with ESTALE: the guest kernel then
    /// looks the name up again (fresh size and mtime, which also drops stale cached pages) and
    /// retries, which succeeds whatever happened in between.
    private func openNode(_ id: UInt64, flags: UInt32, dropSetID drop: Bool) throws -> Data {
        guard !readOnly || !drop else { throw FUSEError(Linux.EROFS) }
        let (fd, st) = try withNode(id) { dirfd, name, expected in
            let (fd, st) = try openFile(dirfd, name, flags)
            guard Inode(st) == Inode(expected) else { close(fd); throw FUSEError(Linux.ESTALE) }
            return (fd, st)
        }
        if drop { dropSetID(st) { fchmod(fd, $0) } }
        lock.lock()
        var refuse = false
        if let node = nodes[id] {
            refuse = !node.refusedOpen && node.seen != nil && node.seen != Version(st) && flags & Linux.O_TRUNC == 0
            node.refusedOpen = refuse
        }
        lock.unlock()
        if refuse {
            close(fd)
            throw FUSEError(Linux.ESTALE)
        }
        do {
            return openReply(try addHandle(.file(fd, node: id)))
        } catch {
            close(fd)
            throw error
        }
    }

    private func create(_ parent: UInt64, _ caller: Caller, _ r: inout FUSEReader) throws -> Data {
        let flags = try r.u32(), mode = try r.u32()
        try r.skip(4)
        let openFlags = try r.u32()
        let name = try r.name()
        let owner = caller.uid != 0 || caller.gid != 0 ? (caller.uid, caller.gid) : nil
        let (fd, opened) = try withDirectory(parent) { try openFile($0, name, flags, create: mode, owner: owner) }
        var st = opened
        if openFlags & FUSE.openKillSUIDGID != 0 {
            dropSetID(st) { fchmod(fd, $0) }
            fstat(fd, &st)
        }
        let fh: UInt64
        let a = attr(st, fd, nil)
        let id = remember(parent, name, a)
        do { fh = try addHandle(.file(fd, node: id)) } catch { forget(id, 1); close(fd); throw error }
        var w = FUSEWriter(capacity: FUSE.entrySize + 16)
        putEntry(&w, id, a)
        w.data.append(openReply(fh))
        return w.data
    }

    /// Clears setuid, and setgid on a group-executable file, as Linux does on a write, truncate or
    /// chown by a user without CAP_FSETID. With FUSE_HANDLE_KILLPRIV_V2 the guest kernel leaves this
    /// to us, and in return stops asking for `security.capability` before every write.
    private func dropSetID(_ st: stat, _ chmod: (mode_t) -> Int32) {
        guard st.st_mode & S_IFMT == S_IFREG else { return }
        var mode = st.st_mode & 0o7777 & ~S_ISUID
        if mode & S_IXGRP != 0 { mode &= ~S_ISGID }
        if mode != st.st_mode & 0o7777 { _ = chmod(mode) }
    }

    /// Reads straight into the guest's buffers. Loops until the request is full or the file ends:
    /// a short read tells the guest kernel that the file ends there.
    private func readFile(_ r: inout FUSEReader, _ output: [iovec]) throws -> Int {
        let fh = try r.u64(), offset = try r.u64(), size = Int(try r.u32())
        guard offset <= UInt64(Int64.max) else { throw FUSEError(Linux.EINVAL) }
        let fd = try duplicateDescriptor(fh)
        defer { close(fd) }
        var iov = slice(output, from: 0, count: size)
        var done = 0
        while !iov.isEmpty {
            let n = preadv(fd, iov, Int32(min(iov.count, Int(IOV_MAX))), off_t(offset) + off_t(done))
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { if done > 0 { break }; throw FUSEError.last }
            if n == 0 { break }
            done += n
            iov = slice(iov, from: n, count: Int.max)
        }
        return done
    }

    private func writeFile(_ r: inout FUSEReader, _ input: [iovec]) throws -> Data {
        let fh = try r.u64(), offset = try r.u64(), size = Int(try r.u32()), writeFlags = try r.u32()
        guard offset <= UInt64(Int64.max) else { throw FUSEError(Linux.EINVAL) }
        let fd = try duplicateDescriptor(fh)
        defer { close(fd) }
        if writeFlags & FUSE.writeKillSUIDGID != 0 {
            var st = stat()
            if fstat(fd, &st) == 0 { dropSetID(st) { fchmod(fd, $0) } }
        }
        var iov = slice(input, from: 0, count: size)
        var done = 0
        while !iov.isEmpty {
            let n = pwritev(fd, iov, Int32(min(iov.count, Int(IOV_MAX))), off_t(offset) + off_t(done))
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { if done > 0 { break }; throw FUSEError.last }
            done += n
            iov = slice(iov, from: n, count: Int.max)
        }
        // The guest knows what it wrote; host changes after this are not caught at open.
        lock.lock()
        if case .file(_, let node)? = handles[fh] { nodes[node]?.seen = nil }
        lock.unlock()
        var w = FUSEWriter(capacity: 8)
        w.u32(UInt32(done)); w.u32(0)
        return w.data
    }

    // MARK: Extended attributes

    /// Runs `body` with a descriptor of the node itself, or returns nil if the node is neither a
    /// file nor a directory (Linux has `user.*` attributes on those only).
    private func withOpenNode<T>(_ id: UInt64, _ body: (Int32) throws -> T) throws -> T? {
        try withNode(id) { dirfd, name, st in
            let type = st.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else { return nil }
            let fd = openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw FUSEError.last }
            defer { close(fd) }
            var now = stat()
            guard fstat(fd, &now) == 0, Inode(now) == Inode(st) else { throw FUSEError(Linux.ESTALE) }
            return try body(fd)
        }
    }

    /// The only names the guest sees or sets; everything else on the host stays hidden.
    private static func guestVisible(_ name: some Collection<UInt8>) -> Bool {
        name.count > 5 && name.starts(with: "user.".utf8)
    }

    /// The reply to a GETXATTR or LISTXATTR: the size if the guest asked with size 0, else the bytes.
    private func sizedReply(_ bytes: [UInt8], _ size: Int) throws -> Data {
        guard size > 0 else {
            var w = FUSEWriter(capacity: 8)
            w.u32(UInt32(bytes.count)); w.u32(0)
            return w.data
        }
        guard bytes.count <= size else { throw FUSEError(Linux.ERANGE) }
        return Data(bytes)
    }

    private func getXattr(_ id: UInt64, _ name: String, size: Int) throws -> Data {
        guard Self.guestVisible(name.utf8) else { throw FUSEError(Linux.ENODATA) }
        let value = try withOpenNode(id) { fd -> [UInt8] in
            let n = fgetxattr(fd, name, nil, 0, 0, 0)
            guard n >= 0 else { throw FUSEError.last }
            var buffer = [UInt8](repeating: 0, count: n)
            let m = fgetxattr(fd, name, &buffer, n, 0, 0)
            guard m >= 0 else { throw FUSEError.last }
            return Array(buffer[..<m])
        }
        guard let value else { throw FUSEError(Linux.ENODATA) }
        return try sizedReply(value, size)
    }

    private func listXattr(_ id: UInt64, size: Int) throws -> Data {
        let names = try withOpenNode(id) { fd -> [UInt8] in
            let n = flistxattr(fd, nil, 0, 0)
            guard n >= 0 else { throw FUSEError.last }
            var buffer = [UInt8](repeating: 0, count: n)
            let m = flistxattr(fd, &buffer, n, 0)
            guard m >= 0 else { throw FUSEError.last }
            return buffer[..<m].split(separator: 0).filter { Self.guestVisible($0) }.flatMap { Array($0) + [0] }
        }
        return try sizedReply(names ?? [], size)
    }

    private func setXattr(_ id: UInt64, _ name: String, _ value: Data, flags: UInt32) throws {
        guard Self.guestVisible(name.utf8) else { throw FUSEError(Linux.EOPNOTSUPP) }
        guard flags & ~(Linux.XATTR_CREATE | Linux.XATTR_REPLACE) == 0 else { throw FUSEError(Linux.EINVAL) }
        let options = (flags & Linux.XATTR_CREATE != 0 ? XATTR_CREATE : 0) | (flags & Linux.XATTR_REPLACE != 0 ? XATTR_REPLACE : 0)
        let done: Void? = try withOpenNode(id) { fd in
            let ok = value.withUnsafeBytes { fsetxattr(fd, name, $0.baseAddress, $0.count, 0, options) }
            guard ok == 0 else { throw FUSEError.last }
        }
        guard done != nil else { throw FUSEError(Linux.EPERM) }
    }

    private func removeXattr(_ id: UInt64, _ name: String) throws {
        guard Self.guestVisible(name.utf8) else { throw FUSEError(Linux.EOPNOTSUPP) }
        let done: Void? = try withOpenNode(id) { fd in
            guard fremovexattr(fd, name, 0) == 0 else { throw FUSEError.last }
        }
        guard done != nil else { throw FUSEError(Linux.EPERM) }
    }

    // MARK: File system

    private func fsStats() throws -> Data {
        var s = Darwin.statfs()
        guard fstatfs(rootFD, &s) == 0 else { throw FUSEError.last }
        var w = FUSEWriter(capacity: 80)
        w.u64(s.f_blocks); w.u64(s.f_bfree); w.u64(s.f_bavail); w.u64(s.f_files); w.u64(s.f_ffree)
        w.u32(s.f_bsize); w.u32(255); w.u32(s.f_bsize); w.u32(0)
        w.zeros(24)
        return w.data
    }

    private func openDir(_ id: UInt64) throws -> Data {
        // A descriptor of its own: fdopendir takes it, and the listing uses its offset.
        let fd = try withDirectory(id) { openat($0, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard fd >= 0, let stream = fdopendir(fd) else { let e = FUSEError.last; if fd >= 0 { close(fd) }; throw e }
        return openReply(try addHandle(.directory(Directory(dir: stream, node: id))))
    }

    /// Lists a directory. Offsets are indexes into a snapshot taken when the guest reads from
    /// offset 0, so entries added or removed while the guest reads do not shift what it gets.
    private func readDir(_ r: inout FUSEReader, plus: Bool) throws -> Data {
        let fh = try r.u64(), offset = try r.u64(), size = Int(try r.u32())
        lock.lock()
        let handle = handles[fh]
        lock.unlock()
        guard case .directory(let dir) = handle else { throw FUSEError(Linux.EBADF) }
        dir.lock.lock()
        defer { dir.lock.unlock() }
        if offset == 0 || !dir.loaded {
            rewinddir(dir.dir)
            dir.entries.removeAll(keepingCapacity: true)
            while let e = Darwin.readdir(dir.dir) {
                let name = withUnsafeBytes(of: e.pointee.d_name) { raw in
                    String(decoding: raw.prefix(Int(e.pointee.d_namlen)), as: UTF8.self)
                }
                dir.entries.append((name, e.pointee.d_ino, e.pointee.d_type))
            }
            dir.loaded = true
        }
        var w = FUSEWriter(capacity: min(size, 64 << 10))
        var index = Int(min(offset, UInt64(dir.entries.count)))
        while index < dir.entries.count {
            let e = dir.entries[index]
            let record = (24 + e.name.utf8.count + 7) / 8 * 8 + (plus ? FUSE.entrySize : 0)
            guard w.data.count + record <= size else { break }
            index += 1
            if plus {
                var st = stat()
                if e.name == "." || e.name == ".." {
                    w.zeros(FUSE.entrySize)  // nodeid 0: the guest makes no dentry for these
                } else if fstatat(dir.fd, e.name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                    let a = attr(st, dir.fd, e.name)
                    putEntry(&w, remember(dir.node, e.name, a), a)
                } else {
                    continue  // gone since the snapshot
                }
            }
            w.u64(e.ino)
            w.u64(UInt64(index))  // where the next read continues
            w.u32(UInt32(e.name.utf8.count))
            w.u32(UInt32(e.type))  // DT_* values are the same on Linux
            w.bytes(e.name)
            w.pad8()
        }
        return w.data
    }
}

/// The part of `buffers` that starts `offset` bytes in and is at most `count` bytes long.
func slice(_ buffers: [iovec], from offset: Int, count: Int) -> [iovec] {
    var result: [iovec] = []
    var skip = offset, left = count
    for b in buffers where left > 0 {
        if skip >= b.iov_len { skip -= b.iov_len; continue }
        let n = min(b.iov_len - skip, left)
        result.append(iovec(iov_base: b.iov_base.map { $0 + skip }, iov_len: n))
        left -= n
        skip = 0
    }
    return result
}

@_silgen_name("pthread_fchdir_np")
private func pthread_fchdir_np(_ fd: Int32) -> Int32
