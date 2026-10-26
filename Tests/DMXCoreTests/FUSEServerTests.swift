import Foundation
import Testing
@testable import DMXCore

/// The share's containment guarantees, driven with requests a hostile guest could send.
@Suite struct FUSEServerTests {
    let base: String
    let root: String
    let server: FUSEServer

    init() throws {
        base = NSTemporaryDirectory() + "dmx-fuse-\(UUID().uuidString)"
        root = base + "/share"
        try FileManager.default.createDirectory(atPath: root + "/d", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: base + "/outside", withIntermediateDirectories: true)
        try "secret".write(toFile: base + "/outside/secret", atomically: false, encoding: .utf8)
        try "inside".write(toFile: root + "/d/secret", atomically: false, encoding: .utf8)
        server = try FUSEServer(path: root, readOnly: false)
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: base) }

    func name(_ s: String) -> Data { Data(s.utf8) + Data([0]) }

    func call(_ op: FUSE.Opcode, _ node: UInt64, _ args: Data, as caller: FUSEServer.Caller = .root) -> FUSEServer.Reply {
        server.handle(opcode: op.rawValue, node: node, caller: caller, args: args, input: [], output: [])
    }

    func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    func data(_ reply: FUSEServer.Reply) -> Data? {
        if case .data(let d) = reply { return d }
        return nil
    }

    /// uid and gid from an attr or entry reply.
    func owner(_ reply: FUSEServer.Reply, entry: Bool = false) -> [UInt32]? {
        guard let d = data(reply) else { return nil }
        let at = (entry ? 40 : 16) + 68
        return d.withUnsafeBytes { [$0.loadUnaligned(fromByteOffset: at, as: UInt32.self), $0.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self)] }
    }

    /// fuse_setattr_in changing the owner.
    func chown(uid: UInt32?, gid: UInt32?) -> Data {
        var d = u32((uid == nil ? 0 : 2) | (gid == nil ? 0 : 4)) + Data(count: 4 + 8 * 6 + 4 * 5)
        d += u32(uid ?? 0) + u32(gid ?? 0) + Data(count: 4)
        return d
    }

    func storedOwner(_ path: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = getxattr(path, FUSEServer.ownerAttribute, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        return n < 0 ? nil : String(decoding: buffer[..<n], as: UTF8.self)
    }

    func errno(_ reply: FUSEServer.Reply) -> Int32? {
        if case .error(let e) = reply { return e }
        return nil
    }

    func lookup(_ parent: UInt64, _ s: String) -> UInt64? {
        guard case .data(let d) = call(.lookup, parent, name(s)) else { return nil }
        return d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    }

    @Test func refusesDotDotAndSlashes() {
        defer { cleanup() }
        for bad in ["..", ".", "", "d/secret", "../outside"] {
            #expect(errno(call(.lookup, FUSE.rootID, name(bad))) != nil, "lookup \(bad)")
            #expect(errno(call(.mkdir, FUSE.rootID, Data(count: 8) + name(bad))) != nil, "mkdir \(bad)")
        }
        let rename = Data([1, 0, 0, 0, 0, 0, 0, 0]) + name("d") + name("../escaped")
        #expect(errno(call(.rename, FUSE.rootID, rename)) != nil)
        #expect(FileManager.default.fileExists(atPath: root + "/d"))
        #expect(errno(call(.getattr, 12345, Data(count: 16))) == Linux.ESTALE)
    }

    @Test func doesNotFollowHostSymlinks() throws {
        defer { cleanup() }
        // A symlink to outside the share: the guest gets the link, never what it points to.
        try FileManager.default.createSymbolicLink(atPath: root + "/out", withDestinationPath: base + "/outside")
        let out = try #require(lookup(FUSE.rootID, "out"))
        #expect(lookup(out, "secret") == nil)
        #expect(errno(call(.open, out, Data(count: 8))) != nil)
        #expect(errno(call(.opendir, out, Data(count: 8))) != nil)
        #expect(errno(call(.mkdir, out, Data(count: 8) + name("planted"))) != nil)
        #expect(!FileManager.default.fileExists(atPath: base + "/outside/planted"))
    }

    @Test func directorySwappedForSymlinkOnTheHost() throws {
        defer { cleanup() }
        // The guest holds a node for d; the host then replaces d with a symlink to outside.
        let d = try #require(lookup(FUSE.rootID, "d"))
        try FileManager.default.moveItem(atPath: root + "/d", toPath: root + "/d.old")
        try FileManager.default.createSymbolicLink(atPath: root + "/d", withDestinationPath: base + "/outside")
        #expect(errno(call(.lookup, d, name("secret"))) == Linux.ESTALE)
        #expect(errno(call(.create, d, Data(count: 16) + name("planted"))) == Linux.ESTALE)
        #expect(errno(call(.unlink, d, name("secret"))) == Linux.ESTALE)
        #expect(FileManager.default.fileExists(atPath: base + "/outside/secret"))
        #expect(!FileManager.default.fileExists(atPath: base + "/outside/planted"))
        // Looked up again, d is the symlink, which the guest resolves itself.
        let again = try #require(lookup(FUSE.rootID, "d"))
        guard case .data(let target) = call(.readlink, again, Data()) else { Issue.record("readlink"); return }
        #expect(String(decoding: target, as: UTF8.self) == base + "/outside")
    }

    @Test func cachedDirectorySwappedForSymlinkOnTheHost() throws {
        defer { cleanup() }
        // Used once, d stays open; after the swap, requests still reach the real directory.
        let d = try #require(lookup(FUSE.rootID, "d"))
        #expect(lookup(d, "secret") != nil)
        try FileManager.default.moveItem(atPath: root + "/d", toPath: root + "/d.old")
        try FileManager.default.createSymbolicLink(atPath: root + "/d", withDestinationPath: base + "/outside")
        guard case .data = call(.mkdir, d, Data(count: 8) + name("planted")) else { Issue.record("mkdir"); return }
        #expect(FileManager.default.fileExists(atPath: root + "/d.old/planted"))
        #expect(!FileManager.default.fileExists(atPath: base + "/outside/planted"))
    }

    @Test func readOnlyShareRefusesChanges() throws {
        defer { cleanup() }
        let ro = try FUSEServer(path: root, readOnly: true)
        let reply = ro.handle(opcode: FUSE.Opcode.mkdir.rawValue, node: FUSE.rootID, args: Data(count: 8) + name("x"), input: [], output: [])
        guard case .error(let e) = reply else { Issue.record("mkdir succeeded"); return }
        #expect(e == Linux.EROFS)
        #expect(!FileManager.default.fileExists(atPath: root + "/x"))
    }

    @Test func readOnlyOpenCannotChangeHostPermissions() throws {
        defer { cleanup() }
        let path = root + "/file"
        try "kept".write(toFile: path, atomically: false, encoding: .utf8)
        #expect(chmod(path, 0o6755) == 0)
        let ro = try FUSEServer(path: root, readOnly: true)
        let entry = try #require(data(ro.handle(opcode: FUSE.Opcode.lookup.rawValue, node: FUSE.rootID,
                                              args: name("file"), input: [], output: [])))
        let node = entry.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        let reply = ro.handle(opcode: FUSE.Opcode.open.rawValue, node: node,
                              args: u32(0) + u32(FUSE.openKillSUIDGID), input: [], output: [])
        #expect(errno(reply) == Linux.EROFS)
        var st = stat()
        #expect(stat(path, &st) == 0 && st.st_mode & 0o7777 == 0o6755)
    }

    @Test func inFlightDescriptorSurvivesGuestRelease() throws {
        defer { cleanup() }
        let dir = try #require(lookup(FUSE.rootID, "d"))
        let node = try #require(lookup(dir, "secret"))
        let opened = try #require(data(call(.open, node, u32(2) + u32(0))))
        let fh = opened.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        // Pause an I/O after it acquired its fd, then let a guest RELEASE and a host open run.
        let fd = try server.duplicateDescriptor(fh)
        defer { close(fd) }
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
        #expect(data(call(.release, node, opened.prefix(8))) != nil)
        let outside = open(base + "/outside/secret", O_RDWR)
        #expect(outside >= 0)
        defer { if outside >= 0 { close(outside) } }
        #expect(pwrite(fd, "kept!", 5, 0) == 5)
        #expect(try String(contentsOfFile: root + "/d/secret", encoding: .utf8) == "kept!e")
        #expect(try String(contentsOfFile: base + "/outside/secret", encoding: .utf8) == "secret")
        #expect(throws: FUSEError.self) { try server.duplicateDescriptor(fh) }
    }

    @Test func directoryReleaseCanRaceARead() throws {
        defer { cleanup() }
        for _ in 0..<100 {
            let opened = try #require(data(call(.opendir, FUSE.rootID, Data(count: 8))))
            let fh = Data(opened.prefix(8))
            let read = fh + Data(count: 8) + u32(4096) + Data(count: 20)
            let shared = server
            DispatchQueue.concurrentPerform(iterations: 2) { i in
                _ = shared.handle(opcode: (i == 0 ? FUSE.Opcode.readdir : .releasedir).rawValue,
                                  node: FUSE.rootID, args: i == 0 ? read : fh, input: [], output: [])
            }
        }
    }

    @Test func socketsAreBound() throws {
        defer { cleanup() }
        let reply = call(.mknod, FUSE.rootID, u32(UInt32(S_IFSOCK) | 0o755) + Data(count: 12) + name("s.sock"))
        #expect(data(reply) != nil)
        var st = stat()
        #expect(lstat(root + "/s.sock", &st) == 0 && st.st_mode & S_IFMT == S_IFSOCK && st.st_mode & 0o777 == 0o755)
        let long = String(repeating: "x", count: 120)
        #expect(errno(call(.mknod, FUSE.rootID, u32(UInt32(S_IFSOCK) | 0o755) + Data(count: 12) + name(long))) == Linux.ENAMETOOLONG)
    }

    @Test func onlyUserAttributesAreVisible() throws {
        defer { cleanup() }
        let file = root + "/d/secret"
        #expect(setxattr(file, "com.apple.quarantine", "q", 1, 0, 0) == 0)
        let d = try #require(lookup(FUSE.rootID, "d"))
        let f = try #require(lookup(d, "secret"))
        #expect(data(call(.setxattr, f, u32(2) + u32(0) + name("user.a") + Data("v1".utf8))) != nil)
        #expect(errno(call(.setxattr, f, u32(1) + u32(0) + name("trusted.x") + Data("v".utf8))) == Linux.EOPNOTSUPP)
        #expect(errno(call(.setxattr, f, u32(1) + u32(0) + name("security.capability") + Data("v".utf8))) == Linux.EOPNOTSUPP)
        #expect(errno(call(.setxattr, f, u32(2) + u32(1) + name("user.a") + Data("v2".utf8))) == Linux.EEXIST)
        #expect(data(call(.getxattr, f, u32(0) + u32(0) + name("user.a"))) == u32(2) + u32(0))
        #expect(data(call(.getxattr, f, u32(64) + u32(0) + name("user.a"))) == Data("v1".utf8))
        #expect(errno(call(.getxattr, f, u32(1) + u32(0) + name("user.a"))) == Linux.ERANGE)
        #expect(errno(call(.getxattr, f, u32(64) + u32(0) + name("com.apple.quarantine"))) == Linux.ENODATA)
        #expect(errno(call(.getxattr, f, u32(64) + u32(0) + name("security.capability"))) == Linux.ENODATA)
        #expect(data(call(.listxattr, f, u32(64) + u32(0))) == Data("user.a\0".utf8))
        #expect(errno(call(.removexattr, f, name("com.apple.quarantine"))) == Linux.EOPNOTSUPP)
        #expect(data(call(.removexattr, f, name("user.a"))) != nil)
        #expect(errno(call(.removexattr, f, name("user.a"))) == Linux.ENODATA)
        #expect(getxattr(file, "com.apple.quarantine", nil, 0, 0, 0) == 1)
    }

    @Test func ownershipIsStored() throws {
        defer { cleanup() }
        let d = try #require(lookup(FUSE.rootID, "d"))
        let f = try #require(lookup(d, "secret"))
        #expect(owner(call(.getattr, f, Data(count: 16))) == [0, 0])
        // Non-root may not give a file away.
        #expect(errno(call(.setattr, f, chown(uid: 999, gid: nil), as: .init(uid: 1000, gid: 1000))) == Linux.EPERM)
        // Root may, also when the host user cannot write the file.
        chmod(root + "/d/secret", 0o444)
        #expect(owner(call(.setattr, f, chown(uid: 999, gid: 998))) == [999, 998])
        #expect(storedOwner(root + "/d/secret") == "999:998")
        var st = stat()
        #expect(stat(root + "/d/secret", &st) == 0 && st.st_mode & 0o777 == 0o444)
        // The owner may change the group to its own, and nothing else.
        #expect(owner(call(.setattr, f, chown(uid: nil, gid: 5), as: .init(uid: 999, gid: 5))) == [999, 5])
        #expect(errno(call(.setattr, f, chown(uid: nil, gid: 6), as: .init(uid: 999, gid: 5))) == Linux.EPERM)
        // Back to the default: the attribute goes.
        #expect(owner(call(.setattr, f, chown(uid: 0, gid: 0))) == [0, 0])
        #expect(storedOwner(root + "/d/secret") == nil)
        // A non-root guest user's new files are its own; root's carry nothing.
        let user = FUSEServer.Caller(uid: 1000, gid: 1001)
        #expect(owner(call(.mkdir, d, u32(0o755) + u32(0) + name("sub"), as: user), entry: true) == [1000, 1001])
        #expect(owner(call(.create, d, u32(0o101) + u32(0o644) + Data(count: 8) + name("new"), as: user), entry: true) == [1000, 1001])
        #expect(owner(call(.symlink, d, name("link") + name("target"), as: user), entry: true) == [1000, 1001])
        #expect(storedOwner(root + "/d/sub") == "1000:1001" && storedOwner(root + "/d/new") == "1000:1001")
        #expect(owner(call(.mkdir, d, u32(0o755) + u32(0) + name("rootdir")), entry: true) == [0, 0])
        #expect(storedOwner(root + "/d/rootdir") == nil)
        // The stored owner is not an attribute the guest can see or change.
        #expect(errno(call(.getxattr, f, u32(64) + u32(0) + name(FUSEServer.ownerAttribute))) == Linux.ENODATA)
    }

    @Test func setIDBitsAreDroppedWhenAsked() throws {
        defer { cleanup() }
        // The host user's own setuid file; the guest kernel asks us to clear the bits (killpriv_v2).
        let path = root + "/d/secret"
        chmod(path, 0o6755)
        let d = try #require(lookup(FUSE.rootID, "d"))
        let f = try #require(lookup(d, "secret"))
        var st = stat()
        // Plain open: unchanged. Open asking for it: cleared.
        _ = call(.open, f, u32(0) + u32(0))
        #expect(stat(path, &st) == 0 && st.st_mode & 0o7777 == 0o6755)
        _ = call(.open, f, u32(UInt32(Linux.O_TRUNC) | 1) + u32(FUSE.openKillSUIDGID))
        #expect(stat(path, &st) == 0 && st.st_mode & 0o7777 == 0o755)
        // A chown (the guest kernel asks for this on every chown of a file).
        chmod(path, 0o4755)
        var args = chown(uid: 5, gid: nil)
        args.replaceSubrange(0..<4, with: u32(2 | FUSE.SetattrValid.killSUIDGID))
        _ = call(.setattr, f, args)
        #expect(stat(path, &st) == 0 && st.st_mode & 0o7777 == 0o755)
    }
}
