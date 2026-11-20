import ArgumentParser
import DMXCore
import Foundation

struct NamesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "names",
        abstract: "Reach running containers at http(s)://<container>.dmx.local and <service>.<project>.dmx.local.",
        discussion: """
            After `dmx names setup`, each running container answers at http://<name>.dmx.local and \
            https://<name>.dmx.local, and each Compose service at <service>.<project>.dmx.local, without \
            publishing a port. Connections go to the container's port 80, else the first of 8080, 3000, \
            8000, 5000 it exposes, else its lowest; the label dmx.http-port=<port> picks another. A \
            container that publishes host port 80 or 443 itself takes that port over while it runs.
            """,
        subcommands: [List.self, Setup.self, Remove.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ls", abstract: "Show the names and whether local names are set up.")
        @OptionGroup var global: GlobalOptions

        @MainActor
        func run() async throws {
            try await report(global) {
                let r = try await LocalNames.status(paths: Paths())
                return (r, describeNames(r), true)
            }
        }
    }

    struct Setup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Turn local names on: make the CA, trust it for this user and write /etc/resolver/dmx.local.",
            discussion: """
                macOS shows two dialogs: your password to trust the CA (it can sign names under \
                dmx.local and nothing else) and an administrator's password for the resolver file. \
                Running it again changes only what is missing.
                """
        )
        @OptionGroup var global: GlobalOptions
        @Option(help: "UDP port on 127.0.0.1 for the names' DNS (default 53530).") var dnsPort: Int?
        @Option(help: "HTTP port (default 80).") var httpPort: Int?
        @Option(help: "HTTPS port (default 443).") var httpsPort: Int?
        @Flag(help: "Leave macOS alone: no trust change, no resolver file (for tests; use curl --resolve and ~/.dmx/names/ca.pem).")
        var noSystem = false

        @MainActor
        func run() async throws {
            let quiet = global.json
            try await report(global) {
                var options = LocalNames.SetupOptions()
                options.dnsPort = dnsPort
                options.httpPort = httpPort
                options.httpsPort = httpsPort
                options.system = !noSystem
                let r = try await LocalNames.setup(paths: Paths(), options: options, progress: { if !quiet { printProgress($0) } })
                return (r, describeNames(r), r.ok)
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Turn local names off and undo setup: the CA's trust, the resolver file and ~/.dmx/names."
        )
        @OptionGroup var global: GlobalOptions

        @MainActor
        func run() async throws {
            let quiet = global.json
            try await report(global) {
                let r = try await LocalNames.remove(paths: Paths(), progress: { if !quiet { printProgress($0) } })
                return (r, describeNames(r), r.ok)
            }
        }
    }
}

func describeNames(_ r: LocalNames.Report) -> String {
    var lines = r.changes
    guard r.enabled, let s = r.settings else {
        lines.append("local names are off")
        if let next = r.next { lines.append("next: \(next)") }
        return lines.joined(separator: "\n")
    }
    lines.append("local names: dns 127.0.0.1:\(s.dnsPort), http \(s.httpPort), https \(s.httpsPort)"
                 + (s.system ? "; CA \(r.trusted ? "trusted" : "NOT trusted"), \(LocalNames.resolverFile) \(r.resolver)" : "; macOS left alone (--no-system)"))
    if let d = r.daemon {
        for (name, state) in d.listeners.sorted(by: { $0.key < $1.key }) where state != "listening" { lines.append("\(name): \(state)") }
        if d.names.isEmpty { lines.append("no running containers") }
        let width = max(20, d.names.map(\.name.count).max() ?? 0) + 2
        for e in d.names {
            lines.append(e.name + String(repeating: " ", count: width - e.name.count) + "\(e.container) \(e.address):\(e.port)")
        }
    } else {
        lines.append("the daemon is not running: no containers")
    }
    if let next = r.next { lines.append("next: \(next)") }
    return lines.joined(separator: "\n")
}
