import Foundation

/// What to boot. `maxMemory` is a ceiling, not a reservation: the host only backs guest pages
/// once the guest touches them.
public struct MachineSpec: Sendable {
    public var cpus: Int
    public var maxMemory: UInt64
    public var kernelArgs: [String]
    /// The data disk, `/dev/vda` in the guest, mounted at /var/lib. None when nil.
    public var dataDisk: DataDisk?

    public init(cpus: Int? = nil, maxMemory: UInt64? = nil, kernelArgs: [String] = []) {
        let info = ProcessInfo.processInfo
        self.cpus = cpus ?? info.activeProcessorCount
        self.maxMemory = maxMemory ?? min(info.physicalMemory / 2, 8 << 30)
        self.kernelArgs = kernelArgs
    }
}
