import ArgumentParser
import DMXCore
import Foundation

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show whether the VM runs and what it costs.")

    @OptionGroup var global: GlobalOptions

    @MainActor
    func run() async throws {
        try await report(global) {
            let status = try await daemonStatus(Paths())
            return (status, describe(status), true)
        }
    }
}

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Boot the VM now instead of on first use.",
        discussion: "It stops again after the idle timeout (`dmx config get idle_timeout`) with nothing using it."
    )

    @OptionGroup var global: GlobalOptions

    @MainActor
    func run() async throws {
        try await report(global) {
            let client = try await DaemonClient.connect(paths: Paths(), start: true)!
            defer { client.close() }
            let status = try await client.start()
            return (status, describe(status), true)
        }
    }
}

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Power the VM off; the daemon exits shortly after.")

    @OptionGroup var global: GlobalOptions

    @MainActor
    func run() async throws {
        try await report(global) {
            let paths = Paths()
            guard let client = try await DaemonClient.connect(paths: paths, start: false) else {
                let status = try await daemonStatus(paths)
                return (status, describe(status), true)
            }
            defer { client.close() }
            let status = try await client.stop()
            return (status, describe(status), true)
        }
    }
}

struct Exec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command in the VM, booting it if needed.",
        discussion: """
            stdin, stdout and stderr are attached and dmx exits with the command's status.
            Output passes through untouched; --json changes only how dmx's own errors print.
            Example: dmx exec -- uname -a
            """
    )

    @OptionGroup var global: GlobalOptions

    @Flag(name: .shortAndLong, help: "Give the command a terminal (for interactive programs).")
    var tty = false

    @Option(name: .shortAndLong, help: "Environment variable KEY=VALUE (repeatable).")
    var env: [String] = []

    @Option(name: .shortAndLong, help: "Working directory in the guest.")
    var workdir: String?

    @Argument(parsing: .captureForPassthrough, help: "The command and its arguments.")
    var command: [String] = []

    @MainActor
    func run() async throws {
        let argv = command.first == "--" ? Array(command.dropFirst()) : command
        try await runExec(global, argv: argv, tty: tty, env: env, cwd: workdir)
    }
}

struct Shell: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a shell in the VM, booting it if needed.",
        discussion: "With a terminal on stdin and stdout the shell is interactive; otherwise it reads commands from stdin."
    )

    @OptionGroup var global: GlobalOptions

    @MainActor
    func run() async throws {
        let tty = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
        try await runExec(global, argv: tty ? ["/bin/sh", "-l"] : ["/bin/sh"], tty: tty, env: [], cwd: nil)
    }
}

@MainActor
func runExec(_ global: GlobalOptions, argv: [String], tty: Bool, env: [String], cwd: String?) async throws {
    let status: Int32
    do {
        guard !argv.isEmpty else {
            throw DMXError("missing_command", "no command given", hint: "put the command after --, e.g. `dmx exec -- uname -a`")
        }
        status = try await execThroughDaemon(paths: Paths(), argv: argv, tty: tty, env: env, cwd: cwd)
    } catch let error as DMXError {
        try await report(global) { () -> (Bool, String, Bool) in throw error }
        return
    }
    throw ExitCode(status)
}

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Let launchd start the daemon when a client connects, from now on and after login.",
        discussion: """
            launchd then also listens on ~/.dmx/docker.sock, and the docker context `dmx` (pointing there) is created and selected. \
            ~/.docker/run/docker.sock, where Docker Desktop's socket lives, becomes a link to it unless another engine serves it. \
            The docker CLI, Compose and Buildx are installed as `dmx tools install` does. \
            Without it, dmx commands start the daemon themselves. Run it again after moving the dmx binary.
            """
    )

    @OptionGroup var global: GlobalOptions

    @MainActor
    func run() async throws {
        let quiet = global.json
        try await report(global) {
            let result = try await LaunchAgent.install(paths: Paths(), progress: { if !quiet { printProgress($0) } })
            var text = "installed \(result.label): \(result.plist)\n  socket \(result.socket), daemon pid \(result.daemonPid.map(String.init) ?? "-")"
            if let context = result.dockerContext { text += "\n  docker context \(context.name) (\(context.host)) selected" }
            if let link = result.dockerSocketLink {
                text += link.linked ? "\n  \(link.path) -> \(link.target)" : "\n  \(link.path) left alone: \(link.skipped ?? "taken")"
            }
            if let tools = result.dockerTools { text += "\n" + describeTools(tools) }
            return (result, text, true)
        }
    }
}

struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove the launchd agent; a running VM powers off.")

    @OptionGroup var global: GlobalOptions

    @MainActor
    func run() async throws {
        try await report(global) {
            let result = try LaunchAgent.uninstall(paths: Paths())
            return (result, "uninstalled \(result.label)", true)
        }
    }
}

struct Daemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the daemon in the foreground (launchd and the CLI start it; use this to debug).",
        discussion: "It owns the VM and serves ~/.dmx/dmx.sock, and exits when the VM is stopped and no client is connected."
    )

    @OptionGroup var global: GlobalOptions

    @MainActor
    func run() async throws {
        do {
            let daemon = try DMXCore.Daemon(paths: Paths(), version: version)
            await daemon.run()
        } catch let error as DMXError {
            try await report(global) { () -> (Bool, String, Bool) in throw error }
        }
    }
}

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read or change settings in ~/.dmx/config.json.",
        discussion: "Settings: cpus, memory (ceiling, e.g. 8G), idle_timeout (e.g. 5m), disk_size (default 64G; ~/.dmx/data.img is sparse, so it costs only what the guest stores; a larger value grows an existing disk at the next boot, a smaller one is ignored: disks do not shrink), x86_emulator (fex, the default, or qemu: what runs x86_64 programs and linux/amd64 images). They apply the next time the VM boots. Mirrors for company networks: release_url (the guest, GitHub's layout <url>/<tag>/<asset>) and tools_url (the docker CLI tools, <url>/<upstream file name>); downloads are still checked against their pinned sha256.",
        subcommands: [Get.self, Set.self, Unset.self]
    )

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show all settings, or one.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "A setting name.") var key: String?

        @MainActor
        func run() async throws {
            try await report(global) { try configReport(Paths(), only: key) }
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change a setting.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "A setting name.") var key: String
        @Argument(help: "Its new value.") var value: String

        @MainActor
        func run() async throws {
            try await report(global) {
                let paths = Paths()
                var config = try DMXCore.Config.load(paths)
                try config.set(key, value)
                try config.save(paths)
                return try configReport(paths, only: key)
            }
        }
    }

    struct Unset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Put a setting back to its default.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "A setting name.") var key: String

        @MainActor
        func run() async throws {
            try await report(global) {
                let paths = Paths()
                var config = try DMXCore.Config.load(paths)
                try config.set(key, nil)
                try config.save(paths)
                return try configReport(paths, only: key)
            }
        }
    }
}

struct ConfigReport: Encodable {
    let ok = true
    /// Every setting with the value in effect.
    let settings: [String: String]
    /// The settings given in the file; the others are defaults.
    let configured: [String]
    let file: String
}

func configReport(_ paths: Paths, only key: String?) throws -> (ConfigReport, String, Bool) {
    let config = try DMXCore.Config.load(paths)
    var settings = config.effective
    if let key {
        guard let value = settings[key] else {
            throw DMXError("unknown_config_key", "no setting named \"\(key)\"", hint: "settings are \(DMXCore.Config.keys.joined(separator: ", "))")
        }
        settings = [key: value]
    }
    let configured = DMXCore.Config.keys.filter { k in
        switch k {
        case "cpus": config.cpus != nil
        case "memory": config.memory != nil
        case "shares": config.shares != nil
        case "disk_size": config.diskSize != nil
        case "release_url": config.releaseUrl != nil
        case "tools_url": config.toolsUrl != nil
        case "x86_emulator": config.x86Emulator != nil
        default: config.idleTimeout != nil
        }
    }
    let text = DMXCore.Config.keys.compactMap { k in
        settings[k].map { "\(k) = \($0)\(configured.contains(k) ? "" : " (default)")" }
    }.joined(separator: "\n")
    return (ConfigReport(settings: settings, configured: configured, file: paths.config.path), text, true)
}

/// The daemon's status, or `not_running` without starting one (launchd starts it if installed).
@MainActor
func daemonStatus(_ paths: Paths) async throws -> DaemonStatus {
    guard let client = try await DaemonClient.connect(paths: paths, start: false) else {
        return DaemonStatus.notRunning(paths, config: (try? DMXCore.Config.load(paths)) ?? DMXCore.Config())
    }
    defer { client.close() }
    return try await client.status()
}

func describe(_ s: DaemonStatus) -> String {
    var lines: [String] = []
    switch s.state {
    case "not_running":
        lines.append("stopped (no daemon running)")
    default:
        lines.append("\(s.state) (daemon pid \(s.pid.map(String.init) ?? "-"), \(s.launchd == true ? "launchd" : "started by dmx"))")
    }
    if let cpus = s.cpus, let max = s.maxMemory {
        lines.append("  vm: \(cpus) cpus, \(max) max" + (s.uptimeS.map { ", up \(formatElapsed(Int($0)))" } ?? ""))
    }
    if let host = s.hostFootprintMb {
        lines.append("  memory: host footprint \(host) MB" + (s.guestUsedMb.map { ", guest uses \($0) MB" } ?? ""))
    }
    if let m = s.memory {
        if let plug = m.plug {
            lines.append("  ram: \(plug.bootMb + plug.pluggedMb) MB present (\(plug.bootMb) boot + \(plug.pluggedMb) plugged), target \(plug.bootMb + plug.requestedMb) MB")
        }
        var parts = ["host pressure \(m.hostPressure)" + (m.pressureSimulated ? " (simulated)" : "")]
        if let balloon = m.balloonMb, balloon > 0 || (m.balloonTargetMb ?? 0) > 0 {
            parts.append("balloon \(balloon) of \(m.balloonTargetMb ?? 0) MB")
        }
        if let trim = m.lastTrim { parts.append("last trim \(formatElapsed(trim.secondsAgo)) ago (\(trim.reason), \(trim.freedMb) MB)") }
        lines.append("  policy: " + parts.joined(separator: ", "))
    }
    if let disk = s.disk {
        lines.append("  disk: \(disk.path), \(formatSize(UInt64(disk.sizeMb) << 20)) max, \(disk.allocatedMb) MB used on the host")
    }
    if let socket = s.dockerSocket {
        lines.append("  docker: \(socket)" + (s.containers.map { ", \($0) running container\($0 == 1 ? "" : "s")" } ?? ""))
    }
    if let clients = s.clients, let execs = s.execs, s.state != "not_running" {
        lines.append("  clients: \(clients), execs: \(execs)")
    }
    lines.append("  idle timeout: \(formatDuration(s.idleTimeoutS))" + (s.idleStopInS.map { ", stops in \(formatElapsed($0)) if nothing uses it" } ?? ""))
    return lines.joined(separator: "\n")
}
