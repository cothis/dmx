import CryptoKit
import Foundation

/// The `docker context` named dmx, pointing the docker CLI at `~/.dmx/docker.sock`, as Docker
/// Desktop's `desktop-linux` does for its socket. Written in the docker CLI's own context store,
/// so it works whether or not the CLI is installed yet: `$DOCKER_CONFIG` (default `~/.docker`)
/// holds `contexts/meta/<sha256 of the name>/meta.json`, and `currentContext` in config.json
/// selects it. `DOCKER_HOST` and `DOCKER_CONTEXT` in the environment still win over it.
public enum DockerContext {
    public static let name = "dmx"

    public struct Report: Codable, Sendable, Equatable {
        public let name: String
        /// The socket the context points at.
        public let host: String
        public let configDir: String
        /// Whether it is the docker CLI's current context now.
        public let selected: Bool
    }

    /// `$DOCKER_CONFIG`, or `~/.docker`.
    public static func configDir(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["DOCKER_CONFIG"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker", isDirectory: true)
    }

    static func metaDir(_ configDir: URL) -> URL {
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return configDir.appendingPathComponent("contexts/meta/\(digest)", isDirectory: true)
    }

    /// Creates or updates the context and makes it the current one, keeping everything else in
    /// config.json.
    public static func install(socket: URL, configDir: URL) throws -> Report {
        let host = "unix://\(socket.path)"
        let meta: [String: Any] = [
            "Name": name,
            "Metadata": ["Description": "dmx (\(socket.path))"],
            "Endpoints": ["docker": ["Host": host, "SkipTLSVerify": false]],
        ]
        let dir = metaDir(configDir)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys, .withoutEscapingSlashes])
                .write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        } catch {
            throw DMXError("docker_context_failed", "cannot write the dmx docker context in \(dir.path): \(error.localizedDescription)",
                           hint: "check that \(configDir.path) is writable, then run `dmx install` again")
        }
        try updateConfig(configDir) { $0["currentContext"] = name }
        return Report(name: name, host: host, configDir: configDir.path, selected: true)
    }

    /// Removes the context; if it was the current one, the docker CLI goes back to its default.
    public static func uninstall(configDir: URL) throws {
        try? FileManager.default.removeItem(at: metaDir(configDir))
        let file = configDir.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try updateConfig(configDir) { config in
            if config["currentContext"] as? String == name { config["currentContext"] = nil }
        }
    }

    /// Reads config.json (an empty object if there is none), changes it, and writes it back with
    /// its permissions. A file that is not a JSON object is left alone.
    static func updateConfig(_ configDir: URL, _ change: (inout [String: Any]) -> Void) throws {
        let file = configDir.appendingPathComponent("config.json")
        var config: [String: Any] = [:]
        var mode: Int = 0o600
        if let data = try? Data(contentsOf: file) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DMXError("docker_context_failed", "\(file.path) is not a JSON object; not changing it",
                               hint: "fix it, then run `dmx install` again, or select the context yourself: `docker context use \(name)`")
            }
            config = object
            mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? mode
        }
        change(&config)
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try (data + Data("\n".utf8)).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        } catch {
            throw DMXError("docker_context_failed", "cannot write \(file.path): \(error.localizedDescription)",
                           hint: "check that \(configDir.path) is writable, then run `dmx install` again")
        }
    }
}

/// `~/.docker/run/docker.sock`, where Docker Desktop puts its socket, as a symlink to
/// `~/.dmx/docker.sock`: tools that look there instead of reading the docker context (some SDKs and
/// IDE plugins, Testcontainers' fallbacks) then find dmx too. It is in the user's own directory, so
/// no sudo; `/var/run/docker.sock` needs root (Docker Desktop's privileged helper) and is left to
/// `DOCKER_HOST`. A socket something else serves there, or a link to another engine's socket, stays.
public enum DockerSocketLink {
    public struct Report: Codable, Sendable, Equatable {
        public let path: String
        public let target: String
        /// Whether the path leads to dmx now.
        public let linked: Bool
        /// Why it was left alone, when it was.
        public let skipped: String?
    }

    public static func path(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".docker/run/docker.sock")
    }

    /// Points `link` at `socket` unless it is taken. Never fails: a tool that reads the docker
    /// context does not need the link, so a taken path is reported, not thrown.
    public static func install(socket: URL, link: URL) -> Report {
        func report(_ linked: Bool, _ skipped: String? = nil) -> Report {
            Report(path: link.path, target: socket.path, linked: linked, skipped: skipped)
        }
        var info = stat()
        if lstat(link.path, &info) == 0 {
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) ?? ""
                if destination == socket.path { return report(true) }
                // Not probed by connecting: a link to another dmx's docker.sock would boot its VM.
                if FileManager.default.fileExists(atPath: link.path) {
                    return report(false, "it links to \(destination), which exists")
                }
            case S_IFSOCK:
                if accepts(link.path) { return report(false, "another engine (Docker Desktop?) serves it") }
            default:
                return report(false, "it is not a socket or a symlink")
            }
            // A dangling link or a socket nobody serves: left behind by an engine that is gone.
            unlink(link.path)
        }
        do {
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: socket.path)
        } catch {
            return report(false, error.localizedDescription)
        }
        return report(true)
    }

    /// Removes the link if it is dmx's.
    public static func uninstall(socket: URL, link: URL) {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == socket.path { unlink(link.path) }
    }

    private static func accepts(_ path: String) -> Bool {
        guard var address = try? unixAddress(URL(fileURLWithPath: path)) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }
}
