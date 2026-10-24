import Foundation

/// Where dmx keeps its state. `DMX_HOME` overrides the default `~/.dmx`.
public struct Paths: Sendable {
    public let home: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let custom = environment["DMX_HOME"], !custom.isEmpty {
            home = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".dmx", isDirectory: true)
        }
    }

    public var guest: URL { home.appendingPathComponent("guest", isDirectory: true) }
    public var kernel: URL { guest.appendingPathComponent("Image") }
    public var initramfs: URL { guest.appendingPathComponent("initramfs.gz") }
    public var manifest: URL { guest.appendingPathComponent("manifest.json") }

    /// The daemon's control socket. Clients connect here; with `dmx install`, launchd owns it
    /// and starts the daemon on the first connection.
    public var controlSocket: URL { home.appendingPathComponent("dmx.sock") }
    public var config: URL { home.appendingPathComponent("config.json") }
    public var logs: URL { home.appendingPathComponent("logs", isDirectory: true) }
    public var daemonLog: URL { logs.appendingPathComponent("daemon.log") }
    /// The guest console of the VM the daemon runs, rewritten on every boot.
    public var consoleLog: URL { logs.appendingPathComponent("console.log") }
}
