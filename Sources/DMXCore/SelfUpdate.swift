import Foundation

/// Replacing the installed dmx with a published release, which `install.sh` otherwise does by
/// hand. The release page carries `dmx-<version>-darwin-arm64.tar.gz` and its `.sha256`; this
/// downloads both, checks the archive, runs the binary it unpacks to see that it is the version
/// asked for, and swaps it in with a rename. The guest follows by itself: the new binary pins its
/// own guest release and downloads it before the next boot (`GuestStore`).
///
/// What this deliberately does not do is restart a running VM. A daemon that is already up keeps
/// serving the old version until it exits, so the report says what that daemon is and what the
/// user can do about it; when the VM is already off, the daemon is asked to quit so the next
/// command starts the new one.
public struct SelfUpdate: Sendable {
    public struct Report: Encodable, Sendable {
        public let ok = true
        /// The version running right now.
        public let current: String
        /// The version that was installed, or would be.
        public let target: String
        /// True when `target` is not what is installed.
        public let available: Bool
        /// False for `--check` and when the target is already installed.
        public let updated: Bool
        public let path: String?
        public let url: String?
        public let sha256: String?
        public let bytes: Int?
        /// The daemon that was running when the binary changed, if any.
        public let daemon: Daemon?
        /// The Developer ID team the new binary is signed with, when this dmx is signed too and
        /// the check ran; "skipped" for an unsigned dmx (a build from source).
        public let signature: String?

        public struct Daemon: Encodable, Sendable {
            public let version: String
            public let pid: Int32
            public let vmRunning: Bool
            /// What happened, or what the user has to do: `quit`, `stop_to_switch` or `older_cli`.
            public let handover: String
        }
    }

    public let current: String
    public let paths: Paths
    /// `<base>/<tag>/<asset>`, as for the guest: the `release_url` setting or `DMX_RELEASE_URL`
    /// replaces GitHub (a company mirror, or a local server when testing a release directory).
    public let baseURL: String
    /// The file this process runs from, which an update replaces.
    public let executable: URL

    public init(current: String, paths: Paths = Paths(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                executable: URL? = nil) {
        self.current = current
        self.paths = paths
        let custom = Config.mirror("DMX_RELEASE_URL", \.releaseUrl, paths: paths, environment: environment)
        baseURL = (custom ?? GuestRelease.defaultBaseURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let running = executable ?? Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        self.executable = running.resolvingSymlinksInPath()
    }

    var isDefaultBase: Bool { baseURL == GuestRelease.defaultBaseURL }
    var asset: (String) -> String { { "dmx-\($0)-darwin-arm64.tar.gz" } }

    /// `--version` reaches a URL and a directory name that is later removed, so it has to look
    /// like a version and nothing else.
    static func checked(version: String) throws -> String {
        let ok = version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.]+)?$", options: .regularExpression) != nil
        guard ok else {
            throw DMXError("update_bad_version", "\"\(version)\" is not a version",
                           hint: "name it as the release does, for example `dmx update --version 0.3.2`")
        }
        return version
    }

    /// True when `target` is a later version than `current` (numeric fields, left to right; a
    /// pre-release suffix sorts before the plain version, as SemVer says).
    static func isNewer(_ target: String, than current: String) -> Bool {
        func parts(_ v: String) -> ([Int], String) {
            let core = v.split(separator: "-", maxSplits: 1)
            let numbers = core[0].split(separator: ".").map { Int($0) ?? 0 }
            return (numbers, core.count > 1 ? String(core[1]) : "")
        }
        let (a, aPre) = parts(target), (b, bPre) = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        if aPre == bPre { return false }
        if aPre.isEmpty { return true }   // 0.3.2 is newer than 0.3.2-rc
        if bPre.isEmpty { return false }
        return aPre > bPre
    }

    func archiveURL(_ version: String) throws -> URL {
        guard let url = URL(string: "\(baseURL)/v\(version)/\(asset(version))") else {
            throw DMXError("update_url_invalid", "cannot build a download URL from \(baseURL)",
                           hint: "check it with `dmx config get release_url`, or clear it with `dmx config unset release_url`")
        }
        return url
    }

    /// The newest published version, from the redirect GitHub answers for `releases/latest`.
    /// A mirror has no such page, so a mirror needs the version named.
    public func latest() async throws -> String {
        guard isDefaultBase else {
            throw DMXError("update_version_required", "a release mirror has no \"latest\" page: \(baseURL)",
                           hint: "name the version: `dmx update --version <x.y.z>`")
        }
        let page = GuestRelease.defaultBaseURL.replacingOccurrences(of: "/download", with: "/latest")
        guard let url = URL(string: page) else {
            throw DMXError("update_url_invalid", "cannot build \(page)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DMXError("update_check_failed", "cannot reach \(page): \(error.localizedDescription)",
                           hint: "check the network, or name the version: `dmx update --version <x.y.z>`")
        }
        // URLSession follows the redirect, so the answer's URL is .../releases/tag/v<version>.
        let landed = (response.url ?? url).absoluteString
        guard let tag = landed.split(separator: "/").last, tag.hasPrefix("v"), tag.dropFirst().first?.isNumber == true else {
            throw DMXError("update_check_failed", "\(page) led to \(landed), which names no release",
                           hint: "name the version: `dmx update --version <x.y.z>`")
        }
        return String(tag.dropFirst())
    }

    /// Resolves what an update would install without downloading anything.
    public func check(version wanted: String?) async throws -> Report {
        let target: String
        if let wanted { target = try Self.checked(version: wanted) } else { target = try await latest() }
        return Report(current: current, target: target, available: Self.isNewer(target, than: current), updated: false,
                      path: executable.path, url: try archiveURL(target).absoluteString, sha256: nil, bytes: nil,
                      daemon: nil, signature: nil)
    }

    /// Downloads the release, checks it and replaces this binary. `force` installs a version that
    /// is already there, and allows replacing a binary inside a source checkout's `.build`.
    public func update(version wanted: String?, force: Bool,
                       progress: @Sendable (String) -> Void = { _ in }) async throws -> Report {
        let target: String
        if let wanted { target = try Self.checked(version: wanted) } else { target = try await latest() }
        guard target != current || force else {
            return Report(current: current, target: target, available: false, updated: false,
                          path: executable.path, url: nil, sha256: nil, bytes: nil, daemon: nil, signature: nil)
        }
        // Without a version named, only ever move forwards: a dmx newer than the newest release
        // (a build from source, or a release page that lost its latest tag) must not be replaced
        // by an older one behind the user's back.
        guard wanted != nil || force || Self.isNewer(target, than: current) else {
            throw DMXError("update_not_newer", "the newest release is \(target), older than this dmx (\(current))",
                           hint: "install it anyway with `dmx update --version \(target)`")
        }
        try checkDestination(force: force)

        let url = try archiveURL(target)
        let expected = try await publishedSHA256(of: url)
        // Per process: two updates running at once must not share the directory one of them is
        // verifying, or the file checked and the file installed could be different.
        let work = paths.downloads.appendingPathComponent("update-\(target)-\(getpid())", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let archive = work.appendingPathComponent(asset(target))
        progress("downloading dmx \(target) from \(url.host ?? baseURL)")
        try await downloadVerified(url, to: archive, sha256: expected)
        let bytes = (try? fm.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? nil

        try DockerTools.untar(archive, member: "dmx", into: work)
        let new = work.appendingPathComponent("dmx")
        // Before anything touches it: a link named `dmx` in the archive would make the checks
        // below read the binary it points at — this one — the chmod change that binary's mode,
        // and the install replace it with a link to itself. attributesOfItem does not follow it.
        let kind = try fm.attributesOfItem(atPath: new.path)[.type] as? FileAttributeType
        guard kind == .typeRegular else {
            throw DMXError("update_failed", "\(asset(target)) does not hold a plain dmx binary (\(kind?.rawValue ?? "unknown"))",
                           hint: "the release may be broken or the download tampered with; report it at \(Self.issues)")
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: new.path)
        // Signature before execution: running the binary to read its version executes it, and
        // until the signature is checked the only thing vouching for it is a sha256 that came
        // from the same server as the binary.
        let signature = try checkSignature(of: new)
        try check(binary: new, is: target)
        let checked = try sha256Hex(of: new)

        // Same directory, so the rename is atomic and cannot leave a half-written dmx behind.
        let staged = executable.deletingLastPathComponent().appendingPathComponent(".dmx.update-\(getpid())")
        try? fm.removeItem(at: staged)
        do {
            try fm.copyItem(at: new, to: staged)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            // The copy is what gets installed, so the copy is what has to match: another process
            // of this user could otherwise swap it between the checks and the rename.
            guard try sha256Hex(of: staged) == checked else {
                throw DMXError("update_failed", "the copy at \(staged.path) is not the binary that was checked",
                               hint: "run `dmx update` again")
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw DMXError("update_not_writable", "cannot write next to \(executable.path): \(error.localizedDescription)",
                           hint: "install it where you can write: `curl -fsSL \(baseURL)/v\(target)/install.sh | PREFIX=$HOME/.local sh`")
        }
        guard rename(staged.path, executable.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: staged)
            throw DMXError("update_not_writable", "cannot replace \(executable.path): \(reason)",
                           hint: "install it where you can write: `curl -fsSL \(baseURL)/v\(target)/install.sh | PREFIX=$HOME/.local sh`")
        }
        progress("installed dmx \(target) at \(executable.path)")
        return Report(current: current, target: target, available: true, updated: true,
                      path: executable.path, url: url.absoluteString, sha256: expected, bytes: bytes,
                      daemon: try await handOver(target: target, progress: progress), signature: signature)
    }

    /// The sha256 the release publishes next to the archive. install.sh checks the same file when
    /// it is asked for another version than the one written into it.
    func publishedSHA256(of archive: URL) async throws -> String {
        let url = URL(string: archive.absoluteString + ".sha256")!
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw DMXError("update_failed", "cannot download \(url.absoluteString): \(error.localizedDescription)",
                           hint: "check the version exists: \(baseURL.replacingOccurrences(of: "/download", with: ""))")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DMXError("update_failed", "\(url.absoluteString) answered HTTP \(http.statusCode)",
                           hint: "check the version exists: \(baseURL.replacingOccurrences(of: "/download", with: ""))")
        }
        // The file is "<hex>  <name>" as shasum writes it, or just the digest; either case.
        let hex = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else {
            throw DMXError("update_failed", "\(url.absoluteString) does not hold a sha256",
                           hint: "that release is incomplete; install another with `dmx update --version <x.y.z>`")
        }
        return hex
    }

    /// Refuses to overwrite a binary this should not: one built from source, or one in a directory
    /// the user cannot write.
    func checkDestination(force: Bool) throws {
        let path = executable.path
        if !force, path.contains("/.build/") {
            throw DMXError("update_source_build", "\(path) is a build from source, not an installed release",
                           hint: "update the installed copy instead, or pass --force to replace this one")
        }
        let dir = executable.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: dir) else {
            throw DMXError("update_not_writable", "\(dir) is not writable by this user",
                           hint: "install it where you can write: `curl -fsSL \(baseURL)/latest/install.sh | PREFIX=$HOME/.local sh`")
        }
    }

    /// Runs the downloaded binary to see that it works and is the version the release claims.
    func check(binary: URL, is target: String) throws {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw DMXError("update_failed", "the downloaded dmx does not run: \(error.localizedDescription)",
                           hint: "check that this Mac is Apple Silicon and the release is for macOS")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let reported = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, reported == target else {
            throw DMXError("update_failed", "the downloaded dmx says it is \(reported.isEmpty ? "nothing" : reported), not \(target)",
                           hint: "the release may be broken; report it to dmx")
        }
    }

    /// A sha256 published next to the archive proves the transfer, not who made it: the same
    /// server serves both. So when this dmx is signed with a Developer ID, the download has to
    /// carry the same team's signature and pass `codesign --verify`. An unsigned dmx (built from
    /// source, or `--ad-hoc` released) has nothing to compare against, so the check is skipped
    /// rather than faked.
    func checkSignature(of binary: URL) throws -> String {
        guard let team = try Self.teamToRequire(current: Self.teamIdentifier(of: executable),
                                                downloaded: Self.teamIdentifier(of: binary)) else {
            return "skipped: this dmx is not Developer ID signed"
        }
        // Not just "the signature is intact": the requirement ties it to Apple's anchor and this
        // team, so a validly signed binary from anyone else is refused.
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", "-R",
                            "=anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"", binary.path]
        verify.standardOutput = Pipe()
        verify.standardError = Pipe()
        do {
            try verify.run()
        } catch {
            // waitUntilExit() on a process that never launched raises, which would end dmx here.
            throw DMXError("update_signature_invalid", "cannot run codesign: \(error.localizedDescription)",
                           hint: "check that /usr/bin/codesign exists, then run `dmx update` again")
        }
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else {
            throw DMXError("update_signature_invalid", "codesign rejects the downloaded dmx (exit \(verify.terminationStatus))",
                           hint: "the download may be damaged; run `dmx update` again")
        }
        return team
    }

    /// Which team the download has to satisfy: none when this dmx is unsigned, so there is
    /// nothing to compare against; otherwise this dmx's team, with an error when the download
    /// carries no team or a different one. Split out so every branch can be tested.
    static func teamToRequire(current: String?, downloaded: String?) throws -> String? {
        guard let team = current else { return nil }
        guard let signed = downloaded else {
            throw DMXError("update_unsigned", "the downloaded dmx is not signed by a Developer ID, but this one is (team \(team))",
                           hint: "the release may be broken or the download tampered with; report it at \(issues)")
        }
        guard signed == team else {
            throw DMXError("update_signature_mismatch", "the downloaded dmx is signed by team \(signed), this one by \(team)",
                           hint: "the release may be broken or the download tampered with; report it at \(issues)")
        }
        return team
    }

    static let issues = "https://github.com/cothis/dmx/issues"

    /// The Developer ID team a binary is signed with, nil for ad-hoc or unsigned ones.
    /// `codesign -dv` prints to stderr, one `TeamIdentifier=` line, `not set` without a team.
    static func teamIdentifier(of binary: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=4", binary.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let team = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return team == "not set" ? nil : team
        }
        return nil
    }

    /// The new binary only takes over when the old daemon is gone, so say what that will take.
    ///
    /// This asks the daemon to quit in no case. `quit` powers the VM off, and the states a daemon
    /// reports are `stopped`, `starting`, `running` and `stopping`: treating everything that is
    /// not `running` as idle would kill a VM that is booting, and a `status` call that fails or
    /// times out would look the same. A daemon whose VM is off exits by itself ten seconds after
    /// its last client anyway, which is the whole benefit, without the race.
    func handOver(target: String, progress: @Sendable (String) -> Void) async throws -> Report.Daemon? {
        let connected = try? await DaemonClient.connect(paths: paths, start: false)
        guard let client = connected else { return nil }
        defer { client.close() }
        let hello = client.hello
        let state = (try? await client.status())?.state
        if state == "stopped" {
            progress("the daemon (pid \(hello.pid)) is idle and exits shortly; the next command runs \(target)")
            return Report.Daemon(version: hello.version, pid: hello.pid, vmRunning: false, handover: "exits_soon")
        }
        progress("the VM keeps running on dmx \(hello.version) (pid \(hello.pid)); `dmx stop` hands it over")
        return Report.Daemon(version: hello.version, pid: hello.pid, vmRunning: state == "running", handover: "stop_to_switch")
    }
}
