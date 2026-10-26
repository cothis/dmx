import ArgumentParser
import DMXCore
import Foundation

struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Replace this dmx with a published release.",
        discussion: """
            Downloads dmx-<version>-darwin-arm64.tar.gz and the sha256 published next to it,
            checks the archive, runs the binary it unpacks to see that it is that version, and
            replaces this file. The guest follows by itself: the new dmx knows the sha256 of its
            own guest and downloads it before the next boot (`dmx guest` shows that).

            A VM that is running is left alone, because its containers are. The daemon serving it
            is the old version until it exits, so this prints what to do: `dmx stop` powers the VM
            off and the daemon exits a few seconds later. With the VM already off, the idle daemon
            is asked to quit, so the next command runs the new version.

            The release_url setting (or DMX_RELEASE_URL) replaces the base URL; a mirror has no
            "latest" page, so with one set the version has to be named.
            """
    )

    @OptionGroup var global: GlobalOptions
    @Flag(help: "Only say whether a newer release exists; download nothing.") var check = false
    @Option(name: .customLong("version"), help: "Install this version instead of the newest (e.g. 0.3.0).") var wanted: String?
    @Flag(help: "Install even if that version is already here, including over a build from source.") var force = false

    @MainActor
    func run() async throws {
        let quiet = global.json
        try await report(global) {
            let updater = SelfUpdate(current: version)
            let result = check
                ? try await updater.check(version: wanted)
                : try await updater.update(version: wanted, force: force) { message in
                    if !quiet { FileHandle.standardError.write(Data("dmx: \(message)\n".utf8)) }
                }
            var text: String
            switch (result.updated, result.available) {
            case (true, _):
                text = "dmx \(result.current) → \(result.target) in \(result.path ?? "?")"
            case (false, true):
                text = check
                    ? "dmx \(result.target) is out; this is \(result.current). `dmx update` installs it."
                    : "dmx \(result.target) was not installed"
            case (false, false):
                text = result.target == result.current
                    ? "dmx \(result.current) is the newest release"
                    : "dmx \(result.current) is newer than the newest release (\(result.target))"
            }
            if let daemon = result.daemon {
                switch daemon.handover {
                case "exits_soon": text += "\n  the daemon (pid \(daemon.pid)) is idle and exits shortly; the next command runs \(result.target)"
                case "stop_to_switch": text += "\n  the VM still runs on \(daemon.version) (pid \(daemon.pid)); `dmx stop` hands it over"
                default: text += "\n  a daemon from \(daemon.version) (pid \(daemon.pid)) is running"
                }
            }
            return (result, text, true)
        }
    }
}
