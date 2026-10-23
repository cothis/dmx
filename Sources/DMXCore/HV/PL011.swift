import Foundation

/// A device on the MMIO bus. Called from vCPU threads, so implementations lock their own state.
protocol MMIODevice: AnyObject {
    func read(offset: UInt64, size: Int) -> UInt64
    func write(offset: UInt64, size: Int, value: UInt64)
}

/// The ARM PrimeCell PL011 UART, enough for Linux's amba-pl011 driver and earlycon.
/// Transmit is instant. Interrupts follow QEMU's model, which that driver is known to work with:
/// TX is raised by every write and RX while input waits, both cleared through ICR.
final class PL011: MMIODevice, @unchecked Sendable {
    private let lock = NSLock()
    private let output: FileHandle
    private let irq: (Bool) -> Void
    private var input: [UInt8] = []
    private var level: UInt32 = 0      // raw interrupt status (RIS)
    private var mask: UInt32 = 0       // IMSC
    private var registers: [UInt64: UInt32] = [:]

    private static let rx: UInt32 = 1 << 4, tx: UInt32 = 1 << 5
    /// PeriphID0-3 and PCellID0-3, which the AMBA bus reads to match the driver.
    private static let ids: [UInt32] = [0x11, 0x10, 0x14, 0x00, 0x0d, 0xf0, 0x05, 0xb1]

    init(output: FileHandle, irq: @escaping (Bool) -> Void) {
        self.output = output
        self.irq = irq
    }

    /// Bytes typed on the host, delivered to the guest's receive FIFO.
    func receive(_ bytes: [UInt8]) {
        lock.lock()
        input += bytes
        level |= Self.rx
        let line = level & mask != 0
        lock.unlock()
        irq(line)
    }

    func read(offset: UInt64, size: Int) -> UInt64 {
        lock.lock()
        defer { update() }
        switch offset {
        case 0x000:  // DR
            guard !input.isEmpty else { return 0 }
            let byte = input.removeFirst()
            if input.isEmpty { level &= ~Self.rx }
            return UInt64(byte)
        case 0x018:  // FR: TXFE, and RXFE when nothing waits
            return UInt64(1 << 7 | (input.isEmpty ? 1 << 4 : 0))
        case 0x038: return UInt64(mask)
        case 0x03c: return UInt64(level)
        case 0x040: return UInt64(level & mask)
        case 0xfe0...0xffc: return UInt64(Self.ids[Int(offset - 0xfe0) / 4])
        default: return UInt64(registers[offset] ?? 0)
        }
    }

    func write(offset: UInt64, size: Int, value: UInt64) {
        lock.lock()
        defer { update() }
        switch offset {
        case 0x000:
            output.write(Data([UInt8(truncatingIfNeeded: value)]))
            level |= Self.tx
        case 0x038: mask = UInt32(truncatingIfNeeded: value)
        case 0x044: level &= ~UInt32(truncatingIfNeeded: value)
        default: registers[offset] = UInt32(truncatingIfNeeded: value)
        }
    }

    /// Unlocks and drives the interrupt line from the masked status.
    private func update() {
        let line = level & mask != 0
        lock.unlock()
        irq(line)
    }
}
