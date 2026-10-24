import ArgumentParser
import DMXCore
import Foundation

struct Port: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Forward host TCP and UDP ports to ports in the VM.",
        discussion: """
            Forwards are kept in ~/.dmx/ports.json and stay until removed, across daemon restarts.
            The daemon keeps listening while the VM is stopped and boots it on the first connection;
            an open forwarded connection keeps the VM from stopping for being idle.
            """,
        subcommands: [Add.self, Remove.self, List.self]
    )

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Forward a host port to a guest port.",
            discussion: "Listens on 127.0.0.1 unless HOST_IP is given (0.0.0.0 lets other machines in). Examples: dmx port add 8080:80, dmx port add 5353:53/udp"
        )
        @OptionGroup var global: GlobalOptions
        @Argument(help: "[HOST_IP:]HOST_PORT[:GUEST_PORT][/udp]; the guest port defaults to the host port.") var spec: String

        @MainActor
        func run() async throws {
            try await report(global) {
                let forward = try PortForward(parsing: spec)
                let status = try await withDaemon { try await $0.addPort(forward) }
                return (status, "forwarding \(describe(status))", true)
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Stop forwarding a host port. Open connections stay until they close."
        )
        @OptionGroup var global: GlobalOptions
        @Argument(help: "[HOST_IP:]HOST_PORT") var spec: String

        @MainActor
        func run() async throws {
            try await report(global) {
                // A protocol suffix is ignored: every forward on the port goes.
                let parts = spec.split(separator: "/", omittingEmptySubsequences: false)[0]
                    .split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                guard (1...2).contains(parts.count), let port = Int(parts.last!) else {
                    throw DMXError("bad_port_spec", "cannot read \"\(spec)\" as [HOST_IP:]HOST_PORT", hint: "run `dmx port ls` to see the forwards")
                }
                let address = parts.count == 2 ? parts[0] : nil
                let removed = try await withDaemon { try await $0.removePort(hostPort: port, hostAddress: address) }
                return (PortListReport(forwards: removed), removed.map { "removed \(describe($0))" }.joined(separator: "\n"), true)
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ls", abstract: "Show the forwarded ports.")
        @OptionGroup var global: GlobalOptions

        @MainActor
        func run() async throws {
            try await report(global) {
                let forwards = try await withDaemon { try await $0.ports() }
                let text = forwards.isEmpty ? "no ports forwarded" : forwards.map(describe).joined(separator: "\n")
                return (PortListReport(forwards: forwards), text, true)
            }
        }
    }
}

struct PortListReport: Encodable {
    let ok = true
    let forwards: [PortForwardStatus]
}

/// Runs a call on the daemon, starting it if needed (the VM stays stopped). A daemon with nothing
/// forwarded exits again shortly after.
@MainActor
private func withDaemon<T>(_ body: (DaemonClient) async throws -> T) async throws -> T {
    let client = try await DaemonClient.connect(paths: Paths(), start: true)!
    defer { client.close() }
    return try await body(client)
}

private func describe(_ f: PortForwardStatus) -> String {
    let proto = f.proto == "tcp" ? "" : "/\(f.proto)"
    var line = "\(f.hostAddress):\(f.hostPort)\(proto) -> guest \(f.guestPort)\(proto)" + (f.source.map { " (\($0))" } ?? "")
    if !f.listening { line += " (not listening: \(f.error ?? "unknown"))" }
    if f.connections > 0 { line += ", \(f.connections) open" }
    return line
}
