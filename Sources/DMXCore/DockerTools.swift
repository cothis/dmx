import Foundation

/// The docker CLI, the Compose and Buildx plugins and the keychain credential helper, as Docker
/// Desktop ships them, so Docker works without Homebrew. dmx downloads pinned darwin-arm64 builds,
/// checks their sha256, and keeps them in `~/.dmx/bin` and `~/.dmx/cli-plugins`. The plugins reach
/// the CLI through `cliPluginsExtraDirs` in the docker config (as Docker Desktop's do), so
/// `~/.docker/cli-plugins` is not touched; `docker` and the credential helper are linked into
/// `~/.local/bin` when that is on PATH. With Buildx present, `docker build` is BuildKit's
/// (dockerd has it built in) instead of the deprecated legacy builder.
public enum DockerTools {
    public struct Tool: Sendable {
        public let name: String
        public let version: String
        public let url: URL
        /// sha256 and size of what `url` serves.
        public let sha256: String
        public let size: Int
        /// The file to take out of a .tgz, and its sha256; nil when the download is the binary.
        public let member: (path: String, sha256: String)?
        /// The installed file name.
        public let file: String
        /// A docker CLI plugin (in `cli-plugins`) rather than a program (in `bin`).
        public let plugin: Bool

        /// The sha256 of the installed file.
        var installedSHA256: String { member?.sha256 ?? sha256 }

        /// Where to download it: `url`, or the file of that name under a mirror.
        func source(mirror: String?) -> URL {
            mirror.flatMap { URL(string: "\($0)/\(url.lastPathComponent)") } ?? url
        }
    }

    /// The mirror for the tools: `DMX_TOOLS_URL`, or the `tools_url` setting.
    static func mirror(paths: Paths, environment: [String: String]) -> String? {
        Config.mirror("DMX_TOOLS_URL", \.toolsUrl, paths: paths, environment: environment)
    }

    /// Pinned on 2026-10-24. Compose, Buildx and the credential helper match the checksums.txt of
    /// their GitHub releases; download.docker.com publishes no checksums for the static CLI, so its
    /// tgz is pinned as first downloaded (its `docker` reports 29.9.2, build a82e528, the version
    /// of dockerd in the guest).
    public static let pinned: [Tool] = [
        Tool(name: "docker", version: "29.9.2",
             url: URL(string: "https://download.docker.com/mac/static/stable/aarch64/docker-29.9.2.tgz")!,
             sha256: "ea8a2ce5ac31f9f5f3fb711a7a485e1e46cc7a69798a629a70306f6e6af25b7a", size: 19_654_797,
             member: ("docker/docker", "cbcda5a0eb03c42037e90fff45ceb78763c8f80509c0f5009c117e0ef7779b96"),
             file: "docker", plugin: false),
        Tool(name: "docker-credential-osxkeychain", version: "0.9.12",
             url: URL(string: "https://github.com/docker/docker-credential-helpers/releases/download/v0.9.12/docker-credential-osxkeychain-v0.9.12.darwin-arm64")!,
             sha256: "0e43ec22d3fd186b2d69a3c76fd9ac0a1ae4ec4f2c2b2e4ee156e048c8258cb0", size: 2_439_634,
             member: nil, file: "docker-credential-osxkeychain", plugin: false),
        Tool(name: "compose", version: "5.6.1",
             url: URL(string: "https://github.com/docker/compose/releases/download/v5.6.1/docker-compose-darwin-aarch64")!,
             sha256: "fcce41226abd2b7b2936094e688bbd61284673dddafea542e08cb9a3b4423a8b", size: 30_813_090,
             member: nil, file: "docker-compose", plugin: true),
        Tool(name: "buildx", version: "0.38.1",
             url: URL(string: "https://github.com/docker/buildx/releases/download/v0.38.1/buildx-v0.38.1.darwin-arm64")!,
             sha256: "6f20ba2437865311ef99015bf5d1039c3c8e4d2177c1c64aa41b134b5ecd3012", size: 65_479_600,
             member: nil, file: "docker-buildx", plugin: true),
    ]

    public struct Installed: Encodable, Sendable {
        public let name: String
        public let version: String
        public let path: String
        /// Where it is (or would be) downloaded from.
        public let url: String
        /// `installed` (just now), `present` (already there, sha256 checked), `missing`, or
        /// `changed` (a file with another sha256; `dmx tools install` replaces it).
        public let state: String
        public var downloadedBytes: Int = 0
    }

    public struct Link: Encodable, Sendable {
        public let path: String
        public let target: String
        /// `created`, `present`, `replaced` (a link that pointed at nothing), or `skipped` when
        /// something else has that name. `dmx tools ls` reports such a dangling link as `broken`.
        public let state: String
    }

    public struct Report: Encodable, Sendable {
        public var ok = true
        public let tools: [Installed]
        public let bin: String
        public let cliPlugins: String
        /// The docker config whose `cliPluginsExtraDirs` lists `cliPlugins`.
        public let configDir: String
        public let pluginsConfigured: Bool
        /// Links to `bin` in a directory on PATH (`~/.local/bin`); empty when it is not on PATH.
        public let links: [Link]
        /// The `docker` PATH finds first, and whether it is dmx's.
        public let dockerOnPath: String?
        public let dmxDockerOnPath: Bool
        /// What to do so that `docker` is dmx's, when it is not.
        public let hint: String?
    }

    /// Downloads what is missing or changed, verifies it, and makes it usable: plugins in the
    /// docker config, `docker` linked into `~/.local/bin` if that is on PATH. Interrupted
    /// downloads resume from `~/.dmx/downloads`. Never replaces files dmx did not put there.
    public static func install(paths: Paths, configDir: URL = DockerContext.configDir(),
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               linkDirectory: URL? = nil,
                               tools: [Tool] = pinned,
                               progress: @Sendable (String) -> Void = { _ in }) async throws -> Report {
        var installed: [Installed] = []
        let mirror = mirror(paths: paths, environment: environment)
        for tool in tools {
            try Task.checkCancellation()
            let dest = destination(tool, paths)
            let source = tool.source(mirror: mirror)
            if (try? sha256Hex(of: dest)) == tool.installedSHA256 {
                installed.append(Installed(name: tool.name, version: tool.version, path: dest.path, url: source.absoluteString, state: "present"))
                continue
            }
            progress("downloading \(tool.name) \(tool.version) (\(tool.size >> 20) MB) from \(source.host ?? source.absoluteString)")
            let part = paths.downloads.appendingPathComponent(tool.url.lastPathComponent + ".part")
            let fetched = try await fetch(tool, from: source, to: part)
            try Task.checkCancellation()
            try place(tool, from: part, at: dest, scratch: paths.downloads)
            try? FileManager.default.removeItem(at: part)
            installed.append(Installed(name: tool.name, version: tool.version, path: dest.path, url: source.absoluteString, state: "installed", downloadedBytes: fetched))
        }
        try Task.checkCancellation()
        // A concurrent updater may own a sibling download. Remove only an empty directory.
        _ = rmdir(paths.downloads.path)

        if tools.contains(where: \.plugin) {
            try DockerContext.updateConfig(configDir) { config in
                var dirs = (config["cliPluginsExtraDirs"] as? [String]) ?? []
                dirs.removeAll { $0 == paths.cliPlugins.path }
                // First, so these win over another copy of the same plugin (Homebrew's, say).
                dirs.insert(paths.cliPlugins.path, at: 0)
                config["cliPluginsExtraDirs"] = dirs
            }
        }
        var links: [Link] = []
        let dir = linkDirectory ?? linkDir(environment)
        if linkDirectory != nil || searchPath(environment).contains(dir.standardizedFileURL.path) {
            for tool in tools where !tool.plugin {
                links.append(try link(destination(tool, paths), in: dir))
            }
        }
        return report(paths: paths, configDir: configDir, environment: environment, tools: installed, links: links)
    }

    /// What is installed and where, without changing anything.
    public static func status(paths: Paths, configDir: URL = DockerContext.configDir(),
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              tools: [Tool] = pinned) -> Report {
        let mirror = mirror(paths: paths, environment: environment)
        let installed = tools.map { tool in
            let dest = destination(tool, paths)
            let state: String
            switch try? sha256Hex(of: dest) {
            case nil: state = "missing"
            case tool.installedSHA256: state = "present"
            default: state = "changed"
            }
            return Installed(name: tool.name, version: tool.version, path: dest.path, url: tool.source(mirror: mirror).absoluteString, state: state)
        }
        let dir = linkDir(environment)
        let links = tools.filter { !$0.plugin }.compactMap { tool -> Link? in
            let path = dir.appendingPathComponent(tool.file)
            let target = destination(tool, paths)
            guard let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: path.path) else { return nil }
            let state = existing == target.path ? "present" : FileManager.default.fileExists(atPath: path.path) ? "skipped" : "broken"
            return Link(path: path.path, target: existing, state: state)
        }
        return report(paths: paths, configDir: configDir, environment: environment, tools: installed, links: links)
    }

    /// Undoes `install`: the links that point at dmx's files, the plugin directory in the docker
    /// config, and the files themselves. Succeeds when nothing was installed.
    public static func uninstall(paths: Paths, configDir: URL = DockerContext.configDir(),
                                 environment: [String: String] = ProcessInfo.processInfo.environment,
                                 tools: [Tool] = pinned) throws {
        let fm = FileManager.default
        let dir = linkDir(environment)
        for tool in tools {
            let dest = destination(tool, paths)
            let path = dir.appendingPathComponent(tool.file)
            if (try? fm.destinationOfSymbolicLink(atPath: path.path)) == dest.path { try? fm.removeItem(at: path) }
            try? fm.removeItem(at: dest)
        }
        try? fm.removeItem(at: paths.downloads)
        for empty in [paths.dockerBin, paths.cliPlugins] where (try? fm.contentsOfDirectory(atPath: empty.path))?.isEmpty == true {
            try? fm.removeItem(at: empty)
        }
        guard fm.fileExists(atPath: configDir.appendingPathComponent("config.json").path) else { return }
        try DockerContext.updateConfig(configDir) { config in
            guard var dirs = config["cliPluginsExtraDirs"] as? [String], dirs.contains(paths.cliPlugins.path) else { return }
            dirs.removeAll { $0 == paths.cliPlugins.path }
            config["cliPluginsExtraDirs"] = dirs.isEmpty ? nil : dirs
        }
    }

    static func destination(_ tool: Tool, _ paths: Paths) -> URL {
        (tool.plugin ? paths.cliPlugins : paths.dockerBin).appendingPathComponent(tool.file)
    }

    /// `$HOME/.local/bin`, where `make install` puts dmx.
    static func linkDir(_ environment: [String: String]) -> URL {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local/bin", isDirectory: true)
    }

    static func searchPath(_ environment: [String: String]) -> [String] {
        (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }
    }

    private static func report(paths: Paths, configDir: URL, environment: [String: String], tools: [Installed], links: [Link]) -> Report {
        let config = (try? Data(contentsOf: configDir.appendingPathComponent("config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let configured = (config?["cliPluginsExtraDirs"] as? [String])?.contains(paths.cliPlugins.path) == true
        let ours = paths.dockerBin.appendingPathComponent("docker").resolvingSymlinksInPath().path
        let found = searchPath(environment).lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent("docker").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let isOurs = found.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == ours } ?? false
        var hint: String?
        if !isOurs {
            let dir = linkDir(environment).path
            if let found, links.contains(where: { $0.state != "skipped" }) {
                hint = "\(found) comes first on PATH; put \(dir) before \(URL(fileURLWithPath: found).deletingLastPathComponent().path) in PATH, or run \(ours)"
            } else {
                hint = "add dmx's tools to PATH (in your shell's rc file): export PATH=\"\(paths.dockerBin.path):$PATH\""
            }
        }
        return Report(tools: tools, bin: paths.dockerBin.path, cliPlugins: paths.cliPlugins.path, configDir: configDir.path,
                      pluginsConfigured: configured, links: links, dockerOnPath: found, dmxDockerOnPath: isOurs, hint: hint)
    }

    /// Links `dir/<name>` to `target` unless something else already has the name.
    private static func link(_ target: URL, in dir: URL) throws -> Link {
        let fm = FileManager.default
        let path = dir.appendingPathComponent(target.lastPathComponent)
        var replaced = false
        if let existing = try? fm.destinationOfSymbolicLink(atPath: path.path) {
            // A link to nothing (fileExists follows it) is nobody's working docker: typically dmx's
            // own, left by a DMX_HOME that was deleted, or an uninstalled engine's. Left alone it
            // would keep `docker` broken; anything that still resolves stays untouched.
            guard existing != target.path, !fm.fileExists(atPath: path.path) else {
                return Link(path: path.path, target: existing, state: existing == target.path ? "present" : "skipped")
            }
            try? fm.removeItem(at: path)
            replaced = true
        }
        if fm.fileExists(atPath: path.path) {
            return Link(path: path.path, target: path.path, state: "skipped")
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: path, withDestinationURL: target)
        } catch {
            throw DMXError("link_failed", "cannot link \(path.path) to \(target.path): \(error.localizedDescription)",
                           hint: "check that \(dir.path) is writable, or put \(target.deletingLastPathComponent().path) on PATH yourself")
        }
        return Link(path: path.path, target: target.path, state: replaced ? "replaced" : "created")
    }

    /// Downloads `tool` into `part`, resuming what an earlier attempt left, retrying network
    /// failures, and checks size and sha256. Returns the bytes transferred.
    static func fetch(_ tool: Tool, from url: URL, to part: URL) async throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        var transferred = 0
        var lastError = ""
        var attempt = 0
        while true {
            try Task.checkCancellation()
            var have = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0
            if have > tool.size {
                try? fm.removeItem(at: part)
                have = 0
            }
            if have == tool.size { break }
            attempt += 1
            if attempt > 4 {
                throw DMXError("download_failed", "cannot download \(url.absoluteString): \(lastError)",
                               hint: "check the network (and a proxy, if any), then run `dmx tools install` again; it resumes where this stopped")
            }
            if attempt > 1 { try await Task.sleep(for: .seconds(attempt - 1)) }
            do {
                transferred += try await Transfer.run(url, to: part, from: have)
            } catch let error as Transfer.Failure {
                lastError = error.message
                if error.restart { try? fm.removeItem(at: part) }
                if !error.retry { attempt = 4 }
            }
        }
        guard (try? sha256Hex(of: part)) == tool.sha256 else {
            try? fm.removeItem(at: part)
            throw DMXError("checksum_mismatch", "\(url.absoluteString) does not have the sha256 dmx pins for \(tool.name) \(tool.version); deleted it",
                           hint: "run `dmx tools install` again; if this repeats, the file changed upstream: do not use it, report it to dmx")
        }
        return transferred
    }

    /// Puts a verified download in place: the binary (or the member of the .tgz, checked against
    /// its own sha256) is renamed over `dest`, so the old file stays until the new one is complete
    /// and a running copy keeps its inode.
    private static func place(_ tool: Tool, from part: URL, at dest: URL, scratch: URL) throws {
        let fm = FileManager.default
        var source = part
        let unpacked = scratch.appendingPathComponent("unpack-\(tool.file)", isDirectory: true)
        defer { try? fm.removeItem(at: unpacked) }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let member = tool.member {
                try? fm.removeItem(at: unpacked)
                try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
                try untar(part, member: member.path, into: unpacked)
                source = unpacked.appendingPathComponent(member.path)
                guard (try? sha256Hex(of: source)) == member.sha256 else {
                    try? fm.removeItem(at: part)
                    throw DMXError("checksum_mismatch", "\(member.path) in \(tool.url.lastPathComponent) does not have the sha256 dmx pins; deleted it",
                                   hint: "run `dmx tools install` again; if this repeats, report it to dmx")
                }
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
            let temp = dest.deletingLastPathComponent().appendingPathComponent(".\(tool.file).new")
            try? fm.removeItem(at: temp)
            try fm.moveItem(at: source, to: temp)
            guard rename(temp.path, dest.path) == 0 else {
                throw DMXError("install_failed", "cannot rename \(temp.path) to \(dest.path): \(String(cString: strerror(errno)))",
                               hint: "check that \(dest.deletingLastPathComponent().path) is writable, then run `dmx tools install` again")
            }
            try? fm.removeItem(at: part)
        } catch let error as DMXError {
            throw error
        } catch {
            throw DMXError("install_failed", "cannot install \(dest.path): \(error.localizedDescription)",
                           hint: "check that \(dest.deletingLastPathComponent().path) is writable, then run `dmx tools install` again")
        }
    }

    /// Also used by SelfUpdate, which takes `dmx` out of a release tarball.
    static func untar(_ archive: URL, member: String, into dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", dir.path, member]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DMXError("install_failed", "cannot unpack \(member) from \(archive.path): \(String(decoding: data, as: UTF8.self))",
                           hint: "run `dmx tools install` again")
        }
    }
}

extension Paths {
    /// The docker CLI and the credential helper dmx installs (`dmx tools install`).
    public var dockerBin: URL { home.appendingPathComponent("bin", isDirectory: true) }
    /// The Compose and Buildx plugins, listed in the docker config's `cliPluginsExtraDirs`.
    public var cliPlugins: URL { home.appendingPathComponent("cli-plugins", isDirectory: true) }
    /// Downloads in progress, kept between attempts so they resume.
    public var downloads: URL { home.appendingPathComponent("downloads", isDirectory: true) }
}

/// One HTTP GET into a file, appending from `offset` when the server honours the range. A
/// delegate streams the body to disk instead of holding 65 MB in memory.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Failure: Error {
        let message: String
        /// Worth another attempt (network trouble, a server error).
        var retry = true
        /// The partial file is unusable: start over.
        var restart = false
    }

    private let lock = NSLock()
    private let file: FileHandle
    private let offset: Int
    private var written = 0
    private var failure: Failure?
    private var continuation: CheckedContinuation<Int, Error>?

    private init(file: FileHandle, offset: Int) {
        self.file = file
        self.offset = offset
    }

    static func run(_ url: URL, to part: URL, from offset: Int) async throws -> Int {
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        guard let file = try? FileHandle(forWritingTo: part) else {
            throw Failure(message: "cannot write \(part.path)", retry: false)
        }
        defer { try? file.close() }
        let transfer = Transfer(file: file, offset: offset)
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let configuration = URLSessionConfiguration.ephemeral
        // Seconds without data before an attempt fails; the whole download may take longer.
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let result: Int = try await withCheckedThrowingContinuation { continuation in
                    transfer.lock.withLock { transfer.continuation = continuation }
                    session.dataTask(with: request).resume()
                }
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: { session.invalidateAndCancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        do {
            switch status {
            case 206 where offset > 0:
                try file.seekToEnd()
            case 200:
                // The whole file (no range asked, or the server ignored it).
                try file.truncate(atOffset: 0)
            case 416:
                failure = Failure(message: "the server refused to resume (HTTP 416)", restart: true)
            default:
                let retry = status >= 500 || status == 408 || status == 429
                failure = Failure(message: "HTTP \(status)", retry: retry)
            }
        } catch {
            failure = Failure(message: "cannot write the download: \(error.localizedDescription)", retry: false)
        }
        completionHandler(failure == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        do {
            try file.write(contentsOf: data)
            written += data.count
        } catch {
            failure = Failure(message: "cannot write the download: \(error.localizedDescription)", retry: false)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let failure = self.failure ?? error.map { Failure(message: $0.localizedDescription) }
        let continuation = self.continuation
        self.continuation = nil
        let written = self.written
        lock.unlock()
        if let failure { continuation?.resume(throwing: failure) } else { continuation?.resume(returning: written) }
    }
}
