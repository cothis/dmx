import Darwin
import Foundation
import Hypervisor
import Testing
@testable import DMXCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DMX_MACHINE_VM"] == "1"))
struct RemainingLifecycleVMTests {
    @Test func preRunExitIsLatched() throws {
        try check(hv_vm_create(hv_vm_config_create()), "hv_vm_create")
        defer { hv_vm_destroy() }
        let size = Int(getpagesize())
        let memory = try #require(mmap(nil,size,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0))
        defer { munmap(memory,size) }
        #expect(memory != MAP_FAILED)
        memory.storeBytes(of:UInt32(0x14000000),as:UInt32.self) // b .
        try check(hv_vm_map(memory,0x40000000,size,hv_memory_flags_t(HV_MEMORY_READ|HV_MEMORY_WRITE|HV_MEMORY_EXEC)),"hv_vm_map")
        var id:hv_vcpu_t = 0
        var info:UnsafeMutablePointer<hv_vcpu_exit_t>?
        try check(hv_vcpu_create(&id,&info,nil),"hv_vcpu_create")
        defer { hv_vcpu_destroy(id) }
        try check(hv_vcpu_set_reg(id,HV_REG_PC,0x40000000),"PC")
        try check(hv_vcpu_set_reg(id,HV_REG_CPSR,0x3c5),"CPSR")
        var target=id
        try check(hv_vcpus_exit(&target,1),"pre-run exit")
        let rescue = DispatchSemaphore(value:0)
        let ownedID = id
        DispatchQueue.global().async {
            usleep(200000)
            var target=ownedID
            hv_vcpus_exit(&target,1)
            rescue.signal()
        }
        let start=ContinuousClock.now
        try check(hv_vcpu_run(id),"hv_vcpu_run")
        let elapsed=ContinuousClock.now-start
        rescue.wait() // no later rescue may target a destroyed/reused vCPU id
        #expect(elapsed < .milliseconds(100))
        #expect(info?.pointee.reason == HV_EXIT_REASON_CANCELED)
    }
}

/// The parent probe expects exit 70; this suite deliberately leaves a vCPU in a share syscall.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DMX_STUCK_SHARE_VM"] == "1"))
struct StuckShareLifecycleTests {
    @Test func shutdownExitsWhenHostShareCannotReturn() async throws {
        let home=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["DMX_STUCK_SHARE_PATH"]))
        let entered=DispatchSemaphore(value:0), never=DispatchSemaphore(value:0)
        let machine=try Machine(spec:MachineSpec(cpus:2,maxMemory:512<<20,shares:[Share(path:home.path,readOnly:false)]),paths:Paths(),output:.file(.nullDevice),teardownTimeout:0.5,beforeShareRequest:{ opcode in
            if opcode == FUSE.Opcode.lookup.rawValue { entered.signal(); never.wait() }
        })
        try machine.start()
        let agent=try await machine.connectAgent(timeout:.seconds(10))
        let request=Task { try await agent.run(["stat",home.path+"/block"]) }
        let reached = await withCheckedContinuation { done in
            DispatchQueue.global().async { done.resume(returning: entered.wait(timeout:.now()+5)) }
        }
        #expect(reached == .success)
        await machine.stop()
        _ = await machine.waitUntilStopped() // watchdog must terminate the process
        _ = try? await request.value
        Issue.record("uninterruptible share stop returned instead of bounded process exit")
    }
}
