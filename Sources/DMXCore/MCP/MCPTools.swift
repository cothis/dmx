import Foundation

/// A tool `dmx mcp` offers. `call` returns the structured result, which also goes out as JSON
/// text; a thrown DMXError becomes a result with `isError` and the hint.
struct MCPTool: Sendable {
    let definition: JSONValue
    let call: @Sendable (Paths, MCPArguments) async throws -> MCPToolResult

    var name: String { definition["name"]?.string ?? "" }
}

struct MCPToolResult: Sendable {
    let structured: JSONValue
    var isError = false
}

/// Per-stream output limit of `dmx_exec`, in bytes: head and tail halves. Large enough for most
/// command output, small enough that both streams stay well inside an agent's context.
public let mcpDefaultMaxOutputBytes = 8192
public let mcpMaximumMaxOutputBytes = 1 << 20
public let mcpDefaultExecTimeout = 120.0
public let mcpMaximumExecTimeout = 3600.0

let mcpTools: [MCPTool] = [
    MCPTool(definition: [
        "name": "dmx_exec",
        "title": "Run a command in the dmx VM",
        "description": .string("""
            Runs a command in dmx's Linux VM (Alpine, arm64) and returns its exit code, stdout and \
            stderr. The VM boots on first use in well under a second and stops by itself when idle. \
            argv runs directly, without a shell: use ["sh", "-c", "..."] for pipes and redirection. \
            Each stream keeps its first and last max_output_bytes/2 bytes, with a marker saying how \
            many bytes were left out; for long output, write it to a file in the VM and read parts \
            of it (head, tail, grep). On timeout the command and its children are killed and \
            timed_out is true.
            """),
        "inputSchema": [
            "type": "object",
            "properties": [
                "argv": ["type": "array", "items": ["type": "string"], "minItems": 1,
                         "description": "Program and arguments, e.g. [\"uname\", \"-a\"]."],
                "stdin": ["type": "string", "description": "Text to send on standard input (default: none, /dev/null)."],
                "env": ["type": "object", "additionalProperties": ["type": "string"],
                        "description": "Environment variables to add, e.g. {\"LANG\": \"C\"}."],
                "cwd": ["type": "string", "description": "Working directory in the VM (default /)."],
                "timeout": ["type": "number", "exclusiveMinimum": 0, "maximum": .double(mcpMaximumExecTimeout),
                            "description": .string("Seconds before the command is killed (default \(Int(mcpDefaultExecTimeout))).")],
                "max_output_bytes": ["type": "integer", "minimum": 0, "maximum": .int(mcpMaximumMaxOutputBytes),
                                     "description": .string("Bytes kept per stream, head and tail (default \(mcpDefaultMaxOutputBytes)).")],
            ],
            "required": ["argv"],
            "additionalProperties": false,
        ],
        "outputSchema": [
            "type": "object",
            "properties": [
                "exit_code": ["type": ["integer", "null"], "description": "Null if killed by a signal or the timeout."],
                "signal": ["type": ["integer", "null"]],
                "timed_out": ["type": "boolean"],
                "duration_ms": ["type": "integer"],
                "stdout": ["type": "string"],
                "stderr": ["type": "string"],
                "stdout_bytes": ["type": "integer", "description": "Bytes the command wrote in total."],
                "stderr_bytes": ["type": "integer"],
                "stdout_omitted_bytes": ["type": "integer", "description": "Bytes left out of stdout."],
                "stderr_omitted_bytes": ["type": "integer"],
            ],
            "required": ["exit_code", "signal", "timed_out", "duration_ms", "stdout", "stderr",
                         "stdout_bytes", "stderr_bytes", "stdout_omitted_bytes", "stderr_omitted_bytes"],
        ],
    ]) { paths, args in
        let argv = try args.strings("argv")
        guard let argv, !argv.isEmpty else {
            throw args.error("argv is required: the program and its arguments, e.g. [\"uname\", \"-a\"]")
        }
        let timeout = try args.number("timeout") ?? mcpDefaultExecTimeout
        guard timeout > 0, timeout <= mcpMaximumExecTimeout else {
            throw args.error("timeout must be more than 0 and at most \(Int(mcpMaximumExecTimeout)) seconds")
        }
        let limit = try args.integer("max_output_bytes") ?? mcpDefaultMaxOutputBytes
        guard limit >= 0, limit <= mcpMaximumMaxOutputBytes else {
            throw args.error("max_output_bytes must be between 0 and \(mcpMaximumMaxOutputBytes)")
        }
        let env = try args.stringMap("env").map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } } ?? []
        let result = try await execCapped(
            paths: paths, argv: argv, stdin: try args.string("stdin").map { Data($0.utf8) }, env: env,
            cwd: try args.string("cwd"), timeout: .milliseconds(Int(timeout * 1000)), maxOutputBytes: limit)
        mcpLog("dmx_exec \(argv.joined(separator: " ").prefix(80)): " +
               (result.timedOut ? "timed out" : "exit \(result.exitCode.map(String.init) ?? "signal \(result.signal ?? 0)")") +
               " in \(result.durationMs) ms, \(result.stdoutBytes + result.stderrBytes) bytes")
        return MCPToolResult(structured: try JSONValue(encoding: result), isError: result.timedOut)
    },

    MCPTool(definition: [
        "name": "dmx_status",
        "title": "dmx VM status",
        "description": .string("""
            Shows whether dmx's VM runs and what it costs: state (not_running, stopped, starting, \
            running, stopping), uptime, cpus, memory ceiling, guest memory used, host memory \
            footprint in MB, exec sessions, idle timeout and seconds until the idle stop. Never \
            boots the VM.
            """),
        "inputSchema": ["type": "object", "additionalProperties": false],
        "annotations": ["readOnlyHint": true, "openWorldHint": false],
    ]) { paths, args in
        try args.checkKnown()
        guard let client = try await DaemonClient.connect(paths: paths, start: false) else {
            return MCPToolResult(structured: try JSONValue(encoding: DaemonStatus.notRunning(paths, config: (try? Config.load(paths)) ?? Config())))
        }
        defer { client.close() }
        return MCPToolResult(structured: try JSONValue(encoding: try await client.status()))
    },

    MCPTool(definition: [
        "name": "dmx_start",
        "title": "Boot the dmx VM",
        "description": "Boots dmx's VM now instead of on the first dmx_exec, and returns its status. It stops again after the idle timeout with nothing using it.",
        "inputSchema": ["type": "object", "additionalProperties": false],
        "annotations": ["idempotentHint": true, "destructiveHint": false, "openWorldHint": false],
    ]) { paths, args in
        try args.checkKnown()
        let client = try await DaemonClient.connect(paths: paths, start: true)!
        defer { client.close() }
        return MCPToolResult(structured: try JSONValue(encoding: try await client.start()))
    },

    MCPTool(definition: [
        "name": "dmx_stop",
        "title": "Power off the dmx VM",
        "description": "Powers dmx's VM off now, killing every process in it, and returns its status. The next dmx_exec boots it again.",
        "inputSchema": ["type": "object", "additionalProperties": false],
        "annotations": ["idempotentHint": true, "destructiveHint": true, "openWorldHint": false],
    ]) { paths, args in
        try args.checkKnown()
        guard let client = try await DaemonClient.connect(paths: paths, start: false) else {
            return MCPToolResult(structured: try JSONValue(encoding: DaemonStatus.notRunning(paths, config: (try? Config.load(paths)) ?? Config())))
        }
        defer { client.close() }
        return MCPToolResult(structured: try JSONValue(encoding: try await client.stop()))
    },

    MCPTool(definition: [
        "name": "dmx_config_get",
        "title": "Read dmx settings",
        "description": .string("Shows dmx's settings with the values in effect (\(Config.keys.joined(separator: ", "))), and which of them are set rather than defaults."),
        "inputSchema": [
            "type": "object",
            "properties": ["key": ["type": "string", "description": "One setting; default all."]],
            "additionalProperties": false,
        ],
        "annotations": ["readOnlyHint": true, "openWorldHint": false],
    ]) { paths, args in
        MCPToolResult(structured: try configResult(paths, only: try args.string("key")))
    },

    MCPTool(definition: [
        "name": "dmx_config_set",
        "title": "Change a dmx setting",
        "description": .string("""
            Changes one of dmx's settings in ~/.dmx/config.json: cpus (e.g. "4"), memory (the \
            ceiling, e.g. "8G"; only touched pages cost host memory) or idle_timeout (e.g. "10m"). \
            A null value puts it back to its default. Takes effect the next time the VM boots \
            (dmx_stop, then dmx_exec or dmx_start).
            """),
        "inputSchema": [
            "type": "object",
            "properties": [
                "key": ["type": "string", "enum": .array(Config.keys.map { .string($0) })],
                "value": ["type": ["string", "null"], "description": "The new value; null for the default."],
            ],
            "required": ["key", "value"],
            "additionalProperties": false,
        ],
        "annotations": ["idempotentHint": true, "destructiveHint": false, "openWorldHint": false],
    ]) { paths, args in
        guard let key = try args.string("key") else { throw args.error("key is required") }
        var config = try Config.load(paths)
        try config.set(key, try args.string("value"))
        try config.save(paths)
        return MCPToolResult(structured: try configResult(paths, only: key))
    },
]

/// Settings in effect, which of them the file sets, and the file; like `dmx config get --json`.
private func configResult(_ paths: Paths, only key: String?) throws -> JSONValue {
    let config = try Config.load(paths)
    var settings = config.effective
    if let key {
        guard let value = settings[key] else {
            throw DMXError("unknown_config_key", "no setting named \"\(key)\"", hint: "settings are \(Config.keys.joined(separator: ", "))")
        }
        settings = [key: value]
    }
    // Keys present in the encoded file are the configured ones; unset optionals are left out.
    let configured = (try JSONValue(encoding: config)).object?.keys.sorted() ?? []
    return .object([
        "settings": .object(settings.mapValues { .string($0) }),
        "configured": .array(Config.keys.filter { configured.contains($0) }.map { .string($0) }),
        "file": .string(paths.config.path),
    ])
}

/// A tool call's arguments, checked against the tool's input schema as they are read.
struct MCPArguments: Sendable {
    let tool: String
    let values: [String: JSONValue]
    let known: Set<String>

    init(tool: MCPTool, values: [String: JSONValue]) {
        self.tool = tool.name
        self.values = values
        known = Set(tool.definition["inputSchema"]?["properties"]?.object?.keys.map { $0 } ?? [])
    }

    func error(_ message: String) -> DMXError {
        DMXError("bad_argument", "\(tool): \(message)", hint: "see the input schema of \(tool) in tools/list")
    }

    func checkKnown() throws {
        if let unknown = values.keys.sorted().first(where: { !known.contains($0) }) {
            throw error("unknown argument \"\(unknown)\"" + (known.isEmpty ? "; it takes none" : "; it takes \(known.sorted().joined(separator: ", "))"))
        }
    }

    /// The value of `key`, nil if absent or null. Every getter checks for unknown keys first.
    private func value(_ key: String) throws -> JSONValue? {
        try checkKnown()
        guard let value = values[key], value != .null else { return nil }
        return value
    }

    func string(_ key: String) throws -> String? {
        guard let v = try value(key) else { return nil }
        guard let s = v.string else { throw error("\(key) must be a string") }
        return s
    }

    func number(_ key: String) throws -> Double? {
        switch try value(key) {
        case nil: return nil
        case .int(let n): return Double(n)
        case .double(let n): return n
        default: throw error("\(key) must be a number")
        }
    }

    func integer(_ key: String) throws -> Int? {
        switch try value(key) {
        case nil: return nil
        case .int(let n): return n
        case .double(let n) where n == n.rounded() && abs(n) < 1e15: return Int(n)
        default: throw error("\(key) must be a whole number")
        }
    }

    func strings(_ key: String) throws -> [String]? {
        guard let v = try value(key) else { return nil }
        guard case .array(let items) = v, let strings = Optional(items.compactMap(\.string)), strings.count == items.count else {
            throw error("\(key) must be an array of strings")
        }
        return strings
    }

    func stringMap(_ key: String) throws -> [String: String]? {
        guard let v = try value(key) else { return nil }
        guard let object = v.object else { throw error("\(key) must be an object of strings") }
        return try object.reduce(into: [:]) { result, item in
            guard !item.key.isEmpty, !item.key.contains("=") else { throw error("\(key) has a bad name \"\(item.key)\"") }
            guard let s = item.value.string else { throw error("\(key) values must be strings") }
            result[item.key] = s
        }
    }
}
