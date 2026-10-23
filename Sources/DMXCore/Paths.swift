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
}
