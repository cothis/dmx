import Darwin
import Dispatch
import Foundation

/// macOS charges an anonymous page to a process's footprint once for every mapping of it, not
/// once per physical page. Guest RAM has two: this process's own, through which devices read and
/// write guest buffers, and the VM's stage 2 (`hv_vm_map`), through which the guest does. A page
/// the guest zeroed (our kernel zeroes every page it allocates: init_on_alloc) and a device filled
/// counts twice: reading 1 GB over virtio-fs cost 2 GB of footprint for 1 GB of memory. Two
/// mappings of the same page within this process count twice too, so this is the ledger, not
/// Hypervisor.framework copying anything.
///
/// So after devices touch guest memory, this drops this process's mappings of guest RAM by
/// remapping the region onto itself: the same VM object and pages, the stage-2 mappings stay,
/// and the next device access faults its page back in (a soft fault, no copy). The remap is one
/// map operation under the map lock, so a device thread touching guest RAM meanwhile just waits.
/// A page only this process mapped is then counted by nobody until the guest touches it. That
/// stays small because every buffer the guest hands a device was allocated, and so zeroed, by
/// the guest first; without init_on_alloc, pages a device filled and the guest never read (unused
/// readahead) would go uncounted. At idle the footprint is within 3 MB of the guest's own count
/// (reserved + MemTotal - MemFree) plus the 3 MB dmx and Hypervisor.framework cost.
final class HostMappings: @unchecked Sendable {
    /// Device traffic that triggers a remap at once, so a large transfer counts twice for at
    /// most this much. A remap that unmaps 64 MB took 0.3 to 3 ms, up to 60 ms on a loaded host.
    static let threshold = 64 << 20
    /// Smaller traffic waits this long, so idle polling remaps every few seconds at most.
    static let delay: DispatchTimeInterval = .seconds(1)

    private let base: UnsafeMutableRawPointer
    private let size: Int
    private let queue = DispatchQueue(label: "dmx.host-mappings", qos: .utility)
    /// Guards the counters below; never held across a remap.
    private let lock = NSLock()
    private var pending = 0
    private var due: DispatchTime?
    private var stopped = false
    /// Held across a remap, and by `exclusive` callers that change guest RAM's mappings.
    private let mapLock = NSLock()

    init(base: UnsafeMutableRawPointer, size: Int) {
        self.base = base
        self.size = size
    }

    /// A device read or wrote `bytes` of guest buffers through this process's mapping.
    func touched(_ bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        pending += bytes
        let when: DispatchTime = pending >= Self.threshold ? .now() : .now() + Self.delay
        if let due, due <= when { return }
        due = when
        queue.asyncAfter(deadline: when) { [weak self] in self?.remap(scheduledFor: when) }
    }

    /// Runs `body` with no remap in progress, for changes to guest RAM's mappings
    /// (`hv_vm_unmap`, `madvise`, `hv_vm_map`) that must not interleave with one.
    func exclusive<T>(_ body: () throws -> T) rethrows -> T {
        mapLock.lock()
        defer { mapLock.unlock() }
        return try body()
    }

    /// No more remaps: guest RAM is about to be unmapped, and remapping a range something else
    /// may then own would replace that memory. Waits for a remap in progress.
    func stop() {
        mapLock.lock()
        lock.lock()
        stopped = true
        lock.unlock()
        mapLock.unlock()
    }

    /// Drops this process's mappings now, without waiting for traffic to add up.
    func remapNow() {
        lock.lock()
        due = nil  // cancels a scheduled remap
        pending = 0
        lock.unlock()
        remap()
    }

    private func remap(scheduledFor when: DispatchTime) {
        lock.lock()
        guard !stopped, due == when else { lock.unlock(); return }  // stopped, or an earlier one ran
        due = nil
        pending = 0
        lock.unlock()
        remap()
    }

    private func remap() {
        mapLock.lock()
        defer { mapLock.unlock() }
        lock.lock()
        let stopped = self.stopped
        lock.unlock()
        guard !stopped else { return }
        var address = mach_vm_address_t(UInt(bitPattern: base))
        var current: vm_prot_t = 0, maximum: vm_prot_t = 0
        // copy false: the new mapping shares the VM object, it does not copy it.
        let result = mach_vm_remap(mach_task_self_, &address, mach_vm_size_t(size), 0,
                                   VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self_, address,
                                   0, &current, &maximum, VM_INHERIT_DEFAULT)
        if result != KERN_SUCCESS || address != mach_vm_address_t(UInt(bitPattern: base)) {
            // Not expected; the footprint only overcounts again. Stop rather than retry.
            lock.lock()
            self.stopped = true
            lock.unlock()
        }
    }
}
