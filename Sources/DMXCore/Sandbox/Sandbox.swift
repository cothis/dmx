import Foundation

/// A sandbox as `dmx sandbox ls` and the MCP tools show it.
public struct SandboxInfo: Codable, Sendable {
    public let name: String
    /// Docker's state of its container: `running`, `exited`, `created`, ...
    public let state: String
    /// The container's id (12 characters) and name in Docker.
    public let id: String
    public let container: String
    /// The image it was created from: the policy's, or a checkpoint's after a rollback or fork.
    public let image: String
    public let policy: SandboxPolicy
    /// What `allow` resolved to when the sandbox (re)started: the addresses it may reach.
    public let allowed: [String]
    public let createdAt: String
    public let expiresAt: String
    public let expiresInS: Int
    public var checkpoints: [SandboxCheckpoint]
}

public struct SandboxCheckpoint: Codable, Sendable {
    public let name: String
    /// The image holding it: `dmx-sandbox/<sandbox>:<checkpoint>`.
    public let image: String
    public let createdAt: String
    /// The image's size as dockerd reports it, base layers included, and what the sandbox had
    /// changed when it was taken (nil for a fork from a checkpoint).
    public let sizeMb: Double
    public let addedMb: Double?
    public var ms: Int? = nil
}

public struct SandboxRemoved: Codable, Sendable {
    public let name: String
    public let container: Bool
    /// Checkpoint images removed; images still used by a fork stay until the fork is removed.
    public let checkpoints: [String]
    public let reason: String
}

/// Sandboxes: Docker containers in the guest with a policy (docs/sandbox.md). Every call talks
/// to dockerd over the Docker API; egress rules are set in the guest through the daemon's exec.
/// Nothing is kept on the host: a sandbox is its container, its labels and its checkpoint images.
public struct Sandboxes: Sendable {
    let docker: DockerAPI
    /// For guest commands (egress rules, killing a timed out exec) and the shares; nil in the
    /// daemon's reaper, which only removes sandboxes.
    let paths: Paths?

    public init(paths: Paths) {
        docker = .host(paths)
        self.paths = paths
    }

    init(docker: DockerAPI) {
        self.docker = docker
        paths = nil
    }

    static let label = "io.github.cothis.dmx.sandbox"
    static let expiresLabel = "io.github.cothis.dmx.sandbox.expires"
    static let policyLabel = "io.github.cothis.dmx.sandbox.policy"
    static let allowedLabel = "io.github.cothis.dmx.sandbox.allowed"
    /// On checkpoint images: when (Unix ms, to order them) and the bytes the sandbox had changed.
    static let checkpointLabel = "io.github.cothis.dmx.checkpoint.at"
    static let addedLabel = "io.github.cothis.dmx.checkpoint.added"
    /// The bridge for sandboxes with network access. Inter-container traffic on it is off, so
    /// sandboxes cannot reach each other, and Docker isolates it from other networks.
    static let network = "dmx-sandbox"
    static let imageRepo = "dmx-sandbox/"

    static func containerName(_ name: String) -> String { "dmx-sandbox-\(name)" }

    public static func checkName(_ name: String, what: String = "sandbox") throws {
        let ok = name.count <= 40 && name.first.map { $0.isASCII && ($0.isLowercase || $0.isNumber) } == true
            && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
        guard ok else {
            throw DMXError("bad_name", "\(what) names are 1 to 40 lowercase letters, digits, '-', '_' or '.', starting with a letter or digit, not \"\(name)\"",
                           hint: "e.g. \(what == "sandbox" ? "build-1" : "before-upgrade")")
        }
    }

    // MARK: Create

    /// Creates and starts a sandbox. With no name, one is made up (`sb-` and 6 hex digits).
    public func create(name: String?, policy given: SandboxPolicy) async throws -> SandboxInfo {
        await sweep()
        let name = name ?? "sb-" + String(UInt32.random(in: 0...0xffffff), radix: 16).leftPadded(6)
        try Self.checkName(name)
        try given.validate()
        var policy = given
        policy.mounts = try policy.mounts.map { try $0.resolved(shares: try shares()) }
        if try await find(name) != nil {
            throw DMXError("sandbox_exists", "a sandbox named \(name) exists", hint: "pick another name, or `dmx sandbox rm \(name)`")
        }
        try await ensureImage(policy.image)
        let expires = Date().addingTimeInterval(TimeInterval(policy.ttlS))
        try await launch(name, container: Self.containerName(name), image: Self.imageForCreate(policy.image), policy: policy, expires: expires)
        return try await info(name)
    }

    /// Creates, starts and fences one container. On failure nothing is left behind.
    private func launch(_ name: String, container: String, image: String, policy: SandboxPolicy, expires: Date) async throws {
        let allowed = try resolveAllowlist(policy)
        if policy.network != "none" { try await ensureNetwork() }
        let left = max(Int(expires.timeIntervalSinceNow.rounded(.up)), 1)
        var labels: [String: JSONValue] = [
            Self.label: .string(name),
            Self.expiresLabel: .string(String(Int(expires.timeIntervalSince1970))),
            Self.policyLabel: .string(try JSONValue(encoding: policy).compact),
        ]
        if policy.network == "allowlist" { labels[Self.allowedLabel] = .string(allowed.joined(separator: ",")) }
        let hostConfig: [String: JSONValue] = [
            // tini as PID 1 reaps what exec'd commands leave behind and passes signals on.
            "Init": true,
            "NetworkMode": .string(policy.network == "none" ? "none" : Self.network),
            "NanoCpus": .int(Int(policy.cpus * 1e9)),
            "Memory": .int(Int(policy.memoryBytes)),
            "MemorySwap": .int(Int(policy.memoryBytes)),
            "PidsLimit": .int(policy.pids),
            // Raw and packet sockets would bypass the egress rules (AF_PACKET skips netfilter).
            "CapDrop": ["NET_RAW"],
            "SecurityOpt": ["no-new-privileges"],
            "LogConfig": ["Type": "json-file", "Config": ["max-size": "10m", "max-file": "2"]],
            "Mounts": .array(policy.mounts.map {
                ["Type": "bind", "Source": .string($0.host), "Target": .string($0.path), "ReadOnly": .bool(!$0.writable)]
            }),
        ]
        var command = policy.command ?? ["sleep", String(left)]
        // The egress rules can only be set once the container's network namespace exists, that
        // is, once it runs. `sleep` does nothing meanwhile; a command of the caller's waits for
        // the rules (the fence script leaves /dev/.dmx-fenced), so it never runs unfenced.
        if policy.network == "allowlist" && policy.command != nil {
            command = ["sh", "-c", "while [ ! -e /dev/.dmx-fenced ]; do sleep 0.05; done; exec \"$@\"", "sh"] + command
        }
        var body: [String: JSONValue] = [
            "Image": .string(image),
            // The command is the whole argv: the image's entrypoint would wrap `sleep` otherwise.
            "Entrypoint": [""],
            "Cmd": .array(command.map { .string($0) }),
            "Env": .array(policy.env.map { .string($0) }),
            "Hostname": .string(String(name.prefix(63))),
            "Labels": .object(labels),
            "HostConfig": .object(hostConfig),
        ]
        if let workdir = policy.workdir { body["WorkingDir"] = .string(workdir) }
        let created = try await docker.json("POST", "/containers/create?name=\(queryValue(container))", body: .object(body), code: "sandbox_create_failed")
        guard let id = created["Id"]?.string else { throw DMXError("sandbox_create_failed", "dockerd returned no container id") }
        do {
            try await docker.json("POST", "/containers/\(id)/start", code: "sandbox_create_failed")
            try await fence(id: id, policy: policy, allowed: allowed)
        } catch {
            _ = try? await docker.call("DELETE", "/containers/\(id)?force=1&v=1")
            throw error
        }
    }

    /// Sets the allowlist in the sandbox's own network namespace: loopback, replies and the
    /// allowed addresses; everything else is refused. Names still resolve: the sandbox asks
    /// Docker's DNS server on 127.0.0.11 (loopback), which forwards from outside the sandbox.
    /// The sandbox has no CAP_NET_ADMIN, so it cannot change the rules; they go when its
    /// namespace does.
    func fence(id: String, policy: SandboxPolicy, allowed: [String]) async throws {
        guard policy.network == "allowlist" else { return }
        let state = try await docker.json("GET", "/containers/\(id)/json", code: "sandbox_create_failed")["State"]
        guard case .int(let pid) = state?["Pid"] ?? .null, pid > 0 else {
            throw DMXError("sandbox_create_failed", "the sandbox's main process is not running", hint: "check the image and command; `dmx sandbox logs NAME`")
        }
        let result = try await guest(["sh", "-c", Self.fenceScript, "fence", String(pid)] + allowed)
        guard result.exitCode == 0 else {
            throw DMXError("sandbox_egress_failed", "could not set the egress rules: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))",
                           hint: "see `dmx exec -- tail -50 \(dockerdLog)`")
        }
    }

    /// Runs iptables from dockerd's root (it lives in Docker's tree, not the guest's) inside the
    /// sandbox's network namespace. `-P OUTPUT DROP` last, so a failure halfway leaves REJECT.
    static let fenceScript = #"""
        set -eu
        pid=$1; shift
        d=$(pidof dockerd | cut -d' ' -f1)
        [ -n "$d" ] || { echo "dockerd is not running" >&2; exit 1; }
        ipt() { nsenter -t "$pid" -n chroot "/proc/$d/root" /usr/sbin/iptables -w 5 "$@"; }
        ipt -F OUTPUT
        ipt -A OUTPUT -o lo -j ACCEPT
        ipt -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        for net in "$@"; do ipt -A OUTPUT -d "$net" -j ACCEPT; done
        ipt -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
        ipt -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
        ipt -P OUTPUT DROP
        touch "/proc/$pid/root/dev/.dmx-fenced"
        """#

    /// The allowlist as IPv4 addresses and CIDRs. Names are resolved now, on the Mac (the
    /// guest's DNS forwards to the Mac's resolver, so the answers match) and not again until the
    /// sandbox is rolled back or forked; `host.docker.internal` is the Mac as seen from containers.
    func resolveAllowlist(_ policy: SandboxPolicy) throws -> [String] {
        guard policy.network == "allowlist" else { return [] }
        var out: [String] = []
        for item in policy.allow {
            let parts = item.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard !parts[0].isEmpty else { throw policyError("bad host or CIDR \"\(item)\"") }
            if isIPv4(parts[0]) {
                if parts.count == 2 {
                    guard let bits = Int(parts[1]), (0...32).contains(bits) else { throw policyError("bad CIDR \"\(item)\"") }
                }
                out.append(item)
                continue
            }
            guard parts.count == 1 else { throw policyError("bad CIDR \"\(item)\": IPv4 only") }
            if item == "host.docker.internal" || item == "host.dmx.internal" { out.append("192.168.127.254"); continue }
            let addresses = resolveIPv4(item)
            guard !addresses.isEmpty else { throw policyError("\(item) does not resolve to an IPv4 address") }
            out += addresses
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    // MARK: Read

    /// Every sandbox, oldest first, with its checkpoints.
    public func list() async throws -> [SandboxInfo] {
        let containers = try await sandboxContainers()
        let images = try await checkpointImages(nil)
        return containers.compactMap { describe($0, images: images) }.sorted { $0.createdAt < $1.createdAt }
    }

    public func info(_ name: String) async throws -> SandboxInfo {
        try Self.checkName(name)
        guard let container = try await find(name) else { throw notFound(name) }
        return describe(container, images: try await checkpointImages(name))!
    }

    func notFound(_ name: String) -> DMXError {
        DMXError("sandbox_not_found", "no sandbox named \(name)", hint: "run `dmx sandbox ls`; it may have reached its TTL")
    }

    /// The sandbox's container from the list endpoint, which carries labels and state.
    func find(_ name: String) async throws -> JSONValue? {
        try await sandboxContainers(name).first
    }

    private func sandboxContainers(_ name: String? = nil) async throws -> [JSONValue] {
        let filter: JSONValue = ["label": [.string(name.map { "\(Self.label)=\($0)" } ?? Self.label)]]
        let list = try await docker.json("GET", "/containers/json?all=1&filters=\(queryValue(filter.compact))")
        guard case .array(let items) = list else { return [] }
        // A rollback briefly has two; the one with the plain name is the sandbox.
        return items.sorted { a, b in
            let plain = { (c: JSONValue) in c["Names"]?.firstString == "/" + Self.containerName(name ?? "") }
            return plain(a) && !plain(b)
        }
    }

    private func policy(of container: JSONValue) -> SandboxPolicy? {
        container["Labels"]?[Self.policyLabel]?.string.flatMap { try? FrameConnection.decoder.decode(SandboxPolicy.self, from: Data($0.utf8)) }
    }

    private func describe(_ c: JSONValue, images: [JSONValue]) -> SandboxInfo? {
        guard let labels = c["Labels"]?.object, let name = labels[Self.label]?.string else { return nil }
        let policy = policy(of: c) ?? SandboxPolicy()
        let expires = Int(labels[Self.expiresLabel]?.string ?? "") ?? 0
        let created = c["Created"]?.intValue ?? 0
        return SandboxInfo(
            name: name, state: c["State"]?.string ?? "unknown", id: String((c["Id"]?.string ?? "").prefix(12)),
            container: String((c["Names"]?.firstString ?? "").dropFirst()), image: c["Image"]?.string ?? "",
            policy: policy, allowed: (labels[Self.allowedLabel]?.string ?? "").split(separator: ",").map(String.init),
            createdAt: isoDate(created), expiresAt: isoDate(expires), expiresInS: max(expires - Int(Date().timeIntervalSince1970), 0),
            checkpoints: checkpoints(of: name, images: images))
    }

    // MARK: Remove

    /// Removes the sandbox's container (killing what runs in it) and its checkpoint images.
    public func remove(_ name: String, reason: String = "removed") async throws -> SandboxRemoved {
        try Self.checkName(name)
        let containers = try await sandboxContainers(name)
        for c in containers {
            guard let id = c["Id"]?.string else { continue }
            let (status, body) = try await docker.call("DELETE", "/containers/\(id)?force=1&v=1")
            guard (200..<300).contains(status) || status == 404 else {
                throw DMXError("docker_failed", "cannot remove \(name): \(String(decoding: body.prefix(300), as: UTF8.self))")
            }
        }
        var removed: [String] = []
        for image in try await checkpointImages(name) {
            for tag in image["RepoTags"]?.arrayStrings ?? [] where tag.hasPrefix(Self.imageRepo + name + ":") {
                // A fork may still run from it (409): untagging fails, the fork's tag keeps it.
                let (status, _) = try await docker.call("DELETE", "/images/\(pathValue(tag))")
                if (200..<300).contains(status) { removed.append(String(tag.split(separator: ":").last ?? "")) }
            }
        }
        if containers.isEmpty && removed.isEmpty { throw notFound(name) }
        return SandboxRemoved(name: name, container: !containers.isEmpty, checkpoints: removed.sorted(), reason: reason)
    }

    /// Removes every sandbox past its TTL; returns what went. Errors are skipped: the next
    /// sweep tries again.
    @discardableResult
    public func sweep() async -> [SandboxRemoved] {
        guard let containers = try? await sandboxContainers() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        var removed: [SandboxRemoved] = []
        var seen = Set<String>()
        for c in containers {
            guard let labels = c["Labels"]?.object, let name = labels[Self.label]?.string,
                  let expires = Int(labels[Self.expiresLabel]?.string ?? ""), expires <= now, seen.insert(name).inserted else { continue }
            if let r = try? await remove(name, reason: "ttl") { removed.append(r) }
        }
        return removed
    }

    /// Seconds until the next sandbox reaches its TTL; nil when there is none.
    func nextExpiry() async throws -> Int? {
        let now = Int(Date().timeIntervalSince1970)
        return try await sandboxContainers().compactMap { Int($0["Labels"]?[Self.expiresLabel]?.string ?? "") }.min().map { max($0 - now, 0) }
    }

    // MARK: Checkpoints

    /// Commits the sandbox's filesystem (paused meanwhile) to `dmx-sandbox/<name>:<checkpoint>`.
    /// Host-path mounts and memory are not part of it.
    public func checkpoint(_ name: String, as given: String?) async throws -> SandboxCheckpoint {
        let started = ContinuousClock.now
        let sandbox = try await info(name)
        let checkpoint = given ?? "c\((sandbox.checkpoints.compactMap { Int($0.name.dropFirst()) }.max() ?? 0) + 1)"
        try Self.checkName(checkpoint, what: "checkpoint")
        if sandbox.checkpoints.contains(where: { $0.name == checkpoint }) {
            throw DMXError("checkpoint_exists", "\(name) has a checkpoint named \(checkpoint)", hint: "pick another name, or leave it out for the next c<N>")
        }
        try await commit(sandbox.id, repo: Self.imageRepo + name, tag: checkpoint)
        var result = try await info(name).checkpoints.first { $0.name == checkpoint }
            ?? SandboxCheckpoint(name: checkpoint, image: Self.imageRepo + name + ":" + checkpoint, createdAt: isoDate(Int(Date().timeIntervalSince1970)), sizeMb: 0, addedMb: nil)
        result.ms = milliseconds(ContinuousClock.now - started)
        return result
    }

    /// Replaces the sandbox's container with a new one from a checkpoint (default: the latest),
    /// with the same policy and TTL. Processes running in it are killed.
    public func rollback(_ name: String, to given: String?) async throws -> SandboxInfo {
        let sandbox = try await info(name)
        guard let checkpoint = given.map({ c in sandbox.checkpoints.first { $0.name == c } }) ?? sandbox.checkpoints.last else {
            throw DMXError("checkpoint_not_found", given.map { "\(name) has no checkpoint named \($0)" } ?? "\(name) has no checkpoints",
                           hint: "run `dmx sandbox checkpoint \(name)` first; `dmx sandbox ls` lists them")
        }
        let expires = Date(timeIntervalSince1970: TimeInterval(isoSeconds(sandbox.expiresAt)))
        guard expires.timeIntervalSinceNow > 1 else { throw notFound(name) }
        // The new container exists before the old one goes, so the sandbox is never without one.
        let next = Self.containerName(name) + ".next"
        _ = try? await docker.call("DELETE", "/containers/\(next)?force=1&v=1")
        try await launch(name, container: next, image: checkpoint.image, policy: sandbox.policy, expires: expires)
        try await docker.json("DELETE", "/containers/\(sandbox.id)?force=1&v=1")
        try await docker.json("POST", "/containers/\(next)/rename?name=\(queryValue(Self.containerName(name)))")
        return try await info(name)
    }

    /// A new sandbox with the same policy from a checkpoint of `name`, or from its filesystem
    /// as it is now. Its TTL starts now (`ttl` overrides the length).
    public func fork(_ name: String, into given: String?, from checkpointName: String?, ttl: Int?) async throws -> SandboxInfo {
        let sandbox = try await info(name)
        let newName = given ?? "\(name.prefix(32))-f" + String(UInt16.random(in: 0...0xfff), radix: 16)
        try Self.checkName(newName)
        if try await find(newName) != nil {
            throw DMXError("sandbox_exists", "a sandbox named \(newName) exists", hint: "pick another name")
        }
        var policy = sandbox.policy
        if let ttl { policy.ttlS = ttl }
        try policy.validate()
        let expires = Date().addingTimeInterval(TimeInterval(policy.ttlS))
        let forked = Self.imageRepo + newName + ":forked"
        if let checkpointName {
            guard let checkpoint = sandbox.checkpoints.first(where: { $0.name == checkpointName }) else {
                throw DMXError("checkpoint_not_found", "\(name) has no checkpoint named \(checkpointName)", hint: "`dmx sandbox ls` lists them")
            }
            // The container first: until it exists, nothing would say the tag belongs to a sandbox.
            try await launch(newName, container: Self.containerName(newName), image: checkpoint.image, policy: policy, expires: expires)
            try await docker.json("POST", "/images/\(pathValue(checkpoint.image))/tag?repo=\(queryValue(Self.imageRepo + newName))&tag=forked")
        } else {
            try await commit(sandbox.id, repo: Self.imageRepo + newName, tag: "forked")
            do {
                try await launch(newName, container: Self.containerName(newName), image: forked, policy: policy, expires: expires)
            } catch {
                _ = try? await docker.call("DELETE", "/images/\(pathValue(forked))")
                throw error
            }
        }
        return try await info(newName)
    }

    /// Commits a container's filesystem, paused meanwhile, labelled with the time and with what
    /// it changed since its image (`SizeRw`, which is what the commit adds).
    private func commit(_ id: String, repo: String, tag: String) async throws {
        let inspect = try await docker.json("GET", "/containers/\(id)/json?size=1", code: "checkpoint_failed")
        var changes = "changes=\(queryValue("LABEL \(Self.checkpointLabel)=\(Int(Date().timeIntervalSince1970 * 1000))"))"
        if let added = inspect["SizeRw"]?.intValue { changes += "&changes=\(queryValue("LABEL \(Self.addedLabel)=\(added)"))" }
        try await docker.json("POST", "/commit?container=\(id)&repo=\(queryValue(repo))&tag=\(queryValue(tag))&pause=1&\(changes)", code: "checkpoint_failed")
    }

    /// Checkpoint images, of one sandbox or all, with their labels.
    private func checkpointImages(_ name: String?) async throws -> [JSONValue] {
        let filter: JSONValue = ["reference": [.string(Self.imageRepo + (name ?? "*"))]]
        guard case .array(let items) = try await docker.json("GET", "/images/json?filters=\(queryValue(filter.compact))") else { return [] }
        return items
    }

    private func checkpoints(of name: String, images: [JSONValue]) -> [SandboxCheckpoint] {
        let prefix = Self.imageRepo + name + ":"
        var out: [(at: Int, SandboxCheckpoint)] = []
        for image in images {
            for tag in image["RepoTags"]?.arrayStrings ?? [] where tag.hasPrefix(prefix) {
                let at = Int(image["Labels"]?[Self.checkpointLabel]?.string ?? "") ?? (image["Created"]?.intValue ?? 0) * 1000
                let added = Int(image["Labels"]?[Self.addedLabel]?.string ?? "")
                let size = image["Size"]?.intValue ?? 0
                out.append((at, SandboxCheckpoint(
                    name: String(tag.dropFirst(prefix.count)), image: tag, createdAt: isoDate(at / 1000),
                    sizeMb: mb(size), addedMb: added.map(mb))))
            }
        }
        return out.sorted { $0.at < $1.at }.map(\.1)
    }

    // MARK: Helpers

    private func shares() throws -> [Share] {
        guard let paths else { return Share.defaults }
        return try Config.load(paths).shareList
    }

    /// Pulls the image unless dockerd has it.
    private func ensureImage(_ reference: String) async throws {
        let local = Self.imageForCreate(reference)
        let (status, _) = try await docker.call("GET", "/images/\(pathValue(local))/json")
        if status == 200 { return }
        var name = reference, tag = "latest"
        if let at = reference.firstIndex(of: "@") {
            name = String(reference[..<at])
            tag = String(reference[reference.index(after: at)...])
            if let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") { name = String(name[..<colon]) }
        } else if let colon = reference.lastIndex(of: ":"), !reference[colon...].contains("/") {
            name = String(reference[..<colon])
            tag = String(reference[reference.index(after: colon)...])
        }
        // A stream of JSON progress lines; a failure is a line with "error", still under 200.
        let (code, body) = try await docker.call("POST", "/images/create?fromImage=\(queryValue(name))&tag=\(queryValue(tag))")
        let lines = body.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0)) }
        if code != 200 || lines.contains(where: { $0["error"] != nil }) {
            let message = lines.compactMap { $0["error"]?.string ?? $0["message"]?.string }.last ?? String(decoding: body.prefix(300), as: UTF8.self)
            throw DMXError("image_pull_failed", "cannot pull \(reference): \(message)", hint: "check the name and the network; `docker pull \(reference)` shows more")
        }
    }

    /// `name:tag@digest` is stored by dockerd as `name@digest`.
    static func imageForCreate(_ reference: String) -> String {
        guard let at = reference.firstIndex(of: "@") else { return reference }
        var name = reference[..<at]
        if let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") { name = name[..<colon] }
        return String(name + reference[at...])
    }

    private func ensureNetwork() async throws {
        let (status, _) = try await docker.call("GET", "/networks/\(Self.network)")
        if status == 200 { return }
        let (created, body) = try await docker.call("POST", "/networks/create", body: [
            "Name": .string(Self.network), "Driver": "bridge",
            "Options": ["com.docker.network.bridge.enable_icc": "false"],
            "Labels": .object([Self.label: "network"]),
        ])
        // 409: another client created it meanwhile.
        guard (200..<300).contains(created) || created == 409 else {
            throw DMXError("sandbox_create_failed", "cannot create the \(Self.network) network: \(String(decoding: body.prefix(300), as: UTF8.self))")
        }
    }

    /// Runs a command in the guest (not in a sandbox) through the daemon.
    func guest(_ argv: [String]) async throws -> CappedExecResult {
        guard let paths else { throw DMXError("internal", "no daemon to run \(argv[0]) through") }
        return try await execCapped(paths: paths, argv: argv, stdin: nil, env: [], cwd: nil, timeout: .seconds(60), maxOutputBytes: 8192)
    }
}

extension JSONValue {
    var intValue: Int? {
        switch self {
        case .int(let n): n
        case .double(let n): Int(exactly: n)
        default: nil
        }
    }

    var arrayStrings: [String] {
        if case .array(let items) = self { return items.compactMap(\.string) }
        return []
    }

    var firstString: String? { arrayStrings.first }
}

extension String {
    func leftPadded(_ width: Int) -> String { String(repeating: "0", count: max(width - count, 0)) + self }
}

func isoDate(_ unix: Int) -> String {
    let f = ISO8601DateFormatter()
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
}

func isoSeconds(_ iso: String) -> Int {
    Int(ISO8601DateFormatter().date(from: iso)?.timeIntervalSince1970 ?? 0)
}

private func mb(_ bytes: Int) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }

func isIPv4(_ s: String) -> Bool {
    var addr = in_addr()
    return inet_pton(AF_INET, s, &addr) == 1
}

/// The IPv4 addresses a name resolves to on this Mac.
func resolveIPv4(_ host: String) -> [String] {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0 else { return [] }
    defer { freeaddrinfo(result) }
    var out: [String] = []
    var p = result
    while let info = p {
        if let sa = info.pointee.ai_addr, info.pointee.ai_family == AF_INET {
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
            let s = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if !out.contains(s) { out.append(s) }
        }
        p = info.pointee.ai_next
    }
    return out
}

/// Percent-encodes what may not appear in a URL path segment, keeping `/`, `:` and `@` of
/// image references.
func pathValue(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~/:@")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}
