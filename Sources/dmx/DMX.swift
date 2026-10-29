import ArgumentParser
import DMXCore
import Foundation

/// The literal lives in DMXCore (`dmxVersion`), where the daemon and its client compare it.
let version = dmxVersion

struct GlobalOptions: ParsableArguments {
    @Flag(help: "Print one JSON object on stdout instead of text.")
    var json = false
}

/// Prints a result as JSON or text, and turns DMXError into a non-zero exit.
@MainActor
func report<T: Encodable>(_ global: GlobalOptions, _ body: () async throws -> (T, String, Bool)) async throws {
    do {
        let (value, text, ok) = try await body()
        if global.json { printJSON(value) } else { print(text) }
        if !ok { throw ExitCode(1) }
    } catch let error as DMXError {
        if global.json {
            printJSON(ErrorEnvelope(error: error))
        } else {
            FileHandle.standardError.write(Data("error: \(error.message)\n".utf8))
            if let hint = error.hint { FileHandle.standardError.write(Data("hint: \(hint)\n".utf8)) }
        }
        throw ExitCode(1)
    }
}

struct ErrorEnvelope: Encodable {
    let ok = false
    let error: DMXError
}

func printJSON(_ value: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = (try? encoder.encode(value)) ?? Data("{\"ok\":false}".utf8)
    print(String(decoding: data, as: UTF8.self))
}

@main
struct DMX: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dmx",
        abstract: "A container engine for macOS that stays out of your memory.",
        version: version,
        subcommands: [Doctor.self, Status.self, Start.self, Stop.self, Exec.self, Shell.self, Port.self,
                      ConfigCommand.self, SandboxCommand.self, GuestCommand.self, Install.self, Uninstall.self, Tools.self, AppCommand.self, Update.self, Daemon.self, MCP.self, Boot.self]
    )
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check that this Mac can run the dmx VM.")

    @OptionGroup var global: GlobalOptions

    @MainActor
    func run() async throws {
        try await report(global) {
            let paths = Paths()
            // A daemon that speaks another protocol throws rather than answering; doctor is where
            // that belongs, so keep the error instead of dropping the check.
            var client: DaemonClient?
            var daemonError: DMXError?
            do {
                client = try await DaemonClient.connect(paths: paths, start: false)
            } catch let error as DMXError {
                daemonError = error
            }
            defer { client?.close() }
            let result = runDoctor(paths: paths, daemon: client.map { ($0.hello.version, $0.hello.pid) },
                                   daemonError: daemonError)
            let text = result.checks.map { check in
                var line = "\(check.ok ? "ok  " : "FAIL") \(check.name): \(check.detail)"
                if let hint = check.hint { line += "\n     hint: \(hint)" }
                return line
            }.joined(separator: "\n")
            return (result, text, result.ok)
        }
    }
}

struct Boot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Boot the VM in the foreground with its console attached (debugging).",
        discussion: """
            Press Ctrl-] to power off. With --selftest the guest reports on itself and exits.
            With a command after --, runs it in the guest through the agent instead of a console,
            with stdin, stdout and stderr attached, then powers off and exits with its status.
            Its output passes through untouched; --json changes only how dmx's own errors print.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: "Virtual CPUs (default: all host cores; idle ones cost nothing).")
    var cpus: Int?

    @Option(help: "Memory ceiling, e.g. 8G. Only touched pages use host memory.")
    var memory: String?

    @Option(help: "Guest RAM at boot, e.g. 1G; the rest of --memory is plugged as needed (default 1G). For experiments.")
    var bootMemory: String?

    @Flag(help: "Boot, exercise the guest agent over vsock, and power off through it.")
    var selftest = false

    @Option(help: "Seconds before --selftest gives up.")
    var timeout = 30

    @Flag(help: "Show kernel boot messages.")
    var verbose = false

    @Option(name: .customLong("kernel-arg"), help: "Extra kernel command line argument (repeatable), for experiments.")
    var kernelArgs: [String] = []

    @Option(name: .customLong("share"), help: "Host directory to share at the same path (repeatable; path:ro for read-only). The daemon uses `dmx config set shares` instead.")
    var shares: [String] = []

    @Argument(parsing: .postTerminator, help: "Command to run in the guest, after --.")
    var command: [String] = []

    @MainActor
    func run() async throws {
        var spec = MachineSpec(cpus: cpus, maxMemory: try memory.map(parseSize), kernelArgs: kernelArgs,
                               shares: try Share.parseList(shares.joined(separator: ",")))
        spec.bootMemory = try bootMemory.map(parseSize)
        do {
            let quiet = global.json
            try await GuestStore(paths: Paths()).ensure { message in
                if !quiet { FileHandle.standardError.write(Data("dmx: \(message)\n".utf8)) }
            }
        } catch let error as DMXError {
            try await report(global) { () -> (Bool, String, Bool) in throw error }
            return
        }
        if !command.isEmpty {
            let status: Int32
            do {
                status = try await runInGuest(paths: Paths(), spec: spec, argv: command, timeout: .seconds(timeout), echo: verbose)
            } catch let error as DMXError {
                try await report(global) { () -> (Bool, String, Bool) in throw error }
                return
            }
            throw ExitCode(status)
        }
        if selftest {
            try await report(global) {
                let result = try await runSelftest(paths: Paths(), spec: spec, timeout: .seconds(timeout), echo: verbose)
                var text = result.ok ? "selftest ok" : "selftest FAILED"
                if let ms = result.bootMs { text += " (agent up in \(ms) ms)" }
                if let agent = result.agent { text += "\n  agent: \(agent.agent) \(agent.version), protocol \(agent.protocol)" }
                if let uname = result.uname { text += "\n  uname: \(uname)" }
                if let used = result.guestUsedMb { text += "\n  guest used: \(used) MB of \(result.maxMemory)" }
                if let host = result.host { text += "\n  host footprint: \(host.footprintMb) MB (peak \(host.peakFootprintMb) MB, pid \(host.pid))" }
                if let r = result.reclaim {
                    text += "\n  reclaim: 1 GB freed in the guest, \(r.afterFreeMb) -> \(r.afterReclaimMb) MB" + (r.returnedMs.map { " in \($0) ms" } ?? ", not within 10 s")
                }
                if let d = result.disk {
                    text += "\n  disk: 128 MB written in \(d.writeMs) ms and deleted, host file \(d.allocatedAfterWriteMb) -> \(d.allocatedAfterDeleteMb) MB" + (d.returnedMs.map { " in \($0) ms" } ?? ", not within 10 s")
                }
                if let ms = result.shutdownMs { text += "\n  shutdown: \(ms) ms" }
                for check in result.checks { text += "\n  \(check.ok ? "ok  " : "FAIL") \(check.name): \(check.detail)" }
                for problem in result.problems { text += "\n  problem: \(problem)" }
                return (result, text, result.ok)
            }
            return
        }
        try await interactive(spec)
    }

    @MainActor
    private func interactive(_ base: MachineSpec) async throws {
        var spec = base
        if !verbose { spec.kernelArgs.append("quiet") }
        let machine: Machine
        do {
            machine = try Machine(spec: spec, paths: Paths(), console: .standardOutput)
            let terminal = RawTerminal()
            defer { terminal?.restore() }
            FileHandle.standardError.write(Data("dmx: booting (\(machine.spec.cpus) cpus, \(formatSize(machine.spec.maxMemory)) max). Ctrl-] powers off.\r\n".utf8))
            try machine.start()
            forwardStdin({ machine.input(Array($0)) }) {
                Task { await machine.stop() }
            }
            let exit = await machine.waitUntilStopped()
            terminal?.restore()
            if case .failed(let error) = exit { throw error }
        } catch let error as DMXError {
            try await report(global) { () -> (Bool, String, Bool) in throw error }
        }
    }
}
