import Foundation
import Hypervisor

/// One virtual CPU and the thread that runs it. Hypervisor.framework requires every call on a
/// vCPU to come from the thread that created it, except `hv_vcpus_exit`.
final class VCPU: @unchecked Sendable {
    let index: Int
    private unowned let machine: Machine
    private(set) var mpidr: UInt64 = 0
    private(set) var createError: String?
    private var id: hv_vcpu_t = 0
    private var exitInfo: UnsafeMutablePointer<hv_vcpu_exit_t>!

    /// EL1 state as `hv_vcpu_create` left it, restored on every power-on: a CPU turned off and on
    /// again must enter the kernel with the MMU off, not with its previous life's translation.
    /// ACTLR_EL1 (only its EnTSO bit is visible) too: the guest kernel writes it only when the
    /// thread it switches to wants another memory model, so it must start in the default one.
    private static let resetRegisters: [hv_sys_reg_t] = [
        HV_SYS_REG_ACTLR_EL1,
        HV_SYS_REG_SCTLR_EL1, HV_SYS_REG_TCR_EL1, HV_SYS_REG_TTBR0_EL1, HV_SYS_REG_TTBR1_EL1,
        HV_SYS_REG_MAIR_EL1, HV_SYS_REG_AMAIR_EL1, HV_SYS_REG_VBAR_EL1, HV_SYS_REG_CPACR_EL1,
        HV_SYS_REG_CONTEXTIDR_EL1, HV_SYS_REG_TPIDR_EL1, HV_SYS_REG_TPIDR_EL0, HV_SYS_REG_TPIDRRO_EL0,
        HV_SYS_REG_SP_EL0, HV_SYS_REG_SP_EL1, HV_SYS_REG_ELR_EL1, HV_SYS_REG_SPSR_EL1,
        HV_SYS_REG_ESR_EL1, HV_SYS_REG_FAR_EL1, HV_SYS_REG_PAR_EL1, HV_SYS_REG_AFSR0_EL1,
        HV_SYS_REG_AFSR1_EL1, HV_SYS_REG_MDSCR_EL1, HV_SYS_REG_CNTKCTL_EL1, HV_SYS_REG_CNTV_CTL_EL0,
        HV_SYS_REG_CNTV_CVAL_EL0, HV_SYS_REG_CSSELR_EL1,
    ]
    private var resetValues: [(hv_sys_reg_t, UInt64)] = []

    private let cond = NSCondition()
    private var start: (entry: UInt64, context: UInt64)?
    private var on = false
    private var halted = false
    private var woken = false

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    init(index: Int, machine: Machine) {
        self.index = index
        self.machine = machine
    }

    // MARK: Control from other threads

    /// PSCI CPU_ON (or the boot CPU's first start). False if the CPU is already on.
    @discardableResult
    func powerOn(entry: UInt64, context: UInt64) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        guard !on, start == nil else { return false }
        start = (entry, context)
        cond.broadcast()
        return true
    }

    var isOn: Bool {
        cond.lock()
        defer { cond.unlock() }
        return on || start != nil
    }

    /// Ends the vCPU thread: kicks it out of `hv_vcpu_run` and out of any wait.
    func halt() {
        cond.lock()
        halted = true
        cond.broadcast()
        cond.unlock()
        var target = id
        hv_vcpus_exit(&target, 1)
    }

    /// Ends a WFI wait early, because an interrupt may now be pending.
    func wake() {
        cond.lock()
        woken = true
        cond.broadcast()
        cond.unlock()
    }

    // MARK: vCPU thread

    func main(ready: DispatchSemaphore) {
        var exit: UnsafeMutablePointer<hv_vcpu_exit_t>?
        let created = hv_vcpu_create(&id, &exit, nil)
        guard created == HV_SUCCESS, let exit else {
            createError = String(format: "0x%08x", created)
            ready.signal()
            return
        }
        exitInfo = exit
        // Hypervisor.framework leaves MPIDR at 0 for every vCPU; give each its own affinity.
        hv_vcpu_set_sys_reg(id, HV_SYS_REG_MPIDR_EL1, UInt64(index))
        hv_vcpu_get_sys_reg(id, HV_SYS_REG_MPIDR_EL1, &mpidr)
        resetValues = Self.resetRegisters.map { r in
            var value: UInt64 = 0
            hv_vcpu_get_sys_reg(id, r, &value)
            return (r, value)
        }
        ready.signal()

        while let (entry, context) = waitForPowerOn() {
            for (r, value) in resetValues { hv_vcpu_set_sys_reg(id, r, value) }
            hv_vcpu_set_vtimer_mask(id, false)
            setReg(HV_REG_PC, entry)
            setReg(HV_REG_CPSR, 0x3c5)  // EL1h with D, A, I, F masked
            for n in 0..<4 { setX(n, 0) }
            setX(0, context)
            run()
            cond.lock()
            on = false
            cond.unlock()
        }
        hv_vcpu_destroy(id)
    }

    private func waitForPowerOn() -> (UInt64, UInt64)? {
        cond.lock()
        defer { cond.unlock() }
        while start == nil && !halted { cond.wait() }
        guard !halted, let next = start else { return nil }
        start = nil
        on = true
        return next
    }

    /// Runs until the guest turns this CPU off or the machine stops.
    private func run() {
        while !isHalted {
            let result = hv_vcpu_run(id)
            guard result == HV_SUCCESS else {
                return fail("hv_vcpu_run failed: \(String(format: "0x%08x", result))")
            }
            switch exitInfo.pointee.reason {
            case HV_EXIT_REASON_CANCELED:
                continue
            case HV_EXIT_REASON_VTIMER_ACTIVATED:
                // The in-kernel GIC delivers the timer PPI; unmask once the guest has rearmed it.
                hv_vcpu_set_vtimer_mask(id, false)
            case HV_EXIT_REASON_EXCEPTION:
                if !handleException() { return }
            default:
                return fail("unexpected exit reason \(exitInfo.pointee.reason)")
            }
        }
    }

    private var isHalted: Bool {
        cond.lock()
        defer { cond.unlock() }
        return halted
    }

    /// Returns false when this CPU should stop running.
    private func handleException() -> Bool {
        let syndrome = exitInfo.pointee.exception.syndrome
        let ec = (syndrome >> 26) & 0x3f
        switch ec {
        case 0x24:  // data abort from a lower EL: MMIO
            guard syndrome & (1 << 24) != 0 else {
                fail("data abort without a valid syndrome at 0x\(String(exitInfo.pointee.exception.physical_address, radix: 16))")
                return false
            }
            let address = exitInfo.pointee.exception.physical_address
            let size = 1 << Int((syndrome >> 22) & 3)
            let register = Int((syndrome >> 16) & 0x1f)
            let mask: UInt64 = size == 8 ? ~0 : (1 << (UInt64(size) * 8)) - 1
            if syndrome & (1 << 6) != 0 {
                let value = register == 31 ? 0 : x(register) & mask
                if !machine.mmioWrite(address, size: size, value: value) {
                    debug("unhandled MMIO write of \(size) bytes at 0x\(String(address, radix: 16))")
                }
            } else {
                let value = machine.mmioRead(address, size: size) ?? {
                    debug("unhandled MMIO read of \(size) bytes at 0x\(String(address, radix: 16))")
                    return 0
                }()
                if register != 31 { setX(register, value & mask) }
            }
            advance()
        case 0x16:  // HVC; the return address is already past the instruction
            return psci()
        case 0x17:  // SMC
            advance()
            return psci()
        case 0x01:  // WFI or WFE
            advance()
            waitForInterrupt()
        case 0x18:  // MSR/MRS to a trapped system register: reads as zero, writes are ignored
            let isRead = syndrome & 1 != 0
            let register = Int((syndrome >> 5) & 0x1f)
            if isRead && register != 31 { setX(register, 0) }
            // OSLAR_EL1 and OSDLR_EL1 (the debug OS lock) are expected at boot; report anything else.
            let osLock = syndrome & 0x3ffc1e == 0x280406 || syndrome & 0x3ffc1e == 0x280400
            if !osLock { debug("trapped system register access, syndrome 0x\(String(syndrome, radix: 16))") }
            advance()
        default:
            fail("unhandled exception class 0x\(String(ec, radix: 16)) at pc 0x\(String(reg(HV_REG_PC), radix: 16)), syndrome 0x\(String(syndrome, radix: 16))")
            return false
        }
        return true
    }

    /// PSCI 0.2 calls, function id in x0, result in x0. Returns false after CPU_OFF.
    private func psci() -> Bool {
        let notSupported = UInt64(bitPattern: -1), invalid = UInt64(bitPattern: -2), alreadyOn = UInt64(bitPattern: -4)
        switch UInt32(truncatingIfNeeded: x(0)) {
        case 0x8400_0000:  // PSCI_VERSION
            setX(0, 2)
        case 0x8400_0002:  // CPU_OFF
            return false
        case 0x8400_0003, 0xc400_0003:  // CPU_ON
            guard let target = machine.vcpu(mpidr: x(1)) else { setX(0, invalid); break }
            setX(0, target.powerOn(entry: x(2), context: x(3)) ? 0 : alreadyOn)
        case 0x8400_0004, 0xc400_0004:  // AFFINITY_INFO
            guard let target = machine.vcpu(mpidr: x(1)) else { setX(0, invalid); break }
            setX(0, target.isOn ? 0 : 1)
        case 0x8400_0006:  // MIGRATE_INFO_TYPE: no trusted OS to migrate
            setX(0, 2)
        case 0x8400_0001, 0xc400_0001:  // CPU_SUSPEND: like WFI
            waitForInterrupt()
            setX(0, 0)
        case 0x8400_0008, 0x8400_0009:  // SYSTEM_OFF, SYSTEM_RESET
            machine.stop(.guestStopped)
            return false
        default:
            setX(0, notSupported)
        }
        return true
    }

    /// Sleeps until the guest's virtual timer fires or something wakes this CPU. The in-kernel
    /// GIC does not tell us about interrupts sent between vCPUs, so the wait is capped.
    private func waitForInterrupt() {
        var deadline = DispatchTime.now() + .milliseconds(1)
        var ctl: UInt64 = 0, cval: UInt64 = 0, offset: UInt64 = 0
        hv_vcpu_get_sys_reg(id, HV_SYS_REG_CNTV_CTL_EL0, &ctl)
        if ctl & 1 != 0 && ctl & 2 == 0 {  // enabled and not masked
            hv_vcpu_get_sys_reg(id, HV_SYS_REG_CNTV_CVAL_EL0, &cval)
            hv_vcpu_get_vtimer_offset(id, &offset)
            let now = mach_absolute_time() &- offset
            if cval <= now { return }
            let ns = (cval - now) * UInt64(Self.timebase.numer) / UInt64(Self.timebase.denom)
            deadline = min(deadline, DispatchTime.now() + .nanoseconds(Int(min(ns, 1_000_000_000))))
        }
        cond.lock()
        defer { cond.unlock() }
        while !woken && !halted && DispatchTime.now() < deadline {
            let remaining = Double(deadline.uptimeNanoseconds - min(deadline.uptimeNanoseconds, DispatchTime.now().uptimeNanoseconds)) / 1e9
            _ = cond.wait(until: Date(timeIntervalSinceNow: remaining))
        }
        woken = false
    }

    private func fail(_ message: String) {
        machine.stop(.failed(DMXError("vm_error", "vcpu \(index): \(message)")))
    }

    private func debug(_ message: String) {
        Diagnostics.write(Data("dmx-vmm: vcpu \(index): \(message)\n".utf8))
    }

    // MARK: Registers

    private func reg(_ r: hv_reg_t) -> UInt64 {
        var value: UInt64 = 0
        hv_vcpu_get_reg(id, r, &value)
        return value
    }

    private func setReg(_ r: hv_reg_t, _ value: UInt64) { hv_vcpu_set_reg(id, r, value) }

    private func x(_ n: Int) -> UInt64 { reg(hv_reg_t(rawValue: HV_REG_X0.rawValue + UInt32(n))) }
    private func setX(_ n: Int, _ value: UInt64) { setReg(hv_reg_t(rawValue: HV_REG_X0.rawValue + UInt32(n)), value) }

    private func advance() { setReg(HV_REG_PC, reg(HV_REG_PC) + 4) }
}
