import Foundation

/// What to boot. `maxMemory` is a ceiling, not a reservation: the host only backs guest pages
/// once the guest touches them.
public struct MachineSpec: Sendable {
    public var cpus: Int
    public var maxMemory: UInt64
    public var kernelArgs: [String]
    /// Host directories the guest mounts at the same path (virtio-fs).
    public var shares: [Share]

    public init(cpus: Int? = nil, maxMemory: UInt64? = nil, kernelArgs: [String] = [], shares: [Share] = []) {
        let info = ProcessInfo.processInfo
        self.cpus = cpus ?? info.activeProcessorCount
        self.maxMemory = maxMemory ?? min(info.physicalMemory / 2, 8 << 30)
        self.kernelArgs = kernelArgs
        self.shares = shares
    }
}
