import CryptoKit
import Foundation
import Testing
@testable import DMXCore

/// Telling a downloaded guest from one built with `make guest`, and when a boot downloads.
@Suite struct GuestStoreTests {
    let home = URL(fileURLWithPath: NSTemporaryDirectory() + "dmx-guest-\(UUID().uuidString)")

    private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A fake guest and the release that would describe it.
    private func install(tag: String) throws -> (Paths, GuestRelease) {
        let paths = Paths(environment: ["DMX_HOME": home.path])
        try FileManager.default.createDirectory(at: paths.guest, withIntermediateDirectories: true)
        var files: [String: String] = [:]
        for (name, body) in [("Image", "kernel"), ("initramfs.gz", "initramfs"), ("docker.img", "docker"),
                             ("manifest.json", #"{"kernel": "6.18.58-dmx"}"#)] {
            let data = Data(body.utf8)
            try data.write(to: paths.guest.appendingPathComponent(name))
            files[name] = hex(data)
        }
        let release = GuestRelease(tag: tag, archive: "dmx-guest.tar.gz", bytes: 1, sha256: hex(Data(tag.utf8)), files: files)
        return (paths, release)
    }

    private func writeReceipt(_ release: GuestRelease, _ paths: Paths) throws {
        try JSONEncoder().encode(release).write(to: paths.guest.appendingPathComponent("release.json"))
    }

    @Test func missingGuestIsFetchedOnlyWithAPin() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(environment: ["DMX_HOME": home.path])
        let pin = GuestRelease(tag: "v1", archive: "a", bytes: 1, sha256: "x", files: [:])
        #expect(GuestStore(paths: paths, pin: nil).state().source == .missing)
        #expect(GuestStore(paths: paths, pin: nil).state().needsFetch == false)
        #expect(GuestStore(paths: paths, pin: pin).state().needsFetch == true)
    }

    @Test func downloadedGuestIsCurrentOrStale() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let (paths, v1) = try install(tag: "v1")
        try writeReceipt(v1, paths)
        let current = GuestStore(paths: paths, pin: v1).state()
        #expect(current.source == .release && current.tag == "v1" && current.kernel == "6.18.58-dmx" && !current.needsFetch)
        #expect(GuestStore(paths: paths, pin: v1).verify().isEmpty)

        // Another release that ships the same boot files: nothing to download. 0.3.0 and 0.3.1
        // were exactly this, and downloading 62 MB again would have been for the version string
        // in the archive's THIRD_PARTY.md.
        let sameFiles = GuestRelease(tag: "v2", archive: "b", bytes: 1, sha256: "other", files: v1.files)
        let kept = GuestStore(paths: paths, pin: sameFiles).state()
        #expect(kept.source == .release && kept.tag == "v1" && kept.pinnedTag == "v2" && !kept.needsFetch)

        // A release with another kernel: fetch it.
        var changed = v1.files
        changed["Image"] = hex(Data("another kernel".utf8))
        let v3 = GuestRelease(tag: "v3", archive: "c", bytes: 1, sha256: "third", files: changed)
        let stale = GuestStore(paths: paths, pin: v3).state()
        #expect(stale.source == .release && stale.tag == "v1" && stale.pinnedTag == "v3" && stale.needsFetch)

        // A file gone from a downloaded guest: fetch again; a changed one: doctor says so.
        try FileManager.default.removeItem(at: paths.dockerImage)
        #expect(GuestStore(paths: paths, pin: v1).state().needsFetch)
        try Data("tampered".utf8).write(to: paths.dockerImage)
        #expect(GuestStore(paths: paths, pin: v1).verify() == ["docker.img does not match release v1"])
    }

    @Test func bootRecordsTheNewTagOfTheSameFiles() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let (paths, v1) = try install(tag: "v1")
        try writeReceipt(v1, paths)
        // Nothing listens there, so a download would fail and leave the receipt at v1.
        let pin = GuestRelease(tag: "v2", archive: "b", bytes: 1, sha256: "other", files: v1.files)
        let store = GuestStore(paths: paths, pin: pin, environment: ["DMX_RELEASE_URL": "http://127.0.0.1:1"])
        try await store.ensure { _ in }
        let state = store.state()
        #expect(state.tag == "v2" && !state.needsFetch)
        #expect(store.verify().isEmpty)
    }

    @Test func sameArchiveWithNewTagRefreshesReceiptWithoutDownload() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let (paths, old) = try install(tag: "v1")
        try writeReceipt(old, paths)
        let pin = GuestRelease(tag: "v2", archive: old.archive, bytes: old.bytes,
                               sha256: old.sha256, files: old.files)
        let before = try Data(contentsOf: paths.manifest)
        let store = GuestStore(paths: paths, pin: pin, environment: ["DMX_RELEASE_URL": "http://127.0.0.1:1"])
        try await store.ensure { _ in }
        #expect(store.state().tag == "v2")
        #expect(try JSONDecoder().decode(GuestRelease.self, from: Data(contentsOf: paths.guest.appendingPathComponent("release.json"))) == pin)
        #expect(try Data(contentsOf: paths.manifest) == before)
    }

    @Test func rebuiltGuestIsLocalAndLeftAlone() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let (paths, v1) = try install(tag: "v1")
        try writeReceipt(v1, paths)
        // `make guest` over a downloaded guest rewrites manifest.json; release.json stays behind.
        try Data(#"{"kernel": "6.18.58-dmx", "rebuilt": true}"#.utf8).write(to: paths.manifest)
        let pin = GuestRelease(tag: "v2", archive: "b", bytes: 1, sha256: "other", files: v1.files)
        let state = GuestStore(paths: paths, pin: pin).state()
        #expect(state.source == .local && !state.needsFetch)
        #expect(GuestStore(paths: paths, pin: pin).verify().isEmpty)
    }

    @Test func releaseURLFollowsGitHubLayout() {
        let paths = Paths(environment: ["DMX_HOME": home.path])
        let pin = GuestRelease(tag: "v0.1.0", archive: "dmx-guest-0.1.0.tar.gz", bytes: 1, sha256: "x", files: [:])
        #expect(GuestStore(paths: paths, pin: pin, environment: [:]).url(of: pin)?.absoluteString
                == "https://github.com/cothis/dmx/releases/download/v0.1.0/dmx-guest-0.1.0.tar.gz")
        #expect(GuestStore(paths: paths, pin: pin, environment: ["DMX_RELEASE_URL": "http://127.0.0.1:23456/"]).url(of: pin)?.absoluteString
                == "http://127.0.0.1:23456/v0.1.0/dmx-guest-0.1.0.tar.gz")
    }
}
