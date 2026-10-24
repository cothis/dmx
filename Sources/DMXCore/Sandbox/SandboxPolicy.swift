import Foundation

/// What a sandbox may do. Everything not granted is denied: no network, no host files, a TTL.
/// Stored as JSON in a label on the sandbox's container, so rollbacks and forks keep it and any
/// dmx (the daemon's TTL reaper included) can read it back. See docs/sandbox.md.
public struct SandboxPolicy: Codable, Sendable, Equatable {
    /// Image reference; the default is pinned by digest.
    public var image = SandboxPolicy.defaultImage
    /// `none` (loopback only), `all`, or `allowlist` (only `allow`, plus DNS).
    public var network = "none"
    /// Hosts, addresses and CIDRs reachable with `allowlist`, as given.
    public var allow: [String] = []
    public var mounts: [SandboxMount] = []
    public var cpus = SandboxPolicy.defaultCpus
    /// Memory limit, e.g. "1G"; no swap beyond it.
    public var memory = SandboxPolicy.defaultMemory
    public var pids = SandboxPolicy.defaultPids
    /// Seconds from creation (or from a fork) until the sandbox is removed.
    public var ttlS = SandboxPolicy.defaultTTL
    /// Environment of the sandbox's processes, `KEY=VALUE`.
    public var env: [String] = []
    public var workdir: String?
    /// The main process. Default: `sleep` for the TTL, which keeps the sandbox up for `exec`.
    public var command: [String]?

    public init() {}

    /// Alpine 3.24 (the multi-arch index), as of 2026-10-24: small, has a shell and busybox.
    public static let defaultImage = "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a"
    public static let defaultCpus = 2.0
    public static let defaultMemory = "1G"
    public static let defaultPids = 1024
    /// 30 minutes: long enough for an agent's task, short enough that a forgotten sandbox does
    /// not keep the VM up for long (a running sandbox holds off idle stop).
    public static let defaultTTL = 1800
    public static let maxTTL = 86400
    public static let networks = ["none", "all", "allowlist"]

    /// Checks the values that do not need the host or the VM.
    public func validate() throws {
        guard Self.networks.contains(network) else {
            throw policyError("network must be none, all, or a list of hosts and CIDRs, not \"\(network)\"")
        }
        if network == "allowlist" && allow.isEmpty { throw policyError("an allowlist needs at least one host or CIDR") }
        if network != "allowlist" && !allow.isEmpty { throw policyError("allow is only for network allowlist") }
        guard cpus > 0, cpus <= 64 else { throw policyError("cpus must be more than 0 and at most 64") }
        guard let bytes = try? parseSize(memory), bytes >= 6 << 20 else { throw policyError("memory must be a size of at least 6M, e.g. 512M or 2G, not \"\(memory)\"") }
        guard pids >= 16 else { throw policyError("pids must be at least 16") }
        guard ttlS >= 10, ttlS <= Self.maxTTL else { throw policyError("ttl must be between 10s and \(formatDuration(Self.maxTTL))") }
        guard !image.isEmpty, !image.contains(where: \.isWhitespace) else { throw policyError("image must be an image reference, e.g. alpine:3.24") }
        for item in env where !item.contains("=") || item.hasPrefix("=") { throw policyError("env entries are KEY=VALUE, not \"\(item)\"") }
        if let command, command.isEmpty { throw policyError("command must name a program") }
        if let workdir, !workdir.hasPrefix("/") { throw policyError("workdir must be an absolute path in the sandbox") }
        for (i, m) in mounts.enumerated() {
            guard m.path.hasPrefix("/"), m.path != "/" else { throw policyError("mount target \"\(m.path)\" must be an absolute path other than /") }
            if mounts[..<i].contains(where: { $0.path == m.path }) { throw policyError("two mounts at \(m.path)") }
        }
    }

    var memoryBytes: UInt64 { (try? parseSize(memory)) ?? 1 << 30 }

    /// Parses the CLI's and MCP's network value: `none`, `all`, or hosts and CIDRs separated by
    /// commas (an MCP array is joined first).
    public mutating func setNetwork(_ text: String) throws {
        let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if items.count == 1, items[0] == "none" || items[0] == "all" {
            network = items[0]
            allow = []
        } else if items.isEmpty {
            throw policyError("network is empty; use none, all, or hosts and CIDRs")
        } else {
            network = "allowlist"
            allow = items
        }
    }
}

/// A host directory the sandbox sees, read-only unless `writable`.
public struct SandboxMount: Codable, Sendable, Equatable {
    /// Absolute host path, symlinks resolved.
    public var host: String
    /// Where it appears in the sandbox.
    public var path: String
    public var writable: Bool

    public init(host: String, path: String, writable: Bool) {
        self.host = host
        self.path = path
        self.writable = writable
    }

    /// Parses `HOST[:PATH][:ro|:rw]`. PATH defaults to HOST; read-only unless `:rw`.
    public static func parse(_ text: String) throws -> SandboxMount {
        var parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var writable = false
        if let last = parts.last, parts.count > 1, last == "ro" || last == "rw" {
            writable = last == "rw"
            parts.removeLast()
        }
        guard (1...2).contains(parts.count), !parts[0].isEmpty else {
            throw policyError("cannot read mount \"\(text)\"; use HOST[:PATH][:ro|:rw]")
        }
        let host = (parts[0] as NSString).expandingTildeInPath
        return SandboxMount(host: host, path: parts.count == 2 ? parts[1] : host, writable: writable)
    }

    /// Resolves the host path and checks the guest can see it: it must exist and lie under one
    /// of dmx's shares (`dmx config get shares`), which a writable mount needs read-write.
    func resolved(shares: [Share]) throws -> SandboxMount {
        guard host.hasPrefix("/") else { throw policyError("mount source \"\(host)\" must be an absolute host path") }
        guard let real = realpath(host, nil) else {
            throw policyError("mount source \(host) does not exist on this Mac")
        }
        defer { free(real) }
        let path = String(cString: real)
        guard let share = shares.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else {
            throw DMXError("mount_not_shared", "\(path) is outside dmx's shares (\(shares.map(\.path).joined(separator: ", ")))",
                           hint: "use a directory under them, or add a share: `dmx config set shares ...` then `dmx stop`")
        }
        if writable && share.readOnly {
            throw DMXError("mount_not_shared", "\(path) is in the read-only share \(share.path)", hint: "mount it read-only, or share it read-write")
        }
        return SandboxMount(host: path, path: self.path, writable: writable)
    }
}

func policyError(_ message: String) -> DMXError {
    DMXError("bad_sandbox_policy", message, hint: "see `dmx sandbox create --help` or docs/sandbox.md")
}
