import Foundation

/// Writes a flattened device tree (devicetree spec v0.4, version 17), the hardware description
/// an arm64 Linux kernel reads at boot instead of probing.
struct FDT {
    private var structure = Data()
    private var strings = Data()
    private var stringOffsets: [String: UInt32] = [:]
    private var depth = 0

    private enum Token: UInt32 { case beginNode = 1, endNode = 2, prop = 3, end = 9 }

    mutating func begin(_ name: String) {
        token(.beginNode)
        structure.append(contentsOf: Array(name.utf8) + [0])
        pad()
        depth += 1
    }

    mutating func end() {
        precondition(depth > 0, "unbalanced FDT end()")
        token(.endNode)
        depth -= 1
    }

    /// `begin(name)`, the body, `end()`.
    mutating func node(_ name: String, _ body: (inout FDT) -> Void) {
        begin(name)
        body(&self)
        end()
    }

    mutating func property(_ name: String, _ value: Data) {
        token(.prop)
        be32(UInt32(value.count))
        be32(nameOffset(name))
        structure.append(value)
        pad()
    }

    mutating func property(_ name: String) { property(name, Data()) }

    mutating func property(_ name: String, u32 values: UInt32...) { property(name, u32: values) }

    mutating func property(_ name: String, u32 values: [UInt32]) {
        var data = Data()
        for v in values { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
        property(name, data)
    }

    mutating func property(_ name: String, u64 values: UInt64...) {
        var data = Data()
        for v in values { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
        property(name, data)
    }

    mutating func property(_ name: String, string: String) { property(name, strings: [string]) }

    mutating func property(_ name: String, strings: [String]) {
        property(name, Data(strings.flatMap { Array($0.utf8) + [0] }))
    }

    func finish() -> Data {
        precondition(depth == 0, "unbalanced FDT begin()")
        var body = structure
        withUnsafeBytes(of: Token.end.rawValue.bigEndian) { body.append(contentsOf: $0) }

        let headerSize = 40
        let reserveMap = Data(count: 16)  // one empty entry ends the memory reservation map
        let offReserve = headerSize
        let offStruct = offReserve + reserveMap.count
        let offStrings = offStruct + body.count
        let total = offStrings + strings.count

        var out = Data()
        for field in [0xd00d_feed, UInt32(total), UInt32(offStruct), UInt32(offStrings), UInt32(offReserve),
                      17, 16, 0, UInt32(strings.count), UInt32(body.count)] as [UInt32] {
            withUnsafeBytes(of: field.bigEndian) { out.append(contentsOf: $0) }
        }
        out.append(reserveMap)
        out.append(body)
        out.append(strings)
        return out
    }

    private mutating func token(_ t: Token) { be32(t.rawValue) }

    private mutating func be32(_ v: UInt32) {
        withUnsafeBytes(of: v.bigEndian) { structure.append(contentsOf: $0) }
    }

    private mutating func pad() {
        structure.append(contentsOf: [UInt8](repeating: 0, count: (4 - structure.count % 4) % 4))
    }

    private mutating func nameOffset(_ name: String) -> UInt32 {
        if let offset = stringOffsets[name] { return offset }
        let offset = UInt32(strings.count)
        strings.append(contentsOf: Array(name.utf8) + [0])
        stringOffsets[name] = offset
        return offset
    }
}
