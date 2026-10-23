import Foundation
import Hypervisor

/// Guest physical memory map. Devices sit below RAM, like QEMU's `virt` board.
enum HVLayout {
    static let gicDistributor: UInt64 = 0x0800_0000
    /// Hypervisor.framework sizes the redistributor region for its maximum vCPU count (32 MB).
    static let gicRedistributors: UInt64 = 0x0c00_0000
    static let uart: UInt64 = 0x0900_0000
    static let uartSize: UInt64 = 0x1000
    /// virtio-mmio slots, `VirtioMMIO.size` apart, each with its own SPI.
    static let virtio: UInt64 = 0x0a00_0000
    static let ramBase: UInt64 = 0x4000_0000
    /// GIC interrupt numbers: SPIs start at 32. The device tree names SPIs by their offset.
    static let uartSPI: UInt32 = 1
    static let virtioSPI: UInt32 = 16
}

/// One Linux VM on dmx's own VMM over Hypervisor.framework. Guest RAM is an anonymous mapping
/// in this process, so dmx decides when freed guest memory goes back to macOS. A process can
/// hold only one such VM at a time.
public final class Machine: @unchecked Sendable {
    public enum Exit: Sendable {
        case guestStopped
        case failed(DMXError)
    }

    public let spec: MachineSpec

    private let ram: UnsafeMutableRawPointer
    private let ramSize: UInt64
    private let uart: PL011
    private let console: VirtioConsole
    let vsock = VirtioVsock()
    private var balloon: VirtioBalloon!
    /// Every MMIO device by guest address, UART first.
    private var bus: [(base: UInt64, size: UInt64, device: MMIODevice)] = []
    private var virtioSlots = 0
    private let lock = NSLock()
    private var vcpus: [VCPU] = []
    private var exit: Exit?
    private var waiters: [CheckedContinuation<Exit, Never>] = []
    /// File contents until they are copied into guest RAM, then released.
    private var kernel: Data, initramfs: Data
    private var redistributorBase: UInt64 = 0
    private var redistributorStride: UInt64 = 0

    public init(spec: MachineSpec, paths: Paths, console: FileHandle) throws {
        for file in [paths.kernel, paths.initramfs] where !FileManager.default.fileExists(atPath: file.path) {
            throw DMXError("guest_missing", "guest file not found: \(file.path)", hint: "run `make guest` to build the guest kernel and initramfs")
        }
        // Mapped, not read: clean file pages do not count toward this process's footprint.
        kernel = try Data(contentsOf: paths.kernel, options: .alwaysMapped)
        initramfs = try Data(contentsOf: paths.initramfs, options: .alwaysMapped)

        var resolved = spec
        resolved.cpus = min(max(spec.cpus, 1), ProcessInfo.processInfo.activeProcessorCount)
        resolved.maxMemory = max(spec.maxMemory, 256 << 20) & ~UInt64((2 << 20) - 1)
        self.spec = resolved
        ramSize = resolved.maxMemory

        guard hvSupported else {
            throw DMXError("virtualization_unsupported", "this Mac does not support Hypervisor.framework")
        }
        var config: hv_vm_config_t? = hv_vm_config_create()
        defer { config = nil }
        try check(hv_vm_create(config), "hv_vm_create")

        guard let memory = mmap(nil, Int(ramSize), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              memory != MAP_FAILED else {
            hv_vm_destroy()
            throw DMXError("vm_error", "cannot reserve \(formatSize(ramSize)) of guest memory")
        }
        ram = memory
        try check(hv_vm_map(ram, HVLayout.ramBase, Int(ramSize),
                            hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)), "hv_vm_map")

        let gic = hv_gic_config_create()
        var redistSize = 0
        hv_gic_get_redistributor_size(&redistSize)
        redistributorBase = HVLayout.gicRedistributors
        redistributorStride = UInt64(redistSize)
        try check(hv_gic_config_set_distributor_base(gic, HVLayout.gicDistributor), "hv_gic_config_set_distributor_base")
        try check(hv_gic_config_set_redistributor_base(gic, redistributorBase), "hv_gic_config_set_redistributor_base")
        try check(hv_gic_create(gic), "hv_gic_create")

        uart = PL011(output: console) { level in
            hv_gic_set_spi(32 + HVLayout.uartSPI, level)
        }
        bus.append((HVLayout.uart, HVLayout.uartSize, uart))
        self.console = VirtioConsole(output: console)
        let ram = GuestRAM(base: ram, guestBase: HVLayout.ramBase, size: ramSize)
        addVirtio(self.console, ram: ram)
        addVirtio(VirtioRNG(), ram: ram)
        addVirtio(vsock, ram: ram)
        balloon = VirtioBalloon(ram: ram) { [unowned self] address, length in self.release(address, length) }
        addVirtio(balloon, ram: ram)
    }

    private func addVirtio(_ device: VirtioDevice, ram: GuestRAM) {
        let slot = UInt32(virtioSlots)
        virtioSlots += 1
        let transport = VirtioMMIO(device: device, ram: ram) { level in
            hv_gic_set_spi(32 + HVLayout.virtioSPI + slot, level)
        }
        bus.append((HVLayout.virtio + UInt64(slot) * VirtioMMIO.size, VirtioMMIO.size, transport))
    }

    deinit {
        hv_vm_unmap(HVLayout.ramBase, Int(ramSize))
        munmap(ram, Int(ramSize))
        hv_vm_destroy()
    }

    /// Bytes typed on the host console, for the guest's hvc0.
    public func input(_ bytes: [UInt8]) { console.receive(Data(bytes)) }

    /// Free page reports so far: how many, and how many bytes the guest handed back.
    public var freePageReports: (reports: Int, bytes: UInt64) { balloon.stats }

    /// Gives a guest-physical range back to macOS. The guest promised not to touch it until it
    /// reuses the pages, which then fault in again as zeros. `MADV_FREE_REUSABLE` drops the pages
    /// from our footprint; it only takes hold on pages the guest dirtied if the stage-2 mapping is
    /// torn down around it.
    func release(_ address: UInt64, _ length: UInt64) {
        let page = UInt64(getpagesize())
        let start = alignUp(max(address, HVLayout.ramBase), page)
        let end = min(address + length, HVLayout.ramBase + ramSize) / page * page
        guard end > start else { return }
        let host = ram.advanced(by: Int(start - HVLayout.ramBase))
        let size = Int(end - start)
        hv_vm_unmap(start, size)
        madvise(host, size, MADV_FREE_REUSABLE)
        hv_vm_map(host, start, size, hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC))
    }

    /// Guest RAM lives in this process, so its footprint is the VM's cost, dmx included.
    /// The `footprint` tool leaves out pages the guest dirtied through `hv_vm_map`;
    /// `ri_phys_footprint` (what Activity Monitor shows) counts them.
    public func hostFootprint() -> HostFootprint? { HostFootprint.read(pid: getpid()) }

    public func start() throws {
        // Each vCPU must be created and run on its own thread; create them all first so the
        // device tree can list their MPIDRs, then release CPU 0. The rest wait for PSCI CPU_ON.
        let ready = DispatchSemaphore(value: 0)
        for index in 0..<spec.cpus {
            let vcpu = VCPU(index: index, machine: self)
            vcpus.append(vcpu)
            let thread = Thread { vcpu.main(ready: ready) }
            thread.name = "dmx.vcpu.\(index)"
            thread.stackSize = 1 << 20
            thread.start()
        }
        for _ in vcpus { ready.wait() }
        if let failed = vcpus.first(where: { $0.createError != nil }) {
            stop(.failed(DMXError("vm_error", "hv_vcpu_create: \(failed.createError!)")))
            throw DMXError("vm_error", "hv_vcpu_create: \(failed.createError!)")
        }

        let entry = try loadGuest()
        vcpus[0].powerOn(entry: entry.kernel, context: entry.fdt)
    }

    public func stop() async { stop(.guestStopped) }

    public func waitUntilStopped() async -> Exit {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exit {
                lock.unlock()
                continuation.resume(returning: exit)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func stop(_ result: Exit) {
        lock.lock()
        guard exit == nil else { lock.unlock(); return }
        exit = result
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for vcpu in vcpus { vcpu.halt() }
        vsock.closeAll()
        for waiter in pending { waiter.resume(returning: result) }
    }

    var stopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exit != nil
    }

    // MARK: Guest image

    /// Copies kernel, initramfs and device tree into guest RAM. Returns the kernel entry and the
    /// device tree address, which the boot protocol passes in x0.
    private func loadGuest() throws -> (kernel: UInt64, fdt: UInt64) {
        // arm64 Image header: text_offset at 8, image_size at 16, magic "ARM\x64" at 56.
        guard kernel.count > 64, kernel[56..<60] == Data("ARM\u{64}".utf8) else {
            throw DMXError("guest_invalid", "the kernel is not an arm64 Image", hint: "run `make guest`")
        }
        let textOffset = kernel.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
        let imageSize = kernel.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self) }
        let kernelAddr = HVLayout.ramBase + textOffset
        let initrdAddr = alignUp(kernelAddr + max(imageSize, UInt64(kernel.count)), 2 << 20)
        let fdtAddr = HVLayout.ramBase + ramSize - (2 << 20)
        guard initrdAddr + UInt64(initramfs.count) < fdtAddr else {
            throw DMXError("vm_error", "guest memory is too small for the kernel and initramfs")
        }
        copy(kernel, to: kernelAddr)
        copy(initramfs, to: initrdAddr)
        let fdt = deviceTree(initrd: initrdAddr..<(initrdAddr + UInt64(initramfs.count)))
        guard fdt.count < 2 << 20 else { throw DMXError("vm_error", "device tree too large") }
        copy(fdt, to: fdtAddr)
        kernel = Data()
        initramfs = Data()
        return (kernelAddr, fdtAddr)
    }

    private func copy(_ data: Data, to guestAddress: UInt64) {
        data.withUnsafeBytes { ram.advanced(by: Int(guestAddress - HVLayout.ramBase)).copyMemory(from: $0.baseAddress!, byteCount: data.count) }
    }

    static let baseKernelArgs = [
        "console=ttyAMA0", "earlycon=pl011,0x\(String(HVLayout.uart, radix: 16))", "swiotlb=noforce",
        // Hash tables the kernel sizes by the memory ceiling (14 MB at 8 GB, zeroed at boot).
        // Fixed sizes cost 1.6 MB; a million cached dentries would average 8 per chain.
        "dhash_entries=131072", "ihash_entries=65536", "thash_entries=16384",
        // Report free blocks from 512 KB (order 5 with 16K pages) instead of 16 MB, so little
        // freed memory stays behind in blocks too fragmented to report.
        "page_reporting.page_reporting_order=5",
        // Per-CPU free page lists are invisible to free page reporting and by default may hold
        // up to 38 MB per vCPU at 8 GB. This caps them at 60 pages (~1 MB) each.
        "sysctl.vm.percpu_pagelist_high_fraction=100000",
        // A transparent huge page is 32 MB with 16K pages, and Alpine's default is "always": one
        // byte touched per 32 MB of a 1 GB mapping cost 1 GB. Only programs that ask get them.
        "transparent_hugepage=madvise",
        // Slabs of at most 32 KB (order 1) instead of 128 KB. Every vCPU holds an active slab per
        // cache, so large slabs cost ~0.5 MB per vCPU at idle.
        "slub_max_order=1",
        // Map RAM in the kernel's linear map with 32 MB blocks instead of 16 KB pages: 4 MB of
        // page tables at 8 GB. The cost is that the linear alias of kernel text and rodata is not
        // write-protected (the kernel's own mapping of them still is).
        "rodata=noalias",
        // Atomic DMA pools (1 MB each per zone, preallocated) serve devices that are not
        // DMA-coherent; dmx's virtio devices are. The pools grow on demand if ever needed.
        "coherent_pool=64K",
    ]

    private func deviceTree(initrd: Range<UInt64>) -> Data {
        let gicPhandle: UInt32 = 1, clockPhandle: UInt32 = 2
        let level: UInt32 = 4  // IRQ_TYPE_LEVEL_HIGH
        func hi(_ v: UInt64) -> UInt32 { UInt32(v >> 32) }
        func lo(_ v: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: v) }
        var distSize = 0
        hv_gic_get_distributor_size(&distSize)

        var t = FDT()
        t.node("") { t in
            t.property("compatible", string: "linux,dummy-virt")
            t.property("#address-cells", u32: 2)
            t.property("#size-cells", u32: 2)
            t.property("interrupt-parent", u32: gicPhandle)

            t.node("chosen") { t in
                t.property("bootargs", string: (Self.baseKernelArgs + spec.kernelArgs).joined(separator: " "))
                t.property("stdout-path", string: "/pl011@\(String(HVLayout.uart, radix: 16))")
                t.property("linux,initrd-start", u64: initrd.lowerBound)
                t.property("linux,initrd-end", u64: initrd.upperBound)
            }
            t.node("memory@\(String(HVLayout.ramBase, radix: 16))") { t in
                t.property("device_type", string: "memory")
                t.property("reg", u32: hi(HVLayout.ramBase), lo(HVLayout.ramBase), hi(ramSize), lo(ramSize))
            }
            t.node("cpus") { t in
                t.property("#address-cells", u32: 1)
                t.property("#size-cells", u32: 0)
                for vcpu in vcpus {
                    t.node("cpu@\(vcpu.index)") { t in
                        t.property("device_type", string: "cpu")
                        t.property("compatible", string: "arm,arm-v8")
                        t.property("enable-method", string: "psci")
                        t.property("reg", u32: UInt32(vcpu.mpidr & 0xff_ffff))
                    }
                }
            }
            t.node("psci") { t in
                t.property("compatible", strings: ["arm,psci-0.2"])
                t.property("method", string: "hvc")
            }
            t.node("intc@\(String(HVLayout.gicDistributor, radix: 16))") { t in
                t.property("compatible", string: "arm,gic-v3")
                t.property("#interrupt-cells", u32: 3)
                t.property("interrupt-controller")
                let redistSize = redistributorStride * UInt64(vcpus.count)
                t.property("reg", u32: hi(HVLayout.gicDistributor), lo(HVLayout.gicDistributor), 0, UInt32(distSize),
                           hi(redistributorBase), lo(redistributorBase), hi(redistSize), lo(redistSize))
                t.property("phandle", u32: gicPhandle)
            }
            t.node("timer") { t in
                t.property("compatible", string: "arm,armv8-timer")
                // Secure, non-secure physical, virtual, hypervisor timer PPIs.
                t.property("interrupts", u32: 1, 13, level, 1, 14, level, 1, 11, level, 1, 10, level)
                t.property("always-on")
            }
            t.node("apb-pclk") { t in
                t.property("compatible", string: "fixed-clock")
                t.property("#clock-cells", u32: 0)
                t.property("clock-frequency", u32: 24_000_000)
                t.property("phandle", u32: clockPhandle)
            }
            t.node("pl011@\(String(HVLayout.uart, radix: 16))") { t in
                t.property("compatible", strings: ["arm,pl011", "arm,primecell"])
                t.property("reg", u32: hi(HVLayout.uart), lo(HVLayout.uart), 0, UInt32(HVLayout.uartSize))
                t.property("interrupts", u32: 0, HVLayout.uartSPI, level)
                t.property("clocks", u32: clockPhandle, clockPhandle)
                t.property("clock-names", strings: ["uartclk", "apb_pclk"])
            }
            for slot in 0..<virtioSlots {
                let base = HVLayout.virtio + UInt64(slot) * VirtioMMIO.size
                t.node("virtio_mmio@\(String(base, radix: 16))") { t in
                    t.property("compatible", string: "virtio,mmio")
                    t.property("reg", u32: hi(base), lo(base), 0, UInt32(VirtioMMIO.size))
                    t.property("interrupts", u32: 0, HVLayout.virtioSPI + UInt32(slot), level)
                    t.property("dma-coherent")
                }
            }
        }
        return t.finish()
    }

    // MARK: Exits

    func mmioRead(_ address: UInt64, size: Int) -> UInt64? {
        guard let entry = bus.first(where: { address >= $0.base && address - $0.base < $0.size }) else { return nil }
        return entry.device.read(offset: address - entry.base, size: size)
    }

    func mmioWrite(_ address: UInt64, size: Int, value: UInt64) -> Bool {
        guard let entry = bus.first(where: { address >= $0.base && address - $0.base < $0.size }) else { return false }
        entry.device.write(offset: address - entry.base, size: size, value: value)
        return true
    }

    func vcpu(mpidr: UInt64) -> VCPU? {
        vcpus.first { $0.mpidr & 0xff_ffff == mpidr & 0xff_ffff }
    }
}

/// `kern.hv_support`: whether this Mac can run Hypervisor.framework VMs at all.
var hvSupported: Bool {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_support", &value, &size, nil, 0) == 0 && value == 1
}

func alignUp(_ value: UInt64, _ alignment: UInt64) -> UInt64 {
    (value + alignment - 1) / alignment * alignment
}

func check(_ result: hv_return_t, _ what: String) throws {
    guard result == HV_SUCCESS else {
        throw DMXError("vm_error", "\(what) failed: \(String(format: "0x%08x", result))",
                       hint: result == HV_DENIED ? "build with `make build`, which signs dmx with the hypervisor entitlement" : nil)
    }
}
