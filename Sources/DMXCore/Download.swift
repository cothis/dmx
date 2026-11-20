import CryptoKit
import Foundation

/// Downloads `url` to `destination` and checks it against `sha256` before anything uses it.
/// A file that does not match is deleted. Nothing is fetched without a pinned hash.
/// `maxBytes`: the expected size, or a bound on it; a larger answer fails while it downloads,
/// before the hash could tell, so a wrong server cannot fill the disk.
func downloadVerified(_ url: URL, to destination: URL, sha256 expected: String, maxBytes: Int = 512 << 20) async throws {
    let fm = FileManager.default
    try? fm.removeItem(at: destination)
    do {
        _ = try await Transfer.run(url, to: destination, from: 0, limit: maxBytes)
    } catch let failure as Transfer.Failure {
        try? fm.removeItem(at: destination)
        throw DMXError("download_failed", "cannot download \(url.absoluteString): \(failure.message)",
                       hint: "check the network and the release URL (`dmx config get release_url`), then try again")
    } catch {
        try? fm.removeItem(at: destination)
        throw error
    }
    let actual = try sha256Hex(of: destination)
    guard actual == expected else {
        try? fm.removeItem(at: destination)
        throw DMXError("checksum_mismatch", "\(url.absoluteString) has sha256 \(actual), expected \(expected)",
                       hint: "the file changed on its way or on the server; try again, and report it if it stays so")
    }
}

/// The sha256 of a file, read through one 1 MB buffer. Not FileHandle.read: each chunk it returns
/// is autoreleased, and in the daemon (no pool drains) a 58 MB guest download plus hashing its
/// files left ~130 MB in the footprint for the daemon's life.
func sha256Hex(of file: URL) throws -> String {
    let fd = open(file.path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw DMXError("io_error", "cannot open \(file.path): \(String(cString: strerror(errno)))") }
    defer { close(fd) }
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
    defer { buffer.deallocate() }
    var hash = SHA256()
    while true {
        let n = read(fd, buffer.baseAddress, buffer.count)
        if n < 0 && errno == EINTR { continue }
        guard n >= 0 else { throw DMXError("io_error", "cannot read \(file.path): \(String(cString: strerror(errno)))") }
        if n == 0 { break }
        hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<n]))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
