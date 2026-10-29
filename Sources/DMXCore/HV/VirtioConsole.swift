import Foundation

/// virtio-console (device 3) with one port: hvc0 in the guest.
final class VirtioConsole: VirtioDevice, @unchecked Sendable {
    let deviceID: UInt32 = 3
    let features: UInt64 = 0
    let queueSizes: [UInt16] = [64, 64]  // receiveq (to the guest), transmitq (from it)
    private let output: ConsoleOutput
    /// Guards `pending` and `transport`; taken before `transport.lock`.
    private let inputLock = NSLock()
    private var pending = Data()  // typed on the host, not yet in a guest buffer
    private weak var transport: VirtioMMIO?

    init(output: ConsoleOutput) { self.output = output }

    func activate(_ transport: VirtioMMIO, features: UInt64) {
        inputLock.lock()
        self.transport = transport
        inputLock.unlock()
        deliver()
    }

    func reset() {
        inputLock.lock()
        transport = nil
        inputLock.unlock()
    }

    /// Bytes for the guest's hvc0, kept until the driver has buffers for them.
    func receive(_ bytes: Data) {
        inputLock.lock()
        pending.append(bytes)
        inputLock.unlock()
        deliver()
    }

    func notify(queue: Int) {
        if queue == 0 { return deliver() }
        inputLock.lock()
        let transport = self.transport
        inputLock.unlock()
        guard let transport else { return }
        transport.lock.lock()
        var data = Data(), used = false
        while let chain = transport.queues[1].pop() {
            data.append(chain.readableBytes)
            transport.queues[1].push(chain, written: 0)
            used = true
        }
        transport.lock.unlock()
        if !data.isEmpty { output.write(data) }
        if used { transport.signalUsed() }
    }

    private func deliver() {
        inputLock.lock()
        guard let transport else { return inputLock.unlock() }
        transport.lock.lock()
        var used = false
        while !pending.isEmpty, let chain = transport.queues[0].pop() {
            let n = chain.write(pending)
            pending.removeFirst(n)
            transport.queues[0].push(chain, written: n)
            used = true
        }
        transport.lock.unlock()
        inputLock.unlock()
        if used { transport.signalUsed() }
    }
}

/// virtio-rng (device 4): entropy for the guest from the host's generator.
final class VirtioRNG: VirtioDevice, @unchecked Sendable {
    let deviceID: UInt32 = 4
    let features: UInt64 = 0
    let queueSizes: [UInt16] = [64]
    private weak var transport: VirtioMMIO?

    func activate(_ transport: VirtioMMIO, features: UInt64) { self.transport = transport }
    func reset() {}

    func notify(queue: Int) {
        guard let transport else { return }
        transport.lock.lock()
        var used = false
        while let chain = transport.queues[0].pop() {
            var written = 0
            for buffer in chain.writable {
                arc4random_buf(buffer.baseAddress!, buffer.count)
                written += buffer.count
            }
            transport.queues[0].push(chain, written: written)
            used = true
        }
        transport.lock.unlock()
        if used { transport.signalUsed() }
    }
}
