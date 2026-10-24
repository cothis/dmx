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

    func call(_ op: FUSE.Opcode, _ node: UInt64, _ args: Data) -> FUSEServer.Reply {
        server.handle(opcode: op.rawValue, node: node, args: args, input: [], output: [])
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
}
