import ArgumentParser
import DMXCore
import Foundation

struct SandboxCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sandbox",
        abstract: "Disposable environments with a policy, for AI agents and experiments.",
        discussion: """
            A sandbox is a container in the VM with no network, no host files and a TTL unless
            granted more. It keeps the VM up until its TTL, when the daemon removes it.
            See docs/sandbox.md.
            """,
        subcommands: [Create.self, List.self, Exec.self, Remove.self, Checkpoint.self, Rollback.self, Fork.self, Logs.self]
    )

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create and start a sandbox.",
            discussion: """
                Examples:
                  dmx sandbox create build --mount ~/src/app:/app --network registry.npmjs.org
                  dmx sandbox create web --network all --ttl 2h --memory 2G
                """
        )
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Name (default sb-<random>).") var name: String?
        @Option(help: "Image (default \(SandboxPolicy.defaultImage)).") var image: String?
        @Option(help: "none (default), all, or comma separated hosts, IPv4 addresses and CIDRs to allow (DNS is allowed then).") var network: String?
        @Option(name: .customLong("mount"), help: "HOST[:PATH][:rw] (repeatable). Read-only unless :rw; must be under dmx's shares.") var mounts: [String] = []
        @Option(help: "CPUs (default \(SandboxPolicy.defaultCpus)).") var cpus: Double?
        @Option(help: "Memory limit (default \(SandboxPolicy.defaultMemory)).") var memory: String?
        @Option(help: "Process limit (default \(SandboxPolicy.defaultPids)).") var pids: Int?
        @Option(help: "Lifetime, e.g. 90s, 30m, 2h (default \(formatDuration(SandboxPolicy.defaultTTL)), at most \(formatDuration(SandboxPolicy.maxTTL))).") var ttl: String?
        @Option(name: .shortAndLong, help: "Environment variable KEY=VALUE (repeatable).") var env: [String] = []
        @Option(name: .shortAndLong, help: "Default working directory.") var workdir: String?
        @Argument(parsing: .postTerminator, help: "Main process instead of sleep, after --.") var command: [String] = []

        @MainActor
        func run() async throws {
            try await report(global) {
                var policy = SandboxPolicy()
                if let image { policy.image = image }
                if let network { try policy.setNetwork(network) }
                policy.mounts = try mounts.map(SandboxMount.parse)
                if let cpus { policy.cpus = cpus }
                if let memory { policy.memory = memory }
                if let pids { policy.pids = pids }
                if let ttl { policy.ttlS = try parseDuration(ttl) }
                policy.env = env
                policy.workdir = workdir
                if !command.isEmpty { policy.command = command }
                let sandbox = try await Sandboxes(paths: Paths()).create(name: name, policy: policy)
                return (sandbox, describe(sandbox), true)
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ls", abstract: "List sandboxes (those past their TTL are removed first).")
        @OptionGroup var global: GlobalOptions

        @MainActor
        func run() async throws {
            try await report(global) {
                let sandboxes = Sandboxes(paths: Paths())
                await sandboxes.sweep()
                let list = try await sandboxes.list()
                let text = list.isEmpty ? "no sandboxes" : list.map(describe).joined(separator: "\n")
                return (SandboxListReport(sandboxes: list), text, true)
            }
        }
    }

    struct Exec: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a command in a sandbox.",
            discussion: """
                Output passes through and dmx exits with the command's status. With --json, the
                output is collected and capped like the MCP tool's (head and tail per stream).
                Example: dmx sandbox exec build -- sh -c 'cd /app && make'
                """
        )
        @OptionGroup var global: GlobalOptions
        @Flag(name: .shortAndLong, help: "Pass stdin to the command (read to its end first).") var interactive = false
        @Option(name: .shortAndLong, help: "Environment variable KEY=VALUE (repeatable).") var env: [String] = []
        @Option(name: .shortAndLong, help: "Working directory in the sandbox.") var workdir: String?
        @Option(help: "Seconds before the command is killed (default: none; 120 with --json).") var timeout: Double?
        @Option(help: "With --json, bytes kept per stream.") var maxOutputBytes = 8192
        @Argument(help: "Sandbox name.") var name: String
        @Argument(parsing: .postTerminator, help: "The command and its arguments, after --.") var command: [String] = []

        @MainActor
        func run() async throws {
            let sandboxes = Sandboxes(paths: Paths())
            let stdin = interactive ? FileHandle.standardInput.readDataToEndOfFile() : nil
            if global.json {
                try await report(global) {
                    let result = try await sandboxes.exec(name, argv: command, stdin: stdin, env: env, cwd: workdir,
                                                          timeout: .milliseconds(Int((timeout ?? 120) * 1000)), maxOutputBytes: maxOutputBytes)
                    return (result, "", true)
                }
                return
            }
            let task = Task {
                try await sandboxes.run(name, argv: command, stdin: stdin, env: env, cwd: workdir,
                                        timeout: timeout.map { .milliseconds(Int($0 * 1000)) }) { stream, data in
                    (stream == 2 ? FileHandle.standardError : FileHandle.standardOutput).write(data)
                }
            }
            // Ctrl-C kills the command in the sandbox, not only dmx.
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            source.setEventHandler { task.cancel() }
            source.resume()
            defer { source.cancel() }
            do {
                let (code, timedOut) = try await task.value
                if timedOut { FileHandle.standardError.write(Data("dmx: timed out after \(timeout ?? 0) s; killed\n".utf8)) }
                throw ExitCode(code ?? 137)
            } catch let error as DMXError {
                try await report(global) { () -> (Bool, String, Bool) in throw error }
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove sandboxes now, with their checkpoints.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Sandbox names.") var names: [String]

        @MainActor
        func run() async throws {
            try await report(global) {
                let sandboxes = Sandboxes(paths: Paths())
                var removed: [SandboxRemoved] = []
                for name in names { removed.append(try await sandboxes.remove(name)) }
                let text = removed.map { "removed \($0.name)" + ($0.checkpoints.isEmpty ? "" : " and checkpoints \($0.checkpoints.joined(separator: ", "))") }
                return (SandboxRemovedReport(removed: removed), text.joined(separator: "\n"), true)
            }
        }
    }

    struct Checkpoint: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save a sandbox's filesystem as a checkpoint.",
            discussion: "Pauses it for the moment it takes. Processes, memory and host mounts are not saved."
        )
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Sandbox name.") var name: String
        @Argument(help: "Checkpoint name (default the next c<N>).") var checkpoint: String?

        @MainActor
        func run() async throws {
            try await report(global) {
                let c = try await Sandboxes(paths: Paths()).checkpoint(name, as: checkpoint)
                return (c, "\(name): checkpoint \(c.name) (\(c.addedMb.map { "+\($0) MB" } ?? "\(c.sizeMb) MB"), \(c.ms ?? 0) ms)", true)
            }
        }
    }

    struct Rollback: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Put a sandbox's filesystem back to a checkpoint (default the latest); kills its processes.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Sandbox name.") var name: String
        @Argument(help: "Checkpoint (default the latest).") var checkpoint: String?

        @MainActor
        func run() async throws {
            try await report(global) {
                let sandbox = try await Sandboxes(paths: Paths()).rollback(name, to: checkpoint)
                return (sandbox, describe(sandbox), true)
            }
        }
    }

    struct Fork: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start a copy of a sandbox, from a checkpoint or its current filesystem.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Sandbox name.") var name: String
        @Argument(help: "Name of the copy (default <name>-f<random>).") var newName: String?
        @Option(help: "Fork from this checkpoint instead of the current state.") var checkpoint: String?
        @Option(help: "Lifetime of the copy (default the original's TTL).") var ttl: String?

        @MainActor
        func run() async throws {
            try await report(global) {
                let sandbox = try await Sandboxes(paths: Paths()).fork(name, into: newName, from: checkpoint, ttl: try ttl.map(parseDuration))
                return (sandbox, describe(sandbox), true)
            }
        }
    }

    struct Logs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the logs of a sandbox's main process or of a container, capped, with a summary.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Sandbox name, or container name or id.") var target: String
        @Option(help: "Only after this: 10m, an RFC 3339 time or Unix seconds.") var since: String?
        @Option(help: "Only the last N lines.") var tail: Int?
        @Flag(help: "Prefix lines with their time.") var timestamps = false
        @Option(help: "Bytes kept per stream, head and tail.") var maxOutputBytes = 8192

        @MainActor
        func run() async throws {
            try await report(global) {
                let r = try await Sandboxes(paths: Paths()).logs(target, since: since, tail: tail, timestamps: timestamps, maxOutputBytes: maxOutputBytes)
                var text = r.stdout
                if !r.stderr.isEmpty { text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + "--- stderr ---\n" + r.stderr }
                let s = r.summary
                text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") +
                    "--- \(s.stdoutLines) stdout lines, \(s.stderrLines) stderr lines, \(s.errorLines) look like errors ---"
                for e in s.errors { text += "\n\(e.stream):\(e.line): \(e.text)" }
                return (r, text, true)
            }
        }
    }
}

struct SandboxListReport: Encodable {
    let ok = true
    let sandboxes: [SandboxInfo]
}

struct SandboxRemovedReport: Encodable {
    let ok = true
    let removed: [SandboxRemoved]
}

private func describe(_ s: SandboxInfo) -> String {
    let p = s.policy
    var network = p.network
    if p.network == "allowlist" { network = p.allow.joined(separator: ",") + (s.allowed.isEmpty ? "" : " (\(s.allowed.joined(separator: ",")))") }
    var line = "\(s.name): \(s.state), \(formatElapsed(s.expiresInS)) left, network \(network), \(p.cpus) cpus, \(p.memory), image \(s.image)"
    for m in p.mounts { line += "\n  mount \(m.host) -> \(m.path) (\(m.writable ? "rw" : "ro"))" }
    if !s.checkpoints.isEmpty { line += "\n  checkpoints: " + s.checkpoints.map(\.name).joined(separator: ", ") }
    return line
}
