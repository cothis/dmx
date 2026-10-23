import ArgumentParser
import DMXCore
import Foundation

let version = "0.0.1"

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
        subcommands: [Doctor.self, Boot.self]
    )
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check that this Mac can run the dmx VM.")

    @OptionGroup var global: GlobalOptions

    @MainActor
    func run() async throws {
        try await report(global) {
            let result = runDoctor(paths: Paths())
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
        discussion: "Press Ctrl-] to power off. With --selftest the guest reports on itself and exits."
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: "Virtual CPUs (default: all host cores; idle ones cost nothing).")
    var cpus: Int?

    @Option(help: "Memory ceiling, e.g. 8G. Only touched pages use host memory.")
    var memory: String?

    @Flag(help: "Boot, exercise the guest agent over vsock, and power off through it.")
    var selftest = false

    @Option(help: "Seconds before --selftest gives up.")
    var timeout = 30

    @Flag(help: "Show kernel boot messages.")
    var verbose = false

    @MainActor
    func run() async throws {
        let spec = MachineSpec(cpus: cpus, maxMemory: try memory.map(parseSize))
        if selftest {
            try await report(global) {
                let result = try await runSelftest(paths: Paths(), spec: spec, timeout: .seconds(timeout), echo: verbose)
                var text = result.ok ? "selftest ok" : "selftest FAILED"
                if let ms = result.bootMs { text += " (agent up in \(ms) ms)" }
                if let agent = result.agent { text += "\n  agent: \(agent.agent) \(agent.version), protocol \(agent.protocol)" }
                if let uname = result.uname { text += "\n  uname: \(uname)" }
                if let used = result.guestUsedMb { text += "\n  guest used: \(used) MB of \(result.maxMemory)" }
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
        let console = Console(fromGuest: .standardOutput)
        let machine: Machine
        do {
            machine = try Machine(spec: spec, paths: Paths(), console: console)
        } catch let error as DMXError {
            try await report(global) { () -> (Bool, String, Bool) in throw error }
            return
        }

        let terminal = RawTerminal()
        defer { terminal?.restore() }
        FileHandle.standardError.write(Data("dmx: booting (\(machine.spec.cpus) cpus, \(formatSize(machine.spec.maxMemory)) max). Ctrl-] powers off.\r\n".utf8))
        try await machine.start()
        forwardStdin(to: console.toGuest) {
            Task { @MainActor in await machine.stop() }
        }
        if case .failed(let error) = await machine.waitUntilStopped() {
            terminal?.restore()
            try await report(global) { () -> (Bool, String, Bool) in throw error }
        }
    }
}
