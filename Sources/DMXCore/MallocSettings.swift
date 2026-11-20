import Darwin
import Foundation

/// The processes that hold the VM (`dmx daemon`, `dmx boot`) run with libmalloc's space-efficient
/// mode. By default malloc keeps the pages of freed small blocks dirty: the daemon held about
/// 10 MB of them right after starting and 21 MB after a burst of HTTPS connections, with 1.4 MB
/// actually allocated, and `malloc_zone_pressure_relief` did not give them back. In this mode it
/// marks emptied pages reusable as they empty, so they leave the footprint (3.5–3.9 MB in the
/// same runs; docs/PLAN.md has the measurements). libmalloc reads the setting only when the
/// process starts, so the first start sets it and executes itself again, same pid, same
/// arguments and descriptors (launchd's sockets included).
public enum MallocSettings {
    public static let variable = "MallocSpaceEfficient"

    /// Returns only if the setting is in effect already, or the exec failed (then malloc keeps
    /// its defaults and nothing else changes).
    public static func reexecIfNeeded(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard environment[variable] == nil, let path = executablePath() else { return }
        setenv(variable, "1", 1)
        let argv = CommandLine.unsafeArgv
        argv.withMemoryRebound(to: UnsafeMutablePointer<CChar>?.self, capacity: Int(CommandLine.argc) + 1) {
            _ = execv(path, $0)
        }
        // Reached only if execv failed; the variable is left set so a child would not retry.
        FileHandle.standardError.write(Data("dmx: cannot restart with \(variable)=1: \(String(cString: strerror(errno)))\n".utf8))
    }

    static func executablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
