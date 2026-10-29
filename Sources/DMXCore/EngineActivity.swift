import Foundation

/// Passive lifecycle observation. Reading a receipt never activates launchd, claims the VM,
/// holds a daemon connection open, or samples guest memory. The daemon owns this file.
public struct EngineActivity: Codable, Sendable {
    public let pid: Int32
    public let version: String
    public let state: String
    public let containers: Int?
    public let reason: String?
    public let failure: Failure?

    public struct Failure: Codable, Sendable {
        public let code: String
        public let message: String
        public let hint: String?

        init(_ error: DMXError) {
            code = error.code; message = error.message; hint = error.hint
        }
    }

    static func publish(paths: Paths, version: String, state: String, containers: Int?,
                        reason: String? = nil, failure: DMXError? = nil) throws {
        try FileManager.default.createDirectory(at: paths.activityDirectory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let receipt = EngineActivity(pid: getpid(), version: version, state: state, containers: containers,
                                     reason: reason, failure: failure.map(Failure.init))
        try JSONEncoder().encode(receipt).write(to: paths.activity, options: [.atomic])
    }

    public static func read(paths: Paths) -> EngineActivity? {
        guard let data = try? Data(contentsOf: paths.activity) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Directory notifications survive the atomic rename of engine.json. Process-exit observation
/// also catches SIGKILL, which cannot publish a final receipt. No polling timer is needed.
@MainActor
public final class EngineActivityObserver {
    private var directory: DispatchSourceFileSystemObject?
    private var process: DispatchSourceProcess?
    private var pid: Int32?

    public init(paths: Paths, changed: @escaping @MainActor (EngineActivity) -> Void,
                exited: @escaping @MainActor (Int32) -> Void) throws {
        try FileManager.default.createDirectory(at: paths.activityDirectory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let fd = open(paths.activityDirectory.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw DMXError("menu_observer_failed", "cannot observe \(paths.activityDirectory.path)",
                           hint: "check that the dmx state directory is readable, then reopen dmx.app")
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                if let receipt = EngineActivity.read(paths: paths) { changed(receipt) }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        directory = source
        self.onExit = exited
    }

    private let onExit: @MainActor (Int32) -> Void

    public func watch(pid: Int32) {
        guard self.pid != pid else { return }
        process?.cancel()
        self.pid = pid
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            // A standalone helper is our child; launchd's daemon is not (ECHILD is harmless).
            // Reap only this exited PID, never change process-wide SIGCHLD handling.
            _ = waitpid(pid, nil, WNOHANG)
            MainActor.assumeIsolated { self?.onExit(pid) }
        }
        source.resume()
        process = source
    }

    public func close() {
        directory?.cancel(); directory = nil
        process?.cancel(); process = nil
    }
}
