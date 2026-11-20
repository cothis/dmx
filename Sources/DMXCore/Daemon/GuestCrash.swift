import Foundation

/// A VM that died under the daemon: the guest kernel reset itself (a panic, with `panic=-1`, or a
/// reboot inside the guest) or the VMM failed. The daemon keeps the console tail of that boot in
/// `logs/guest-crash.log` and, if containers were running, boots a new VM after a backoff, so
/// dockerd brings back those whose restart policy says so (`always`, `unless-stopped`) as it does
/// after any unclean stop; `no` ones stay exited. A guest that powers off (`poweroff`) is not a crash.
struct GuestCrashes {
    /// The first reboot waits this long, each crash in a row doubles it, up to `maxDelay`.
    static let firstDelay: Duration = .seconds(1)
    static let maxDelay: Duration = .seconds(60)
    /// A VM that ran this long before crashing starts the count again.
    static let stableAfter: Duration = .seconds(300)
    /// Of the crashed boot's console output, what is kept: enough for a panic's trace.
    static let tailBytes = 32 << 10
    /// guest-crash.log, with .1 and .2: a few dozen crashes.
    static let logLimit = 256 << 10

    /// Crashes in a row, each after less than `stableAfter` of uptime.
    private(set) var streak = 0
    private(set) var last: (at: Date, reason: String)?

    /// Counts a crash after `uptime` and returns how long to wait before the next boot.
    mutating func crashed(reason: String, uptime: Duration?, at: Date = Date()) -> Duration {
        if let uptime, uptime >= Self.stableAfter { streak = 0 }
        streak += 1
        last = (at, reason)
        return Self.delay(streak: streak)
    }

    static func delay(streak: Int) -> Duration {
        let doublings = min(max(streak - 1, 0), 16)
        return min(firstDelay * (1 << doublings), maxDelay)
    }

    /// The console output since the last boot marker the daemon writes, at most `tailBytes`.
    static func consoleTail(_ consoleLog: URL, limit: Int = tailBytes) -> String {
        // The marker can be in the rotation before; reading both keeps a boot that straddles them.
        var data = Data()
        for url in [URL(fileURLWithPath: consoleLog.path + ".1"), consoleLog] {
            data += readTail(url, limit: limit * 2) ?? Data()
        }
        var text = String(decoding: data, as: UTF8.self)
        if let marker = text.range(of: bootMarker, options: .backwards) {
            text = String(text[marker.lowerBound...])
        }
        if text.utf8.count > limit {
            text = String(decoding: Data(text.utf8).suffix(limit), as: UTF8.self)
        }
        return text
    }

    static let bootMarker = "\n--- dmx VM boot "

    /// One record in guest-crash.log: when, why, and the console tail.
    static func record(reason: String, uptime: Duration?, at: Date = Date(), consoleLog: URL) -> Data {
        let up = uptime.map { String(format: ", up %.1f s", seconds($0)) } ?? ""
        var tail = consoleTail(consoleLog)
        if !tail.hasSuffix("\n") { tail += "\n" }
        return Data("=== guest crash \(ISO8601DateFormatter().string(from: at)): \(reason)\(up) ===\n\(tail)\n".utf8)
    }

    private static func readTail(_ url: URL, limit: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let start = max(0, Int(info.st_size) - limit)
        var out = Data(count: Int(info.st_size) - start)
        var got = 0
        while got < out.count {
            let n = out.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: got), $0.count - got, off_t(start + got)) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            got += n
        }
        return out.prefix(got)
    }
}

/// The last guest crash in `dmx status`.
public struct GuestCrashStatus: Codable, Sendable {
    public let secondsAgo: Int
    /// `kernel reset (panic or reboot)` or the VMM's error.
    public let reason: String
    /// Crashes in a row, each soon after its boot.
    public let streak: Int
    /// Seconds until the next VM boots, while a reboot is pending.
    public let rebootInS: Int?
    /// guest-crash.log: the console tail of each crashed boot.
    public let log: String
}
