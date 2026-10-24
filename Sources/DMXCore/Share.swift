import Foundation

/// A host directory the guest sees at the same path, over dmx's virtio-fs device, so a bind
/// mount like `docker run -v $PWD:$PWD` names the same files on both sides.
public struct Share: Sendable, Equatable {
    /// Absolute host path, also the mount point in the guest. Symlinks in it are resolved on the
    /// host when the VM boots; the guest mounts it under the name given here.
    public var path: String
    public var readOnly: Bool

    public init(path: String, readOnly: Bool = false) {
        self.path = path
        self.readOnly = readOnly
    }

    /// The default, Docker Desktop's: /Users, /Volumes and /private, read-write. Docker Desktop
    /// also lists /tmp and /var/folders, which on macOS are links into /private; dockerd sees
    /// them at their own paths (guest/docker), so `docker run -v /tmp/x:/x` names the Mac's
    /// /tmp/x. The rest of the guest keeps its own /tmp.
    public static var defaults: [Share] { ["/Users", "/Volumes", "/private"].map { Share(path: $0) } }

    /// Guest directories a share must not cover: the guest's own system and the data disk.
    static let reserved = ["/bin", "/dev", "/etc", "/lib", "/proc", "/run", "/sbin", "/sys", "/usr", "/var/lib"]

    /// Each share is its own virtio-fs device and kernel command line argument.
    public static let maxCount = 8

    /// The text form `parse` reads back: the path, with `:ro` for read-only.
    public var text: String { path + (readOnly ? ":ro" : "") }

    /// Parses `path` or `path:ro`. `~` stands for the home directory; the result is absolute.
    public static func parse(_ text: String) throws -> Share {
        var raw = text.trimmingCharacters(in: .whitespaces)
        var readOnly = false
        if raw.hasSuffix(":ro") { readOnly = true; raw.removeLast(3) } else if raw.hasSuffix(":rw") { raw.removeLast(3) }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw DMXError("bad_share", "a share must be an absolute path or start with ~, not \"\(text)\"", hint: "e.g. `dmx config set shares ~,/Volumes/data:ro`")
        }
        let path = (expanded as NSString).standardizingPath
        // The guest learns the mount points from the kernel command line, split on whitespace.
        guard !path.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "," }), !path.contains("\0") else {
            throw DMXError("bad_share", "share paths cannot contain whitespace, quotes or commas: \"\(path)\"", hint: "share a parent directory instead")
        }
        guard path != "/", path != "/var", !reserved.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            throw DMXError("bad_share", "\(path) would hide the guest's own files", hint: "share a directory outside \(reserved.joined(separator: ", "))")
        }
        return Share(path: path, readOnly: readOnly)
    }

    /// Parses a comma separated list; `none` (or nothing) shares nothing.
    public static func parseList(_ text: String) throws -> [Share] {
        let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if items == ["none"] || items.isEmpty { return [] }
        let shares = try items.map(parse)
        guard shares.count <= maxCount else {
            throw DMXError("bad_share", "at most \(maxCount) shares, not \(shares.count)", hint: "share a common parent directory")
        }
        for (i, a) in shares.enumerated() {
            for b in shares[(i + 1)...] where a.path == b.path {
                throw DMXError("bad_share", "\(a.path) is shared twice", hint: "list each directory once")
            }
        }
        return shares
    }
}
