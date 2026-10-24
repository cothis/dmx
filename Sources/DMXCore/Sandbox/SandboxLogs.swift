import Foundation

/// A container's logs, capped like `dmx_exec` output, with a summary of all of it.
public struct LogsResult: Codable, Sendable {
    public let container: String
    /// The sandbox, when the target was one.
    public let sandbox: String?
    public let stdout: String
    public let stderr: String
    public let stdoutBytes: Int
    public let stderrBytes: Int
    public let stdoutOmittedBytes: Int
    public let stderrOmittedBytes: Int
    public let summary: LogSummary
}

/// What the whole log holds, including what the caps left out: line counts and the lines that
/// look like errors. No model is involved; it is a pattern match.
public struct LogSummary: Codable, Sendable {
    public let stdoutLines: Int
    public let stderrLines: Int
    /// Lines matching `error`, `fatal`, `panic`, `exception`, `traceback`, `failed`, `denied`, ...
    public let errorLines: Int
    /// The first and last of them (up to 10 each), in order, cut at 240 bytes.
    public let errors: [LogLine]
}

public struct LogLine: Codable, Sendable {
    public let stream: String
    /// 1-based, counted in that stream.
    public let line: Int
    public let text: String
}

extension Sandboxes {
    /// Reads the logs of a sandbox's main process, or of any container by name or id.
    /// `since` is a duration back from now (`10m`), an RFC 3339 time or Unix seconds; `tail`
    /// keeps that many lines from the end (before the byte caps apply).
    public func logs(_ target: String, since: String?, tail: Int?, timestamps: Bool, maxOutputBytes: Int) async throws -> LogsResult {
        var sandbox: String?
        var container = target
        if (try? Self.checkName(target)) != nil, let c = try await find(target), let id = c["Id"]?.string {
            sandbox = target
            container = id
        }
        let inspect = try await docker.json("GET", "/containers/\(pathValue(container))/json", code: "docker_failed",
                                            notFound: DMXError("container_not_found", "no sandbox or container named \(target)",
                                                               hint: "run `dmx sandbox ls`, or `docker ps -a` for containers"))
        let tty = inspect["Config"]?["Tty"] == .bool(true)
        var query = "stdout=1&stderr=1&timestamps=\(timestamps ? 1 : 0)"
        if let tail {
            guard tail >= 0 else { throw DMXError("bad_argument", "tail must be 0 or more lines") }
            query += "&tail=\(tail)"
        }
        if let since { query += "&since=\(try Self.parseSince(since))" }
        let (status, stream, rest) = try await docker.start("GET", "/containers/\(pathValue(container))/logs?\(query)")
        defer { stream.close() }
        guard status == 200 else {
            throw DMXError("docker_failed", "dockerd answered \(status) for the logs of \(target): \(String(decoding: rest.prefix(300), as: UTF8.self))")
        }
        let reader = LogReader(limit: maxOutputBytes)
        try await onThread {
            var frames = DockerFrames()
            func feed(_ data: Data) {
                if tty { reader.append(1, data) } else { for (s, d) in frames.feed(data) { reader.append(s, d) } }
            }
            feed(rest)
            while true {
                let chunk = try stream.read()
                if chunk.isEmpty { return }
                feed(chunk)
            }
        }
        let (out, outOmitted) = reader.out.finish()
        let (err, errOmitted) = reader.err.finish()
        let name = String((inspect["Name"]?.string ?? container).drop { $0 == "/" })
        return LogsResult(container: name, sandbox: sandbox, stdout: out, stderr: err,
                          stdoutBytes: reader.out.total, stderrBytes: reader.err.total,
                          stdoutOmittedBytes: outOmitted, stderrOmittedBytes: errOmitted, summary: reader.summary())
    }

    /// Unix seconds for dockerd's `since`.
    static func parseSince(_ text: String) throws -> String {
        if let unix = Double(text) { return String(Int(unix)) }
        if let seconds = try? parseDuration(text) { return String(Int(Date().timeIntervalSince1970) - seconds) }
        let f = ISO8601DateFormatter()
        if let date = f.date(from: text) { return String(Int(date.timeIntervalSince1970)) }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: text) { return String(Int(date.timeIntervalSince1970)) }
        throw DMXError("bad_argument", "since must be a duration (10m), an RFC 3339 time or Unix seconds, not \"\(text)\"")
    }
}

/// Caps both streams and scans every line for the summary, in bounded memory.
final class LogReader: @unchecked Sendable {
    var out: OutputCapture
    var err: OutputCapture
    private var partial: [UInt8: Data] = [:]
    private var lines: [UInt8: Int] = [1: 0, 2: 0]
    private var errorCount = 0
    private var firstErrors: [LogLine] = []
    private var lastErrors: [LogLine] = []
    static let keep = 10

    init(limit: Int) {
        out = OutputCapture(limit: limit)
        err = OutputCapture(limit: limit)
    }

    func append(_ stream: UInt8, _ data: Data) {
        if stream == 2 { err.append(data) } else { out.append(data) }
        let s: UInt8 = stream == 2 ? 2 : 1
        var buffer = partial[s] ?? Data()
        var start = data.startIndex
        while let nl = data[start...].firstIndex(of: 10) {
            appendCapped(&buffer, data[start..<nl])
            line(s, buffer)
            buffer = Data()
            start = nl + 1
        }
        appendCapped(&buffer, data[start...])
        partial[s] = buffer
    }

    /// A line longer than 4 KB is judged on its first 4 KB.
    private func appendCapped(_ buffer: inout Data, _ bytes: Data.SubSequence) {
        let room = 4096 - buffer.count
        if room > 0 { buffer.append(bytes.prefix(room)) }
    }

    private func line(_ stream: UInt8, _ bytes: Data) {
        lines[stream, default: 0] += 1
        let text = String(decoding: bytes, as: UTF8.self)
        guard Self.looksLikeError(text) else { return }
        errorCount += 1
        var cut = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cut.utf8.count > 240 { cut = String(decoding: Array(cut.utf8.prefix(240)), as: UTF8.self) + "…" }
        let entry = LogLine(stream: stream == 2 ? "stderr" : "stdout", line: lines[stream]!, text: cut)
        if firstErrors.count < Self.keep { firstErrors.append(entry); return }
        lastErrors.append(entry)
        if lastErrors.count > Self.keep { lastErrors.removeFirst() }
    }

    func summary() -> LogSummary {
        for (s, rest) in partial where !rest.isEmpty { line(s, rest) }
        partial = [:]
        return LogSummary(stdoutLines: lines[1] ?? 0, stderrLines: lines[2] ?? 0, errorLines: errorCount, errors: firstErrors + lastErrors)
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"\b(error|errors|err|fatal|panic|panicked|exception|traceback|failed|failure|fail|denied|refused|cannot|can't|unable|segmentation fault|segfault|oom|killed|timed? ?out|abort(ed)?)\b"#,
        options: [.caseInsensitive])

    static func looksLikeError(_ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
