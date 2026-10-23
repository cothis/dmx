import Darwin

/// Host memory charged to one VM. Virtualization.framework runs each VM in an XPC service
/// process (`com.apple.Virtualization.VirtualMachine`) that launchd starts, so it is not our
/// child. Guest RAM lives in that process, and its physical footprint is what the user pays.
public struct HostFootprint: Encodable, Sendable {
    public let pid: Int32
    public let footprint: UInt64
    public let peakFootprint: UInt64

    public var footprintMb: Int { Int(footprint >> 20) }
    public var peakFootprintMb: Int { Int(peakFootprint >> 20) }

    enum CodingKeys: String, CodingKey { case pid, footprintMb, peakFootprintMb }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pid, forKey: .pid)
        try c.encode(footprintMb, forKey: .footprintMb)
        try c.encode(peakFootprintMb, forKey: .peakFootprintMb)
    }

    /// Reads the same number `footprint <pid>` prints. Works for any process of the same user.
    public static func read(pid: Int32) -> HostFootprint? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        return HostFootprint(pid: pid, footprint: info.ri_phys_footprint, peakFootprint: info.ri_lifetime_max_phys_footprint)
    }
}

private let vmServiceName = "com.apple.Virtualization.VirtualMachine"

/// PIDs of every running VM service process, ours or not (other apps run VMs too).
func vmServicePids() -> Set<Int32> {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard filled > 0 else { return [] }
    var result: Set<Int32> = []
    // proc_name truncates to 32 bytes, shorter than the service name, so compare the path.
    var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
    for pid in pids.prefix(Int(filled)) where pid > 0 {
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0 else { continue }
        if String(decoding: path.prefix(Int(length)), as: UTF8.self).hasSuffix("/" + vmServiceName) { result.insert(pid) }
    }
    return result
}

/// launchd records which process a service was started for. This libsystem call is not in a
/// public header but has been stable for years; Activity Monitor relies on the same data.
private let responsiblePid: (@convention(c) (pid_t) -> pid_t)? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
}()

/// The VM service process started for this process. `before` holds the VM service PIDs seen
/// before our VM was created, used only if the responsible-pid lookup is unavailable.
func ownVMServicePid(before: Set<Int32>) -> Int32? {
    let now = vmServicePids()
    let me = getpid()
    let candidates: Set<Int32>
    if let responsiblePid {
        candidates = now.filter { responsiblePid($0) == me }
    } else {
        candidates = now.subtracting(before)
    }
    return candidates.count == 1 ? candidates.first : nil
}
