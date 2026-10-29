import Foundation

/// A single owner's diagnostic stream. Synchronous writes bound both disk use and memory:
/// no output queue, timer or polling. A daemon owns these files under its existing home lock.
final class RotatingLog: @unchecked Sendable {
    static let limit = 1 << 20
    private let lock = NSLock()
    private let url: URL
    private let limit: Int
    private var fd: Int32 = -1
    private var size = 0

    init(url: URL, limit: Int = RotatingLog.limit) throws {
        precondition(limit > 0)
        self.url = url
        self.limit = limit
        // Also bound files left by older versions, without loading an unlimited old log.
        for suffix in [".2", ".1", ""] {
            let path = url.path + suffix
            let file = try Self.open(path, create: suffix.isEmpty)
            if file >= 0 {
                defer { Darwin.close(file) }
                var info = stat()
                guard fstat(file, &info) == 0 else { throw Self.error(path) }
                if info.st_size > limit {
                    var tail = [UInt8](repeating: 0, count: limit)
                    var got = 0
                    while got < limit {
                        let n = tail.withUnsafeMutableBytes {
                            pread(file, $0.baseAddress!.advanced(by: got), limit - got, info.st_size - off_t(limit) + off_t(got))
                        }
                        if n < 0, errno == EINTR { continue }
                        guard n > 0 else { throw Self.error(path) }
                        got += n
                    }
                    guard ftruncate(file, 0) == 0 else { throw Self.error(path) }
                    try tail.withUnsafeBytes { try Self.write(file, $0, path: path) }
                }
            }
        }
        do { try reopen() }
        catch {
            if fd >= 0 { Darwin.close(fd); fd = -1 }
            throw error
        }
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    /// Logging failure must not crash the VM. On a full/unwritable disk, drop diagnostics;
    /// the next write retries opening the file, without building an in-memory backlog.
    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        do {
            if fd < 0 { try reopen() }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    if size == limit { try rotate() }
                    let count = min(limit - size, bytes.count - offset)
                    try Self.write(fd, UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + count)]), path: url.path)
                    size += count
                    offset += count
                }
            }
        } catch {
            if fd >= 0 { Darwin.close(fd); fd = -1 }
        }
    }

    private func reopen() throws {
        fd = try Self.open(url.path, create: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Self.error(url.path) }
        size = Int(info.st_size)
        // Another program may have enlarged it since startup. Never append beyond the cap.
        if size > limit { try rotate() }
    }

    private func rotate() throws {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        // rename/unlink never follow links at the destination. open() below rejects links.
        if unlink(url.path + ".2") != 0, errno != ENOENT { throw Self.error(url.path + ".2") }
        if rename(url.path + ".1", url.path + ".2") != 0, errno != ENOENT { throw Self.error(url.path + ".1") }
        guard rename(url.path, url.path + ".1") == 0 else { throw Self.error(url.path) }
        try reopen()
    }

    private static func open(_ path: String, create: Bool) throws -> Int32 {
        let fd = Darwin.open(path, O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (create ? O_CREAT : 0), 0o600)
        if fd < 0, !create, errno == ENOENT { return -1 }
        guard fd >= 0 else { throw error(path) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            Darwin.close(fd)
            throw DMXError("log_invalid", "diagnostic log must be a regular file with one link: \(path)",
                           hint: "move this log aside, then run `dmx stop` followed by `dmx start`")
        }
        return fd
    }

    private static func write(_ fd: Int32, _ bytes: UnsafeRawBufferPointer, path: String) throws {
        var offset = 0
        while offset < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw error(path) }
            offset += n
        }
    }

    private static func error(_ path: String) -> DMXError {
        DMXError("log_unwritable", "cannot write diagnostic log \(path): \(String(cString: strerror(errno)))",
                 hint: "repair the log directory and free space, then run `dmx stop` followed by `dmx start`")
    }
}

/// Both UART and virtio-console use the same synchronized bounded sink in daemon mode.
/// Interactive boot and selftest retain their original file/pipe output.
enum ConsoleOutput {
    case file(FileHandle)
    case log(RotatingLog?)

    func write(_ data: Data) {
        switch self {
        case .file(let file): file.write(data)
        case .log(let log): log?.append(data)
        }
    }
}

/// Process-wide diagnostics: a daemon installs its bounded sink before starting any VM.
/// Foreground debugging retains stderr; detached/launchd daemons tee to /dev/null.
enum Diagnostics {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var log: RotatingLog?
    }
    private static let state = State()

    static func install(_ log: RotatingLog?) {
        state.lock.lock()
        state.log = log
        state.lock.unlock()
    }

    static func write(_ data: Data) {
        state.lock.lock()
        let log = state.log
        state.lock.unlock()
        log?.append(data)
        FileHandle.standardError.write(data)
    }

    /// Older launchd jobs opened daemon.log themselves. Release those descriptors before
    /// rotation, so a renamed/deleted old inode cannot retain unbounded disk space.
    static func detachLegacyLog(_ url: URL) {
        var target = stat()
        // Resolve metadata only: an older launchd job may already have followed a symlink.
        guard stat(url.path, &target) == 0 else { return }
        for fd in [STDOUT_FILENO, STDERR_FILENO] {
            var info = stat()
            if fstat(fd, &info) == 0, info.st_dev == target.st_dev, info.st_ino == target.st_ino {
                let null = Darwin.open("/dev/null", O_WRONLY | O_CLOEXEC)
                if null >= 0 { _ = dup2(null, fd); Darwin.close(null) }
            }
        }
    }
}

/// Disabled sinks are retried once per VM boot, even when clients keep the daemon alive.
@MainActor
final class DaemonLogs {
    private let paths: Paths
    private(set) var daemon: RotatingLog?
    private(set) var console: RotatingLog?
    private var failures: [String: String] = [:]

    var warnings: [String] { [paths.daemonLog, paths.consoleLog].compactMap { failures[$0.path] } }

    init(paths: Paths) {
        self.paths = paths
        retryDisabled()
    }

    func retryDisabled() {
        if daemon == nil { daemon = make(paths.daemonLog) }
        if console == nil { console = make(paths.consoleLog) }
        Diagnostics.install(daemon)
    }

    private func make(_ url: URL) -> RotatingLog? {
        do {
            try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
            let log = try RotatingLog(url: url)
            failures[url.path] = nil
            return log
        } catch {
            let error = error as? DMXError ?? DMXError("log_unwritable", error.localizedDescription,
                hint: "repair the log directory and free space, then run `dmx stop` followed by `dmx start`")
            failures[url.path] = "\(error.code): \(error.message); \(error.hint ?? "")"
            return nil
        }
    }
}
