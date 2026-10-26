import Foundation

/// Every tool `dmx mcp` offers: the VM's (MCPTools.swift) and the sandboxes'.
let allMCPTools = mcpTools + sandboxTools

/// Output schema of a sandbox, shared by create, rollback and fork.
private let sandboxSchema: JSONValue = [
    "type": "object",
    "properties": [
        "name": ["type": "string"],
        "state": ["type": "string", "description": "Docker's state of the sandbox's container: running, exited, ..."],
        "id": ["type": "string"],
        "container": ["type": "string"],
        "image": ["type": "string"],
        "policy": ["type": "object"],
        "allowed": ["type": "array", "items": ["type": "string"], "description": "Addresses the allowlist resolved to."],
        "created_at": ["type": "string"],
        "expires_at": ["type": "string"],
        "expires_in_s": ["type": "integer"],
        "checkpoints": ["type": "array", "items": ["type": "object"]],
    ],
    "required": ["name", "state", "policy", "expires_at", "expires_in_s", "checkpoints"],
]

private let nameProperty: JSONValue = ["type": "string", "description": "The sandbox's name, as dmx_sandbox_create returned it."]

let sandboxTools: [MCPTool] = [
    MCPTool(definition: [
        "name": "dmx_sandbox_create",
        "title": "Create a sandbox",
        "description": .string("""
            Creates a disposable Linux environment (a container in dmx's VM) with a policy, and \
            returns it. By default: image alpine 3.24 (pinned), no network, no host files, \
            \(SandboxPolicy.defaultCpus) CPUs, \(SandboxPolicy.defaultMemory) memory, removed after \
            \(formatDuration(SandboxPolicy.defaultTTL)). Grant only what the task needs: network \
            "all", or a list of hosts and CIDRs (DNS is allowed then); host directories as \
            mounts, read-only unless writable is true. Then run commands with dmx_sandbox_exec, \
            save and restore its filesystem with dmx_sandbox_checkpoint and dmx_sandbox_rollback, \
            try two approaches with dmx_sandbox_fork, and remove it with dmx_sandbox_rm when done.
            """),
        "inputSchema": [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "1-40 lowercase letters, digits, '-', '_', '.'; default sb-<random>."],
                "image": ["type": "string", "description": .string("Image reference (default \(SandboxPolicy.defaultImage)). The default command is `sleep`, so the image needs one, or give command.")],
                "network": [
                    "description": "\"none\" (default; loopback only), \"all\", or an allowlist: an array of hostnames, IPv4 addresses and CIDRs. Hostnames resolve once, at creation.",
                    "anyOf": [["type": "string", "enum": ["none", "all"]], ["type": "array", "items": ["type": "string"], "minItems": 1]],
                ],
                "mounts": [
                    "type": "array",
                    "description": "Host directories to show in the sandbox. Must be under dmx's shares (/Users, /Volumes, /private by default). Strings \"HOST[:PATH][:rw]\" work too.",
                    "items": ["anyOf": [["type": "string"], [
                        "type": "object",
                        "properties": [
                            "host": ["type": "string", "description": "Absolute host path."],
                            "path": ["type": "string", "description": "Path in the sandbox (default: the host path)."],
                            "writable": ["type": "boolean", "description": "Default false: read-only."],
                        ],
                        "required": ["host"],
                        "additionalProperties": false,
                    ]]],
                ],
                "cpus": ["type": "number", "exclusiveMinimum": 0, "maximum": 64],
                "memory": ["type": "string", "description": "Memory limit, e.g. \"512M\", \"2G\"."],
                "pids": ["type": "integer", "minimum": 16, "description": .string("Process limit (default \(SandboxPolicy.defaultPids)).")],
                "ttl": ["type": ["string", "integer"], "description": .string("Lifetime: seconds, or \"90s\", \"30m\", \"2h\" (default \(formatDuration(SandboxPolicy.defaultTTL)), at most \(formatDuration(SandboxPolicy.maxTTL))).")],
                "env": ["type": "object", "additionalProperties": ["type": "string"], "description": "Environment for every command in it."],
                "workdir": ["type": "string", "description": "Default working directory of commands."],
                "command": ["type": "array", "items": ["type": "string"], "description": "Main process instead of sleep; its output is what dmx_logs shows. When it exits, exec no longer works."],
            ],
            "additionalProperties": false,
        ],
        "outputSchema": sandboxSchema,
        "annotations": ["destructiveHint": false, "openWorldHint": true],
    ]) { paths, args in
        try args.checkKnown()
        var policy = SandboxPolicy()
        if let image = try args.string("image") { policy.image = image }
        switch args.values["network"] {
        case nil, .null: break
        case .string(let s): try policy.setNetwork(s)
        case .array(let items):
            let hosts = items.compactMap(\.string)
            guard hosts.count == items.count, !hosts.isEmpty, !hosts.contains(where: { $0.contains(",") }) else {
                throw args.error("network must be \"none\", \"all\" or an array of hosts and CIDRs")
            }
            policy.network = "allowlist"
            policy.allow = hosts
        default: throw args.error("network must be \"none\", \"all\" or an array of hosts and CIDRs")
        }
        if case .array(let items)? = args.values["mounts"] {
            policy.mounts = try items.map { item in
                if let text = item.string { return try SandboxMount.parse(text) }
                guard let host = item["host"]?.string, item.object?.keys.allSatisfy({ ["host", "path", "writable"].contains($0) }) == true else {
                    throw args.error("each mount is {\"host\": path, \"path\": path in the sandbox, \"writable\": bool}")
                }
                let writable: Bool
                switch item["writable"] {
                case nil, .null: writable = false
                case .bool(let b): writable = b
                default: throw args.error("mount writable must be true or false")
                }
                return SandboxMount(host: (host as NSString).expandingTildeInPath, path: item["path"]?.string ?? host, writable: writable)
            }
        } else if args.values["mounts"] != nil && args.values["mounts"] != .null {
            throw args.error("mounts must be an array")
        }
        if let cpus = try args.number("cpus") { policy.cpus = cpus }
        if let memory = try args.string("memory") { policy.memory = memory }
        if let pids = try args.integer("pids") { policy.pids = pids }
        if let ttl = try ttlArgument(args) { policy.ttlS = ttl }
        if let env = try args.stringMap("env") { policy.env = env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } }
        policy.workdir = try args.string("workdir")
        policy.command = try args.strings("command")
        let started = ContinuousClock.now
        let sandbox = try await Sandboxes(paths: paths).create(name: try args.string("name"), policy: policy)
        mcpLog("dmx_sandbox_create \(sandbox.name) (\(policy.network)) in \(milliseconds(ContinuousClock.now - started)) ms")
        return MCPToolResult(structured: try JSONValue(encoding: sandbox))
    },

    MCPTool(definition: [
        "name": "dmx_sandbox_exec",
        "title": "Run a command in a sandbox",
        "description": .string("""
            Runs a command in a sandbox and returns its exit code, stdout and stderr, with the \
            same output limits and timeout as dmx_exec. argv runs directly, without a shell: use \
            ["sh", "-c", "..."] for pipes. On timeout the command and its children are killed. A \
            sandbox stopped with the VM starts again first.
            """),
        "inputSchema": [
            "type": "object",
            "properties": [
                "name": nameProperty,
                "argv": ["type": "array", "items": ["type": "string"], "minItems": 1, "description": "Program and arguments."],
                "stdin": ["type": "string", "description": "Text to send on standard input (default: none)."],
                "env": ["type": "object", "additionalProperties": ["type": "string"]],
                "cwd": ["type": "string", "description": "Working directory (default: the sandbox's)."],
                "timeout": ["type": "number", "exclusiveMinimum": 0, "maximum": .double(mcpMaximumExecTimeout),
                            "description": .string("Seconds before the command is killed (default \(Int(mcpDefaultExecTimeout))).")],
                "max_output_bytes": ["type": "integer", "minimum": 0, "maximum": .int(mcpMaximumMaxOutputBytes),
                                     "description": .string("Bytes kept per stream, head and tail (default \(mcpDefaultMaxOutputBytes)).")],
            ],
            "required": ["name", "argv"],
            "additionalProperties": false,
        ],
        "annotations": ["destructiveHint": true, "openWorldHint": true],
    ]) { paths, args in
        guard let name = try args.string("name") else { throw args.error("name is required") }
        guard let argv = try args.strings("argv"), !argv.isEmpty else { throw args.error("argv is required: the program and its arguments") }
        let timeout = try args.number("timeout") ?? mcpDefaultExecTimeout
        guard timeout > 0, timeout <= mcpMaximumExecTimeout else {
            throw args.error("timeout must be more than 0 and at most \(Int(mcpMaximumExecTimeout)) seconds")
        }
        let limit = try args.integer("max_output_bytes") ?? mcpDefaultMaxOutputBytes
        guard limit >= 0, limit <= mcpMaximumMaxOutputBytes else { throw args.error("max_output_bytes must be between 0 and \(mcpMaximumMaxOutputBytes)") }
        let env = try args.stringMap("env").map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } } ?? []
        let result = try await Sandboxes(paths: paths).exec(
            name, argv: argv, stdin: try args.string("stdin").map { Data($0.utf8) }, env: env, cwd: try args.string("cwd"),
            timeout: .milliseconds(Int(timeout * 1000)), maxOutputBytes: limit)
        mcpLog("dmx_sandbox_exec \(name) \(argv.joined(separator: " ").prefix(80)): " +
               (result.timedOut ? "timed out" : "exit \(result.exitCode.map(String.init) ?? "killed")") + " in \(result.durationMs) ms")
        return MCPToolResult(structured: try JSONValue(encoding: result), isError: result.timedOut)
    },

    MCPTool(definition: [
        "name": "dmx_sandbox_list",
        "title": "List sandboxes",
        "description": "Lists the sandboxes with their state, policy, time left and checkpoints. Removes those past their TTL first.",
        "inputSchema": ["type": "object", "additionalProperties": false],
        "annotations": ["readOnlyHint": true, "openWorldHint": false],
    ]) { paths, args in
        try args.checkKnown()
        let sandboxes = Sandboxes(paths: paths)
        await sandboxes.sweep()
        return MCPToolResult(structured: ["sandboxes": try JSONValue(encoding: try await sandboxes.list())])
    },

    MCPTool(definition: [
        "name": "dmx_sandbox_rm",
        "title": "Remove a sandbox",
        "description": "Removes a sandbox now: kills what runs in it and deletes its filesystem and checkpoints. Host directories it mounted are not touched.",
        "inputSchema": ["type": "object", "properties": ["name": nameProperty], "required": ["name"], "additionalProperties": false],
        "annotations": ["destructiveHint": true, "idempotentHint": false, "openWorldHint": false],
    ]) { paths, args in
        guard let name = try args.string("name") else { throw args.error("name is required") }
        return MCPToolResult(structured: try JSONValue(encoding: try await Sandboxes(paths: paths).remove(name)))
    },

    MCPTool(definition: [
        "name": "dmx_sandbox_checkpoint",
        "title": "Checkpoint a sandbox",
        "description": .string("""
            Saves the sandbox's filesystem as a named checkpoint (default c1, c2, ...), pausing it \
            for the moment it takes. Running processes, memory and mounted host directories are \
            not saved. Restore it with dmx_sandbox_rollback, or start a copy with dmx_sandbox_fork.
            """),
        "inputSchema": [
            "type": "object",
            "properties": ["name": nameProperty, "checkpoint": ["type": "string", "description": "Checkpoint name; default the next c<N>."]],
            "required": ["name"],
            "additionalProperties": false,
        ],
        "annotations": ["destructiveHint": false, "openWorldHint": false],
    ]) { paths, args in
        guard let name = try args.string("name") else { throw args.error("name is required") }
        let checkpoint = try await Sandboxes(paths: paths).checkpoint(name, as: try args.string("checkpoint"))
        mcpLog("dmx_sandbox_checkpoint \(name):\(checkpoint.name) in \(checkpoint.ms ?? 0) ms")
        return MCPToolResult(structured: try JSONValue(encoding: checkpoint))
    },

    MCPTool(definition: [
        "name": "dmx_sandbox_rollback",
        "title": "Roll a sandbox back",
        "description": "Puts the sandbox's filesystem back to a checkpoint (default the latest). Processes running in it are killed; the policy and TTL stay.",
        "inputSchema": [
            "type": "object",
            "properties": ["name": nameProperty, "checkpoint": ["type": "string", "description": "Default: the latest."]],
            "required": ["name"],
            "additionalProperties": false,
        ],
        "outputSchema": sandboxSchema,
        "annotations": ["destructiveHint": true, "openWorldHint": false],
    ]) { paths, args in
        guard let name = try args.string("name") else { throw args.error("name is required") }
        return MCPToolResult(structured: try JSONValue(encoding: try await Sandboxes(paths: paths).rollback(name, to: try args.string("checkpoint"))))
    },

    MCPTool(definition: [
        "name": "dmx_sandbox_fork",
        "title": "Fork a sandbox",
        "description": .string("""
            Starts a new sandbox with the same policy from a sandbox's checkpoint, or from its \
            filesystem as it is now, to try another approach side by side. Its TTL starts now.
            """),
        "inputSchema": [
            "type": "object",
            "properties": [
                "name": nameProperty,
                "new_name": ["type": "string", "description": "Name of the copy; default <name>-f<random>."],
                "checkpoint": ["type": "string", "description": "Fork from this checkpoint instead of the current state."],
                "ttl": ["type": ["string", "integer"], "description": "Lifetime of the copy; default the original's TTL."],
            ],
            "required": ["name"],
            "additionalProperties": false,
        ],
        "outputSchema": sandboxSchema,
        "annotations": ["destructiveHint": false, "openWorldHint": false],
    ]) { paths, args in
        guard let name = try args.string("name") else { throw args.error("name is required") }
        let started = ContinuousClock.now
        let sandbox = try await Sandboxes(paths: paths).fork(name, into: try args.string("new_name"), from: try args.string("checkpoint"), ttl: try ttlArgument(args))
        mcpLog("dmx_sandbox_fork \(name) -> \(sandbox.name) in \(milliseconds(ContinuousClock.now - started)) ms")
        return MCPToolResult(structured: try JSONValue(encoding: sandbox))
    },

    MCPTool(definition: [
        "name": "dmx_logs",
        "title": "Read container logs",
        "description": .string("""
            Reads the logs of a sandbox's main process or of any Docker container (name or id), \
            with the same head-and-tail limits as dmx_exec, and a summary of the whole log: line \
            counts and the first and last lines that look like errors. Narrow it with since and tail.
            """),
        "inputSchema": [
            "type": "object",
            "properties": [
                "target": ["type": "string", "description": "Sandbox name, or container name or id."],
                "since": ["type": "string", "description": "Only after this: a duration back from now (\"10m\"), an RFC 3339 time or Unix seconds."],
                "tail": ["type": "integer", "minimum": 0, "description": "Only the last N lines."],
                "timestamps": ["type": "boolean", "description": "Prefix each line with its time."],
                "max_output_bytes": ["type": "integer", "minimum": 0, "maximum": .int(mcpMaximumMaxOutputBytes),
                                     "description": .string("Bytes kept per stream, head and tail (default \(mcpDefaultMaxOutputBytes)).")],
            ],
            "required": ["target"],
            "additionalProperties": false,
        ],
        "annotations": ["readOnlyHint": true, "openWorldHint": false],
    ]) { paths, args in
        guard let target = try args.string("target") else { throw args.error("target is required") }
        let limit = try args.integer("max_output_bytes") ?? mcpDefaultMaxOutputBytes
        guard limit >= 0, limit <= mcpMaximumMaxOutputBytes else { throw args.error("max_output_bytes must be between 0 and \(mcpMaximumMaxOutputBytes)") }
        let timestamps: Bool
        switch args.values["timestamps"] {
        case nil, .null: timestamps = false
        case .bool(let b): timestamps = b
        default: throw args.error("timestamps must be true or false")
        }
        let result = try await Sandboxes(paths: paths).logs(target, since: try args.string("since"), tail: try args.integer("tail"),
                                                            timestamps: timestamps, maxOutputBytes: limit)
        return MCPToolResult(structured: try JSONValue(encoding: result))
    },
]

/// `ttl` as seconds or a duration string.
private func ttlArgument(_ args: MCPArguments) throws -> Int? {
    try args.checkKnown()
    switch args.values["ttl"] {
    case nil, .null: return nil
    case .int(let n): return n
    case .double: return try args.integer("ttl")
    case .string(let s):
        do { return try parseDuration(s) } catch { throw args.error("ttl must be seconds or a duration like \"30m\", not \"\(s)\"") }
    default: throw args.error("ttl must be seconds or a duration like \"30m\"")
    }
}
