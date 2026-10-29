import ArgumentParser
import DMXCore
import Foundation

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "app", abstract: "Install the native menu app and its CLI together.", subcommands: [Install.self])

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Verify and install a complete dmx.app. Never starts the engine.")
        @OptionGroup var global: GlobalOptions
        @Option(help: "A release tar.gz containing dmx.app.") var archive: String?
        @Option(help: "A built and signed dmx.app instead of an archive.") var bundle: String?
        @Option(help: "Destination .app (default ~/Applications/dmx.app).") var directory: String?
        @Option(help: "Create a dmx CLI link in this directory.") var binDir: String?
        @Flag(help: "Allow a source CLI to replace a Developer ID app with source signing. Download verification still applies.")
        var allowSigningChange = false

        @MainActor func run() async throws {
            try await report(global) {
                let url: (String) -> URL = { URL(fileURLWithPath: $0).standardizedFileURL }
                let result = try AppInstallation.install(archive: archive.map(url), bundle: bundle.map(url),
                                                         destination: directory.map(url) ?? AppInstallation.defaultDestination,
                                                         binDirectory: binDir.map(url), allowSigningChange: allowSigningChange)
                return (result, "installed dmx \(result.version) at \(result.app)" + (result.cli.map { "\nCLI: \($0)" } ?? ""), true)
            }
        }
    }
}
