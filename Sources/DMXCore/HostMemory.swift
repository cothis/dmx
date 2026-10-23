import Darwin

/// Host memory charged to a process: its physical footprint, the number Activity Monitor shows.
/// Guest RAM lives in the dmx process, so for dmx this is what the VM costs.
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
