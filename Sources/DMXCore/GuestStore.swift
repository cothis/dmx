import Foundation

/// A guest published as a release asset: one tar.gz of what `make guest` writes to ~/.dmx/guest
/// (Image, initramfs.gz, docker.img, manifest.json) plus the license texts and source notes of
/// what runs in it. `scripts/release.py` builds it and writes its hashes into GuestPin.swift, so a
/// download is checked against the dmx binary the user already has, not against a file from the
/// same server.
public struct GuestRelease: Codable, Sendable, Equatable {
    /// The release tag the archive is published under, e.g. v0.1.0.
    public let tag: String
    public let archive: String
    public let bytes: Int
    public let sha256: String
    /// sha256 of each boot file in the archive, so an installed guest can be checked without it.
    public let files: [String: String]

    public init(tag: String, archive: String, bytes: Int, sha256: String, files: [String: String]) {
        self.tag = tag
        self.archive = archive
        self.bytes = bytes
        self.sha256 = sha256
        self.files = files
    }

    /// GitHub's layout: <base>/<tag>/<asset>. `DMX_RELEASE_URL` or the `release_url` setting
    /// replaces the base (a company mirror, or a
    /// local `python3 -m http.server` when testing a release directory).
    public static let defaultBaseURL = "https://github.com/cothis/dmx/releases/download"
}

public struct GuestState: Encodable, Sendable {
    public enum Source: String, Encodable, Sendable {
        /// No kernel or initramfs.
        case missing
        /// Downloaded from a release (`release.json` matches the files).
        case release
        /// Built with `make guest`, or changed after the download. dmx never replaces it by itself.
        case local
    }

    public let source: Source
    public let path: String
    public let kernel: String?
    /// The release a downloaded guest came from.
    public let tag: String?
    /// The release this dmx downloads; nil when it was built without one.
    public let pinnedTag: String?
    /// True when the next boot downloads the pinned release first: the guest is missing, or it
    /// came from another release (dmx was upgraded) or lost a file.
    public let needsFetch: Bool
}

public struct GuestFetchReport: Encodable, Sendable {
    public let fetched: Bool
    public let url: String?
    public let bytes: Int?
    public let ms: Int?
    public let guest: GuestState
}

/// The guest in `~/.dmx/guest`: where it came from, and fetching the pinned release into it.
public struct GuestStore: Sendable {
    public let paths: Paths
    public let pin: GuestRelease?
    public let baseURL: String

    public init(paths: Paths, pin: GuestRelease? = GuestRelease.pinned,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.pin = pin
        let custom = Config.mirror("DMX_RELEASE_URL", \.releaseUrl, paths: paths, environment: environment)
        baseURL = (custom ?? GuestRelease.defaultBaseURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// The release a guest was downloaded from, a copy of the pin at the time.
    var receiptURL: URL { paths.guest.appendingPathComponent("release.json") }

    public func url(of release: GuestRelease) -> URL? {
        URL(string: "\(baseURL)/\(release.tag)/\(release.archive)")
    }

    /// Cheap: a few stat calls and the hash of the 5 KB manifest. Runs before every boot.
    public func state() -> GuestState {
        let fm = FileManager.default
        var kernel: String?
        if let data = try? Data(contentsOf: paths.manifest),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            kernel = manifest["kernel"] as? String
        }
        func make(_ source: GuestState.Source, tag: String? = nil, needsFetch: Bool) -> GuestState {
            GuestState(source: source, path: paths.guest.path, kernel: kernel, tag: tag, pinnedTag: pin?.tag, needsFetch: needsFetch)
        }
        guard fm.fileExists(atPath: paths.kernel.path), fm.fileExists(atPath: paths.initramfs.path) else {
            return make(.missing, needsFetch: pin != nil)
        }
        guard let receipt = self.receipt(), let manifestSha = receipt.files["manifest.json"],
              (try? sha256Hex(of: paths.manifest)) == manifestSha else {
            return make(.local, needsFetch: false)
        }
        let incomplete = receipt.files.keys.contains { !fm.fileExists(atPath: paths.guest.appendingPathComponent($0).path) }
        // A release often ships the boot files of the one before it: 0.3.0 and 0.3.1 differ only
        // in the version the archive's THIRD_PARTY.md names, so their Image, initramfs.gz,
        // docker.img and manifest.json have the same hashes. Both the pin and the receipt carry
        // those hashes, so comparing them costs nothing and saves downloading 62 MB that is
        // already on disk; `fetch` then only rewrites the receipt.
        let sameFiles = pin.map { $0.files == receipt.files } ?? false
        let other = pin.map { $0.sha256 != receipt.sha256 && !sameFiles } ?? false
        return make(.release, tag: receipt.tag, needsFetch: pin != nil && (incomplete || other))
    }

    func receipt() -> GuestRelease? {
        guard let data = try? Data(contentsOf: receiptURL) else { return nil }
        return try? JSONDecoder().decode(GuestRelease.self, from: data)
    }

    /// Hashes every file of a downloaded guest against its release (~70 MB, a fraction of a
    /// second). Returns what does not match; empty for a guest built locally.
    public func verify() -> [String] {
        guard state().source == .release, let receipt = receipt() else { return [] }
        return receipt.files.sorted(by: { $0.key < $1.key }).compactMap { name, want in
            let got = try? sha256Hex(of: paths.guest.appendingPathComponent(name))
            return got == want ? nil : "\(name) does not match release \(receipt.tag)"
        }
    }

    /// Before a boot: downloads the pinned guest when there is none, or when it came from another
    /// release. A guest built with `make guest` is used as it is. If updating an older release
    /// fails (offline), that guest boots instead. A release with the same boot files downloads
    /// nothing, but `fetch` still records the new tag: otherwise `dmx guest` kept naming the
    /// release the files first came from (v0.3.6 under 0.3.10 on one Mac).
    public func ensure(log: @Sendable (String) -> Void) async throws {
        let current = state()
        let renamed = current.source == .release && current.pinnedTag != nil && current.tag != current.pinnedTag
        guard current.needsFetch || renamed else { return }
        do {
            _ = try await fetch(force: false, log: log)
        } catch let error as DMXError where current.source == .release {
            log("cannot update the guest from \(current.tag ?? "?") to \(current.pinnedTag ?? "?"): \(error.message); booting the old one")
        }
    }

    /// Downloads the pinned release into the guest directory, replacing what is there. Without
    /// `force` only when `state().needsFetch`. Several dmx processes may call this at once (CLI,
    /// daemon); one downloads, the others find it done.
    public func fetch(force: Bool, log: @Sendable (String) -> Void) async throws -> GuestFetchReport {
        guard let pin else {
            throw DMXError("no_guest_release", "this dmx was built without a pinned guest release", hint: "build the guest from source: `make guest`")
        }
        guard let url = url(of: pin) else {
            throw DMXError("guest_download_failed", "bad release URL \(baseURL)", hint: "fix DMX_RELEASE_URL or `dmx config set release_url`")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let lock = try await lockGuest()
        defer { Darwin.close(lock) }
        if !force, !state().needsFetch {
            // Same boot files under a new release: keep them and record which release they are
            // now, so `dmx guest` and `dmx doctor` name the release this dmx pins.
            if let receipt = receipt(), receipt != pin, receipt.files == pin.files {
                try? writeReceipt(pin)
                log("guest \(pin.tag) has the files of \(receipt.tag) already; kept them")
            }
            return GuestFetchReport(fetched: false, url: nil, bytes: nil, ms: nil, guest: state())
        }

        let started = ContinuousClock.now
        let work = paths.home.appendingPathComponent("guest-download-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let archive = work.appendingPathComponent(pin.archive)
        log("downloading guest \(pin.tag) (\(formatSize(UInt64(pin.bytes)))) from \(url.absoluteString)")
        do {
            try await downloadVerified(url, to: archive, sha256: pin.sha256)
        } catch let error as DMXError where error.code == "download_failed" {
            throw DMXError("guest_download_failed", error.message,
                           hint: "check the network (or the mirror: release_url, DMX_RELEASE_URL), then `dmx guest fetch`; or build the guest from source: `make guest`")
        } catch let error as DMXError where error.code == "checksum_mismatch" {
            throw DMXError("checksum_mismatch", error.message,
                           hint: "the server did not send the guest this dmx was built for; retry `dmx guest fetch`, or check the mirror (release_url, DMX_RELEASE_URL)")
        }

        // The archive matched the pin, so unpacking it is safe; the files are checked again anyway.
        let unpacked = work.appendingPathComponent("guest", isDirectory: true)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", unpacked.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            throw DMXError("guest_download_failed", "cannot unpack \(pin.archive) (tar exited with \(tar.terminationStatus))", hint: "retry `dmx guest fetch`")
        }
        for (name, want) in pin.files where (try? sha256Hex(of: unpacked.appendingPathComponent(name))) != want {
            throw DMXError("checksum_mismatch", "\(name) in \(pin.archive) does not match this dmx's pin", hint: "retry `dmx guest fetch`, or check the mirror (release_url, DMX_RELEASE_URL)")
        }
        try writeReceipt(pin, in: unpacked)

        // Swap directories. A VM that is running keeps its open docker.img; the kernel and
        // initramfs were copied into guest RAM at boot.
        // Not `fileExists`, which follows links: a link to a guest that is gone is replaced too.
        if (try? fm.attributesOfItem(atPath: paths.guest.path)) != nil {
            try fm.moveItem(at: paths.guest, to: work.appendingPathComponent("old", isDirectory: true))
        }
        try fm.moveItem(at: unpacked, to: paths.guest)
        let ms = Int(seconds(ContinuousClock.now - started) * 1000)
        log("guest \(pin.tag) installed in \(paths.guest.path) (\(ms) ms)")
        return GuestFetchReport(fetched: true, url: url.absoluteString, bytes: pin.bytes, ms: ms, guest: state())
    }

    /// Records which release the guest in `dir` came from (`release.json`, read by `state()`).
    func writeReceipt(_ release: GuestRelease, in dir: URL? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let target = (dir ?? paths.guest).appendingPathComponent("release.json")
        // Atomic: `state()` reads this without the lock, and a truncated file would make a
        // downloaded guest look locally built, which dmx never replaces.
        try encoder.encode(release).write(to: target, options: .atomic)
    }

    /// One fetch at a time per DMX_HOME. Polls instead of blocking, so a daemon waiting here
    /// keeps answering its clients.
    private func lockGuest() async throws -> Int32 {
        let path = paths.home.appendingPathComponent("guest.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DMXError("guest_download_failed", "cannot open \(path): \(String(cString: strerror(errno)))") }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { Darwin.close(fd); throw error }
        }
        return fd
    }
}
