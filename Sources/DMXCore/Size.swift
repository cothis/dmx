import Foundation

/// Parses sizes like `512M`, `8G` or a plain byte count.
public func parseSize(_ text: String) throws -> UInt64 {
    let units: [Character: UInt64] = ["K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40]
    var digits = text.uppercased()
    if digits.hasSuffix("B") { digits.removeLast() }
    var scale: UInt64 = 1
    if let last = digits.last, let unit = units[last] {
        scale = unit
        digits.removeLast()
    }
    guard let value = UInt64(digits), value > 0 else {
        throw DMXError("bad_size", "cannot parse size \"\(text)\"", hint: "use a number with K, M, G or T, e.g. 8G")
    }
    let (bytes, overflow) = value.multipliedReportingOverflow(by: scale)
    // mmap lengths, file offsets and Docker's JSON memory limit all use signed host integers.
    // A value that only fits UInt64 would otherwise trap later, after it was accepted/saved.
    guard !overflow, bytes <= UInt64(Int64.max) else {
        throw DMXError("bad_size", "size \"\(text)\" is too large", hint: "use a smaller size, e.g. 8G")
    }
    return bytes
}

public func formatSize(_ bytes: UInt64) -> String {
    let gib = Double(bytes) / Double(1 << 30)
    return gib >= 1 ? String(format: "%.1fG", gib) : "\(bytes >> 20)M"
}
