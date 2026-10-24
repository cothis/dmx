import ArgumentParser
import DMXCore
import Foundation

struct Tools: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The docker CLI, Compose and Buildx that dmx provides, so Homebrew is not needed.",
        discussion: """
            Pinned darwin-arm64 builds, checked by sha256: docker in ~/.dmx/bin (linked into ~/.local/bin \
            when that is on PATH), Compose and Buildx in ~/.dmx/cli-plugins (listed in cliPluginsExtraDirs \
            of $DOCKER_CONFIG/config.json). `dmx install` installs them too.
            """,
        subcommands: [Install.self, List.self, Uninstall.self]
    )

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download, verify and install the pinned docker CLI and plugins. Resumes an interrupted download."
        )
        @OptionGroup var global: GlobalOptions

        @MainActor
        func run() async throws {
            let quiet = global.json
            try await report(global) {
                let result = try await DockerTools.install(paths: Paths(), progress: { if !quiet { printProgress($0) } })
                return (result, describeTools(result), true)
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ls",
            abstract: "Show the pinned tools, whether they are installed, and which docker PATH finds."
        )
        @OptionGroup var global: GlobalOptions

        @MainActor
        func run() async throws {
            try await report(global) {
                let result = DockerTools.status(paths: Paths())
                return (result, describeTools(result), true)
            }
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove the tools, their links and the plugin directory from the docker config."
        )
        @OptionGroup var global: GlobalOptions

        @MainActor
        func run() async throws {
            try await report(global) {
                let paths = Paths()
                try DockerTools.uninstall(paths: paths)
                let result = DockerTools.status(paths: paths)
                return (result, "removed the docker tools from \(paths.home.path)", true)
            }
        }
    }
}

func printProgress(_ line: String) {
    FileHandle.standardError.write(Data("\(line)\n".utf8))
}

func describeTools(_ r: DockerTools.Report) -> String {
    var lines = r.tools.map { tool in
        var state = tool.state
        if tool.downloadedBytes > 0 { state += ", \(tool.downloadedBytes >> 20) MB downloaded" }
        return "\(tool.name.padding(toLength: 30, withPad: " ", startingAt: 0)) \(tool.version.padding(toLength: 8, withPad: " ", startingAt: 0)) \(tool.path) (\(state))"
    }
    for link in r.links {
        lines.append(link.state == "skipped" ? "left \(link.path) alone: it is not dmx's" : "\(link.path) -> \(link.target) (\(link.state))")
    }
    lines.append("plugins: \(r.cliPlugins) " + (r.pluginsConfigured ? "in cliPluginsExtraDirs of \(r.configDir)/config.json" : "not in \(r.configDir)/config.json"))
    lines.append("docker on PATH: " + (r.dockerOnPath.map { "\($0)\(r.dmxDockerOnPath ? " (dmx's)" : "")" } ?? "none"))
    if let hint = r.hint { lines.append("hint: \(hint)") }
    return lines.joined(separator: "\n")
}
