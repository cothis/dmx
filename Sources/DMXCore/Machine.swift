import Foundation
import Virtualization

/// What to boot. `maxMemory` is a ceiling, not a reservation: the host only backs
/// guest pages once they are touched, and the balloon device gives them back.
public struct MachineSpec: Sendable {
    public var cpus: Int
    public var maxMemory: UInt64
    public var kernelArgs: [String]

    public init(cpus: Int? = nil, maxMemory: UInt64? = nil, kernelArgs: [String] = []) {
        let info = ProcessInfo.processInfo
        self.cpus = cpus ?? info.activeProcessorCount
        self.maxMemory = maxMemory ?? min(info.physicalMemory / 2, 8 << 30)
        self.kernelArgs = kernelArgs
    }
}

/// Byte streams wired to the guest's hvc0 console.
public struct Console: Sendable {
    /// Bytes written here arrive on the guest console's input.
    public let toGuest: FileHandle
    /// Guest console output is written here.
    public let fromGuest: FileHandle
    let guestReads: FileHandle

    public init(fromGuest: FileHandle) {
        let pipe = Pipe()
        toGuest = pipe.fileHandleForWriting
        guestReads = pipe.fileHandleForReading
        self.fromGuest = fromGuest
    }
}

/// One Linux VM. Lives on the main actor because Virtualization.framework
/// objects are bound to the queue they were created on.
@MainActor
public final class Machine: NSObject {
    public enum Exit: Sendable {
        case guestStopped
        case failed(DMXError)
    }

    public let spec: MachineSpec
    private let vm: VZVirtualMachine
    private var exit: Exit?
    private let servicePidsBefore: Set<Int32>
    private var servicePid: Int32?
    private var waiters: [CheckedContinuation<Exit, Never>] = []

    /// `swiotlb=noforce`: by default the kernel zeroes a bounce buffer sized to the ceiling
    /// (64 MB at 8 GB), which the host then backs. No virtio device here negotiates
    /// VIRTIO_F_ACCESS_PLATFORM, so virtio never bounces and the buffer is never used.
    static let baseKernelArgs = ["console=hvc0", "swiotlb=noforce"]

    public init(spec: MachineSpec, paths: Paths, console: Console) throws {
        for file in [paths.kernel, paths.initramfs] where !FileManager.default.fileExists(atPath: file.path) {
            throw DMXError("guest_missing", "guest file not found: \(file.path)", hint: "run `make guest` to build the guest kernel and initramfs")
        }
        guard VZVirtualMachine.isSupported else {
            throw DMXError("virtualization_unsupported", "this Mac does not support Virtualization.framework")
        }

        let cpus = min(max(spec.cpus, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                       VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let memory = min(max(spec.maxMemory & ~UInt64((1 << 20) - 1), VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                         VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        var resolved = spec
        resolved.cpus = cpus
        resolved.maxMemory = memory
        self.spec = resolved

        let boot = VZLinuxBootLoader(kernelURL: paths.kernel)
        boot.initialRamdiskURL = paths.initramfs
        boot.commandLine = (Self.baseKernelArgs + spec.kernelArgs).joined(separator: " ")

        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: console.guestReads,
            fileHandleForWriting: console.fromGuest
        )

        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()

        let config = VZVirtualMachineConfiguration()
        config.bootLoader = boot
        config.cpuCount = cpus
        config.memorySize = memory
        config.serialPorts = [serial]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.networkDevices = [net]

        do {
            try config.validate()
        } catch {
            throw Self.translate(error)
        }
        servicePidsBefore = vmServicePids()
        vm = VZVirtualMachine(configuration: config)
        super.init()
        vm.delegate = self
    }

    public func start() async throws {
        do {
            try await vm.start()
        } catch {
            throw Self.translate(error)
        }
    }

    /// Hard stop, like pulling the power cord. The guest has no disk to corrupt yet.
    /// For a clean stop, ask the agent: `AgentConnection.shutdown()`.
    public func stop() async {
        guard vm.canStop else { return }
        try? await vm.stop()
        finish(.guestStopped)
    }

    /// Physical footprint of the process that holds this VM's memory, or nil before `start()`
    /// or if that process cannot be identified.
    public func hostFootprint() -> HostFootprint? {
        if servicePid == nil { servicePid = ownVMServicePid(before: servicePidsBefore) }
        return servicePid.flatMap(HostFootprint.read)
    }

    /// Memory the guest may keep; the balloon holds the rest. Starts at the ceiling, and the
    /// guest inflates or deflates toward it within about a second. On macOS 26 the host does
    /// not release ballooned pages (see docs/PLAN.md), so this limits the guest, nothing more.
    public var memoryTarget: UInt64 {
        get { balloon?.targetVirtualMachineMemorySize ?? spec.maxMemory }
        set {
            let target = min(max(newValue, 1 << 20), spec.maxMemory) & ~UInt64((1 << 20) - 1)
            balloon?.targetVirtualMachineMemorySize = target
        }
    }

    private var balloon: VZVirtioTraditionalMemoryBalloonDevice? {
        vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice
    }

    var socketDevice: VZVirtioSocketDevice? { vm.socketDevices.first as? VZVirtioSocketDevice }
    var stopped: Exit? { exit }

    public func waitUntilStopped() async -> Exit {
        if let exit { return exit }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func finish(_ result: Exit) {
        guard exit == nil else { return }
        exit = result
        for waiter in waiters { waiter.resume(returning: result) }
        waiters.removeAll()
    }

    nonisolated private static func translate(_ error: Error) -> DMXError {
        let message = (error as NSError).localizedDescription
        if message.contains("entitlement") {
            return DMXError("missing_entitlement", message, hint: "build with `make build`, which signs dmx with the virtualization entitlement")
        }
        return DMXError("vm_error", message)
    }
}

extension Machine: VZVirtualMachineDelegate {
    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { finish(.guestStopped) }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let failure = Self.translate(error)
        MainActor.assumeIsolated { finish(.failed(failure)) }
    }
}
