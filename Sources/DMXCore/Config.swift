import Foundation

/// Settings in `~/.dmx/config.json`. Absent keys take their defaults; the daemon reads the file
/// each time it boots the VM, so changes apply from the next boot.
public struct Config: Codable, Sendable, Equatable {
    /// Virtual CPUs; default all host cores (idle ones cost nothing).
    public var cpus: Int?
    /// Memory ceiling as written by the user, e.g. "8G"; default half the Mac's memory, at most 8G.
    public var memory: String?
    /// Seconds without clients before the VM stops; default 300.
    public var idleTimeout: Int?
    /// Size of the data disk when it is created, e.g. "64G": a ceiling, the image is sparse.
    public var diskSize: String?

    public static let defaultIdleTimeout = 300
    public static let defaultDiskSize: UInt64 = 64 << 30
    public static let keys = ["cpus", "memory", "idle_timeout", "disk_size"]

    public init() {}

    public static func load(_ paths: Paths) throws -> Config {
        guard let data = try? Data(contentsOf: paths.config) else { return Config() }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Config.self, from: data)
        } catch {
            throw DMXError("bad_config", "cannot read \(paths.config.path): \(error)", hint: "fix or delete the file, or run `dmx config unset <key>`")
        }
    }

    public func save(_ paths: Paths) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try (encoder.encode(self) + Data("\n".utf8)).write(to: paths.config, options: .atomic)
    }

    public var spec: MachineSpec {
        get throws { MachineSpec(cpus: cpus, maxMemory: try memory.map(parseSize)) }
    }

    public var idleTimeoutSeconds: Int { idleTimeout ?? Self.defaultIdleTimeout }

    public var diskSizeBytes: UInt64 {
        get throws { try diskSize.map(parseSize) ?? Self.defaultDiskSize }
    }

    /// Every key with the value in effect: the configured one, or the default.
    public var effective: [String: String] {
        let spec = MachineSpec(cpus: cpus, maxMemory: try? memory.map(parseSize))
        return [
            "cpus": String(spec.cpus),
            "memory": memory ?? formatSize(spec.maxMemory),
            "idle_timeout": formatDuration(idleTimeoutSeconds),
            "disk_size": diskSize ?? formatSize(Self.defaultDiskSize),
        ]
    }

    /// Sets a key from its text form, or resets it to the default when `value` is nil.
    public mutating func set(_ key: String, _ value: String?) throws {
        switch key {
        case "cpus":
            guard let value else { cpus = nil; return }
            guard let n = Int(value), n >= 1 else {
                throw DMXError("bad_config_value", "cpus must be a whole number of at least 1, not \"\(value)\"")
            }
            cpus = n
        case "memory":
            guard let value else { memory = nil; return }
            let bytes = try parseSize(value)
            guard bytes >= 512 << 20 else {
                throw DMXError("bad_config_value", "memory must be at least 512M, not \"\(value)\"")
            }
            memory = value.uppercased()
        case "idle_timeout":
            guard let value else { idleTimeout = nil; return }
            idleTimeout = try parseDuration(value)
        case "disk_size":
            // Applies when the image is created; an existing data.img keeps its size.
            guard let value else { diskSize = nil; return }
            guard try parseSize(value) >= 1 << 30 else {
                throw DMXError("bad_config_value", "disk_size must be at least 1G, not \"\(value)\"")
            }
            diskSize = value.uppercased()
        default:
            throw DMXError("unknown_config_key", "no setting named \"\(key)\"", hint: "settings are \(Self.keys.joined(separator: ", ")); run `dmx config get`")
        }
    }
}

/// Parses `90`, `90s`, `5m` or `1h` into seconds.
public func parseDuration(_ text: String) throws -> Int {
    let units: [Character: Int] = ["s": 1, "m": 60, "h": 3600]
    var digits = text.lowercased()
    var scale = 1
    if let last = digits.last, let unit = units[last] {
        scale = unit
        digits.removeLast()
    }
    guard let value = Int(digits), value > 0, value <= 7 * 86400 / scale else {
        throw DMXError("bad_duration", "cannot parse duration \"\(text)\"", hint: "use seconds, or a number with s, m or h, e.g. 5m")
    }
    return value * scale
}

/// The shortest exact form `parseDuration` reads back: `90s`, `5m`, `1h`.
public func formatDuration(_ seconds: Int) -> String {
    if seconds > 0 && seconds % 3600 == 0 { return "\(seconds / 3600)h" }
    if seconds > 0 && seconds % 60 == 0 { return "\(seconds / 60)m" }
    return "\(seconds)s"
}

/// A span for people: `12s`, `4m59s`, `2h5m`.
public func formatElapsed(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m\(seconds % 60 == 0 ? "" : "\(seconds % 60)s")" }
    return "\(seconds / 3600)h\(seconds % 3600 / 60 == 0 ? "" : "\(seconds % 3600 / 60)m")"
}
