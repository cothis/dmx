import Foundation

/// The protocol version of the control socket; see docs/daemon-protocol.md.
public let daemonProtocol = 1

public struct DaemonHello: Codable, Sendable {
    public let version: String
    public let `protocol`: Int
    public let pid: Int32
    /// Additive capability: old daemons do not publish lifecycle receipts.
    public var activityNotifications: Bool? = nil
    public var menuControl: Bool? = nil
}

public struct MenuDaemonState: Codable, Sendable {
    public let pid: Int32
    public let state: String
}

/// What `dmx status` shows. VM fields are nil while the VM is stopped.
public struct DaemonStatus: Codable, Sendable {
    /// `stopped`, `starting`, `running` or `stopping`; `not_running` when no daemon answered.
    public let state: String
    /// The daemon's process id, which is also the process the VM's memory is charged to.
    public let pid: Int32?
    public let version: String?
    /// True when launchd owns the socket (`dmx install`), false when the CLI started the daemon.
    public let launchd: Bool?
    public let uptimeS: Double?
    public let cpus: Int?
    public let maxMemory: String?
    /// Guest memory in use (see `GuestMemory.used`), in MiB.
    public let guestUsedMb: Int?
    /// Host memory charged to the daemon, guest RAM included (`ri_phys_footprint`), in MiB.
    public let hostFootprintMb: Int?
    public let hostPeakFootprintMb: Int?
    /// Connections to the daemon other than the one asking, exec sessions included.
    public let clients: Int?
    public let execs: Int?
    /// Running Docker containers; nil until a Docker client has used the VM since it booted.
    /// While any runs, the VM does not stop for being idle.
    public let containers: Int?
    public let idleTimeoutS: Int
    /// Seconds until the VM stops for being idle, when nothing is using it.
    public let idleStopInS: Int?
    public let socket: String
    public let consoleLog: String
    /// The memory controller: host pressure, balloon, trims (see MemoryController). nil when no daemon answered.
    public var memory: MemoryStatus? = nil
    /// The data disk image on the host; nil until the first boot creates it.
    public var disk: DiskUsage? = nil
    /// The Docker API socket (`DOCKER_HOST=unix://...`, or the `dmx` docker context).
    public var dockerSocket: String? = nil

    public static func notRunning(_ paths: Paths, config: Config) -> DaemonStatus {
        DaemonStatus(state: "not_running", pid: nil, version: nil, launchd: nil, uptimeS: nil, cpus: nil,
                     maxMemory: nil, guestUsedMb: nil, hostFootprintMb: nil, hostPeakFootprintMb: nil,
                     clients: nil, execs: nil, containers: nil, idleTimeoutS: config.idleTimeoutSeconds,
                     idleStopInS: nil, socket: paths.controlSocket.path, consoleLog: paths.consoleLog.path,
                     disk: DataDisk.usage(paths.dataDisk))
    }
}

/// A request on the control socket. Params are decoded per method.
struct DaemonRequest: Decodable {
    let id: UInt64
    let method: String
}

struct DaemonParams<P: Decodable>: Decodable {
    let params: P
}

struct DaemonReply<R: Encodable>: Encodable {
    let id: UInt64
    let ok = true
    let result: R
}

struct DaemonFailure: Encodable {
    let id: UInt64
    let ok = false
    let error: DMXError
}

struct NoParams: Codable, Sendable {}

struct ExecStarted: Codable, Sendable {
    let pid: Int
}
