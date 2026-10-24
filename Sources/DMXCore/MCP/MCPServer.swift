import Foundation

/// MCP revisions `dmx mcp` speaks, newest first. 2026-07-28 is stateless: every request names
/// its version in `_meta` and `server/discover` replaces the handshake. The older ones open
/// with `initialize`. Both kinds are served from the same process.
let mcpModernVersions = ["2026-07-28"]
let mcpLegacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
let mcpVersionKey = "io.modelcontextprotocol/protocolVersion"
let mcpCapabilitiesKey = "io.modelcontextprotocol/clientCapabilities"

let mcpInstructions = """
    dmx runs Linux commands in a small VM on this Mac. dmx_exec boots the VM on first use in \
    well under a second; it stops by itself when idle, so there is no need to stop it. Output \
    is capped per stream (head and tail, with a marker); raise max_output_bytes or write long \
    output to a file in the VM and read parts of it. Errors carry a hint naming the next step.
    """

/// `dmx mcp`: an MCP server on stdin and stdout (newline-delimited JSON-RPC 2.0), logging to
/// stderr. It holds no connection to the daemon between tool calls, so the daemon can still
/// stop the VM and exit when idle; each call connects, and starts the daemon if needed.
public final class MCPServer: Sendable {
    private let paths: Paths
    private let serverInfo: JSONValue
    private let writer = MessageWriter()
    private let calls = RunningCalls()

    public init(paths: Paths, version: String) {
        self.paths = paths
        serverInfo = ["name": "dmx", "title": "dmx", "version": .string(version)]
    }

    /// Serves until stdin closes. Calls still running then are cancelled, which kills their
    /// guest processes.
    public func run() async {
        signal(SIGPIPE, SIG_IGN)
        mcpLog("serving MCP on stdio (DMX_HOME \(paths.home.path))")
        for await line in readLines(fd: STDIN_FILENO, maxLength: 64 << 20) {
            switch line {
            case .tooLong:
                writer.send(errorMessage(id: .null, RPCError(-32600, "message longer than 64 MiB")))
            case .message(let data):
                receive(data)
            }
        }
        calls.cancelAll()
        mcpLog("stdin closed, exiting")
    }

    private func receive(_ data: Data) {
        guard !data.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) else { return }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            writer.send(errorMessage(id: .null, RPCError(-32700, "parse error: not JSON")))
            return
        }
        guard let object = message.object else {
            writer.send(errorMessage(id: .null, RPCError(-32600, "expected one JSON-RPC object per line (batches are not supported)")))
            return
        }
        guard let method = object["method"]?.string else {
            // A response: dmx mcp sends no requests, so there is nothing to match it to.
            if object["id"] == nil || object["result"] == nil && object["error"] == nil {
                writer.send(errorMessage(id: object["id"] ?? .null, RPCError(-32600, "missing method")))
            }
            return
        }
        let params = object["params"]
        guard let id = object["id"] else {
            notification(method, params)
            return
        }
        switch id {
        case .string, .int: break
        default:
            writer.send(errorMessage(id: .null, RPCError(-32600, "id must be a string or an integer")))
            return
        }
        calls.start(id) { [self] in
            let reply: JSONValue
            do {
                reply = ["jsonrpc": "2.0", "id": id, "result": try await request(method, params)]
            } catch is CancellationError {
                return
            } catch let error as RPCError {
                reply = errorMessage(id: id, error)
            } catch {
                reply = errorMessage(id: id, RPCError(-32603, "internal error: \(error)"))
            }
            // A cancelled request gets no answer.
            if !Task.isCancelled { writer.send(reply) }
        }
    }

    private func notification(_ method: String, _ params: JSONValue?) {
        switch method {
        case "notifications/cancelled":
            if let id = params?["requestId"] {
                mcpLog("request \(id.compact) cancelled" + (params?["reason"]?.string.map { ": \($0)" } ?? ""))
                calls.cancel(id)
            }
        default:
            break // notifications/initialized and anything else need no action
        }
    }

    private func request(_ method: String, _ params: JSONValue?) async throws -> JSONValue {
        if let params, params.object == nil {
            throw RPCError(-32602, "params must be an object")
        }
        // A request with the modern per-request metadata is served under that revision.
        let meta = params?["_meta"]
        if let requested = meta?[mcpVersionKey] {
            guard let version = requested.string, mcpModernVersions.contains(version) else {
                throw RPCError(-32022, "Unsupported protocol version",
                               data: ["supported": .array((mcpModernVersions + mcpLegacyVersions).map { .string($0) }), "requested": requested])
            }
            guard meta?[mcpCapabilitiesKey]?.object != nil else {
                throw RPCError(-32602, "_meta is missing \(mcpCapabilitiesKey)")
            }
        }
        var result: JSONValue
        switch method {
        case "initialize":
            result = initialize(params)
        case "server/discover":
            guard meta?[mcpVersionKey] != nil else {
                throw RPCError(-32602, "server/discover needs _meta \(mcpVersionKey)")
            }
            result = [
                "supportedVersions": .array((mcpModernVersions + mcpLegacyVersions).map { .string($0) }),
                "capabilities": ["tools": [:]],
                "instructions": .string(mcpInstructions),
                "ttlMs": 300_000,
                "cacheScope": "public",
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": .array(mcpTools.map(\.definition)), "ttlMs": 300_000, "cacheScope": "public"]
        case "tools/call":
            result = try await callTool(params)
        default:
            throw RPCError(-32601, "method not found: \(method)")
        }
        // Fields of the 2026-07-28 revision; older clients ignore them.
        guard case .object(var fields) = result else { return result }
        fields["resultType"] = "complete"
        fields["_meta"] = ["io.modelcontextprotocol/serverInfo": serverInfo]
        result = .object(fields)
        return result
    }

    /// The legacy handshake: answer with the client's version if known, else the newest legacy one.
    private func initialize(_ params: JSONValue?) -> JSONValue {
        let requested = params?["protocolVersion"]?.string ?? ""
        let version = mcpLegacyVersions.contains(requested) ? requested : mcpLegacyVersions[0]
        let client = params?["clientInfo"]
        mcpLog("initialize from \(client?["name"]?.string ?? "?") \(client?["version"]?.string ?? ""), protocol \(requested) -> \(version)")
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": [:]],
            "serverInfo": serverInfo,
            "instructions": .string(mcpInstructions),
        ]
    }

    private func callTool(_ params: JSONValue?) async throws -> JSONValue {
        guard let name = params?["name"]?.string else { throw RPCError(-32602, "tools/call needs a tool name") }
        guard let tool = mcpTools.first(where: { $0.name == name }) else {
            throw RPCError(-32602, "Unknown tool: \(name)")
        }
        let arguments: [String: JSONValue]
        switch params?["arguments"] {
        case nil, .null: arguments = [:]
        case .object(let o): arguments = o
        default: throw RPCError(-32602, "arguments must be an object")
        }
        do {
            let result = try await tool.call(paths, MCPArguments(tool: tool, values: arguments))
            return [
                "content": [["type": "text", "text": .string(result.structured.compact)]],
                "structuredContent": result.structured,
                "isError": .bool(result.isError),
            ]
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = error as? DMXError ?? DMXError("internal", "\(name): \(error)")
            mcpLog("\(name): \(failure.code): \(failure.message)")
            var text = "error (\(failure.code)): \(failure.message)"
            if let hint = failure.hint { text += "\nhint: \(hint)" }
            return ["content": [["type": "text", "text": .string(text)]], "isError": true]
        }
    }

    private func errorMessage(id: JSONValue, _ error: RPCError) -> JSONValue {
        var body: [String: JSONValue] = ["code": .int(error.code), "message": .string(error.message)]
        if let data = error.data { body["data"] = data }
        return ["jsonrpc": "2.0", "id": id, "error": .object(body)]
    }
}

/// A JSON-RPC error reply.
struct RPCError: Error {
    let code: Int
    let message: String
    let data: JSONValue?

    init(_ code: Int, _ message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// Writes one message per line on stdout. Replies from concurrent calls never interleave.
private final class MessageWriter: Sendable {
    private let lock = NSLock()

    func send(_ message: JSONValue) {
        let data = message.compactData + Data("\n".utf8)
        lock.withLock {
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < buf.count {
                    let n = write(STDOUT_FILENO, buf.baseAddress! + offset, buf.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    // The client is gone; stdin will close too.
                    guard n > 0 else { return }
                    offset += n
                }
            }
        }
    }
}

/// Requests being served, by JSON-RPC id, so `notifications/cancelled` can stop them.
private final class RunningCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [JSONValue: (token: UInt64, task: Task<Void, Never>)] = [:]
    private var nextToken: UInt64 = 0

    func start(_ id: JSONValue, _ body: @escaping @Sendable () async -> Void) {
        lock.withLock {
            nextToken += 1
            let token = nextToken
            // Registered under the lock, so the task cannot finish and deregister before this.
            let task = Task { [self] in
                await body()
                lock.withLock {
                    if tasks[id]?.token == token { tasks[id] = nil }
                }
            }
            tasks[id] = (token, task)
        }
    }

    func cancel(_ id: JSONValue) {
        lock.withLock { tasks[id]?.task }?.cancel()
    }

    func cancelAll() {
        lock.withLock { tasks.values.map(\.task) }.forEach { $0.cancel() }
    }
}

enum Line: Sendable {
    case message(Data)
    case tooLong
}

/// Lines from a file descriptor, read on a thread of their own, without the newline. A line
/// longer than `maxLength` is dropped and reported as `.tooLong`. Splits on "\n" only:
/// JSON text may hold U+2028 and other characters Foundation's line reader also splits on.
func readLines(fd: Int32, maxLength: Int) -> AsyncStream<Line> {
    AsyncStream { continuation in
        let thread = Thread {
            var line = Data()
            var discarding = false
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { break }
                var start = 0
                while start < n {
                    let newline = buffer[start..<n].firstIndex(of: 0x0A)
                    let end = newline ?? n
                    if !discarding {
                        if line.count + (end - start) > maxLength {
                            discarding = true
                            line = Data()
                        } else {
                            line.append(contentsOf: buffer[start..<end])
                        }
                    }
                    guard newline != nil else { break }
                    continuation.yield(discarding ? .tooLong : .message(line))
                    line = Data()
                    discarding = false
                    start = end + 1
                }
            }
            if !line.isEmpty && !discarding { continuation.yield(.message(line)) }
            continuation.finish()
        }
        thread.name = "dmx.mcp.stdin"
        thread.start()
    }
}

func mcpLog(_ message: String) {
    FileHandle.standardError.write(Data("dmx mcp: \(message)\n".utf8))
}
