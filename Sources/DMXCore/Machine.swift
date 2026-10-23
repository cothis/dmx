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
    private var waiters: [CheckedContinuation<Exit, Never>] = []

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
        boot.commandLine = (["console=hvc0"] + spec.kernelArgs).joined(separator: " ")

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
    public func stop() async {
        guard vm.canStop else { return }
        try? await vm.stop()
        finish(.guestStopped)
    }

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
