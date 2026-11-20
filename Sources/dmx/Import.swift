import ArgumentParser
import DMXCore
import Foundation

struct ImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Bring images, volumes, networks and containers over from Docker Desktop, OrbStack or Colima.",
        discussion: """
            Reads the other engine through its Docker socket and changes nothing there. Images go \
            through `docker save | docker load`; each volume's data is copied with `docker cp` between \
            two containers that are created and never started; user bridge networks and containers are \
            created in dmx with their settings and labels, so Compose finds its projects. Containers are \
            created, not started: stop them in the other engine, then start them here. Whatever dmx already \
            has (a tag, a volume, a network or a container name) is left alone, so running it again picks \
            up only what is missing. Without --from, the one engine that answers at its usual socket is used.
            """
    )
    @OptionGroup var global: GlobalOptions

    @Option(help: "docker-desktop, orbstack, colima, rancher-desktop, or unix:///path/to/docker.sock.")
    var from: String?

    @Option(name: .customLong("project"), help: "Only this Compose project (repeat for more).")
    var projects: [String] = []

    @Flag(help: "List what would be imported without changing anything.")
    var dryRun = false

    @MainActor
    func run() async throws {
        let quiet = global.json
        try await report(global) {
            var options = Import.Options()
            options.from = from
            options.projects = projects
            options.dryRun = dryRun
            let result = try await Import.run(paths: Paths(), options: options, progress: { if !quiet { printProgress($0) } })
            return (result, describeImport(result), result.ok)
        }
    }
}

func describeImport(_ r: Import.Report) -> String {
    var lines = ["from \(r.source.name) (\(r.source.socket)" + (r.source.serverVersion.map { ", dockerd \($0)" } ?? "") + ")"
                 + (r.dryRun ? ", dry run: nothing changed" : "")]
    // Anonymous volumes have 64-digit names; they do not set the column for everything else.
    let width = max(12, min(40, r.items.map(\.name.count).max() ?? 0)) + 2
    for item in r.items {
        lines.append(item.kind.padding(toLength: 10, withPad: " ", startingAt: 0)
                     + item.name + String(repeating: " ", count: max(2, width - item.name.count))
                     + item.action + (item.detail.map { " (\($0))" } ?? ""))
    }
    if r.items.isEmpty { lines.append("nothing to import") }
    let counts = Dictionary(grouping: r.items, by: \.action).mapValues(\.count)
    lines.append(["planned", "imported", "exists", "skipped", "failed"].compactMap { a in counts[a].map { "\($0) \(a == "exists" ? "already in dmx" : a)" } }.joined(separator: ", "))
    for w in r.warnings { lines.append("warning: \(w)") }
    if let next = r.next { lines.append("next: \(next)") }
    return lines.joined(separator: "\n")
}
