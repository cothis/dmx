import Foundation

/// Local names: `http://<container>.dmx.local` and `http://<service>.<project>.dmx.local`, and
/// the same over HTTPS, reach a running container's web port without publishing it. A resolver
/// file (`/etc/resolver/dmx.local`) sends lookups under dmx.local to the daemon's DNS on
/// 127.0.0.1, which answers 127.0.0.1 for every name there; the daemon listens on ports 80 and
/// 443 and routes each connection by its Host header or TLS server name to the container's
/// address in the guest, through the agent's `connect`. HTTPS uses leaves from a CA that may sign
/// nothing but names under dmx.local (NameAuthority). `dmx names setup` turns it on.
public enum LocalNames {
    public static let domain = "dmx.local"
    public static let resolverFile = "/etc/resolver/\(domain)"
    /// A container label that picks the port names route to.
    public static let portLabel = "dmx.http-port"

    /// What `dmx names setup` chose, in `~/.dmx/names/names.json`. Names are on while it exists.
    public struct Settings: Codable, Sendable, Equatable {
        public var dnsPort = 53530
        public var httpPort = 80
        public var httpsPort = 443
        /// Whether setup changed macOS (trusted the CA, wrote the resolver file).
        public var system = true
        public init() {}
    }

    public static func directory(_ paths: Paths) -> URL { paths.home.appendingPathComponent("names", isDirectory: true) }
    static func settingsFile(_ paths: Paths) -> URL { directory(paths).appendingPathComponent("names.json") }

    public static func settings(_ paths: Paths) -> Settings? {
        guard let data = try? Data(contentsOf: settingsFile(paths)) else { return nil }
        return try? FrameConnection.decoder.decode(Settings.self, from: data)
    }

    static func save(_ settings: Settings, _ paths: Paths) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(settings) + Data("\n".utf8)).write(to: settingsFile(paths), options: .atomic)
    }

    /// The resolver file's text for `settings`.
    public static func resolverText(_ settings: Settings) -> String {
        "# dmx local names (`dmx names`)\nnameserver 127.0.0.1\nport \(settings.dnsPort)\n"
    }

    // MARK: - Names

    /// A name and where it leads.
    public struct Entry: Codable, Sendable, Equatable {
        public let name: String
        public let container: String
        /// The container's address in the guest and the port connections go to.
        public let address: String
        public let port: Int
        public var url: String { "http://\(name)" }
    }

    /// The names of running containers, from Docker's container listing: each container's own
    /// name, and for a Compose service `<service>.<project>` (its lowest-numbered replica).
    /// A name another entry took first is left out; so is one that is not a DNS name.
    static func entries(_ containers: [[String: Any]]) -> [Entry] {
        var byID: [String: [String: Any]] = [:]
        for c in containers { if let id = c["Id"] as? String { byID[id] = c } }

        func address(_ c: [String: Any], depth: Int = 0) -> String? {
            let mode = (c["HostConfig"] as? [String: Any])?["NetworkMode"] as? String ?? ""
            if mode == "host" { return "127.0.0.1" }
            if mode.hasPrefix("container:"), depth < 4 {
                let target = String(mode.dropFirst("container:".count))
                let owner = byID[target] ?? byID.first(where: { $0.key.hasPrefix(target) })?.value
                return owner.flatMap { address($0, depth: depth + 1) }
            }
            let networks = ((c["NetworkSettings"] as? [String: Any])?["Networks"] as? [String: Any]) ?? [:]
            // The default network if it has an address, otherwise the first by name.
            for key in [mode] + networks.keys.sorted() {
                if let ip = (networks[key] as? [String: Any])?["IPAddress"] as? String, !ip.isEmpty { return ip }
            }
            return nil
        }

        var taken = Set<String>()
        var out: [Entry] = []
        func add(_ label: String, _ container: String, _ c: [String: Any]) {
            guard let name = dnsName(label), taken.insert(name).inserted, let ip = address(c) else { return }
            out.append(Entry(name: name, container: container, address: ip, port: port(c)))
        }
        func number(_ c: [String: Any]) -> Int { Int(((c["Labels"] as? [String: String]) ?? [:])["com.docker.compose.container-number"] ?? "") ?? Int.max }
        let sorted = containers.sorted { (number($0), name($0)) < (number($1), name($1)) }
        // Services first, so a container named like another project's service does not hide it.
        for c in sorted {
            let labels = c["Labels"] as? [String: String] ?? [:]
            if let project = labels["com.docker.compose.project"], let service = labels["com.docker.compose.service"] {
                add("\(service).\(project)", name(c), c)
            }
        }
        for c in sorted { add(name(c), name(c), c) }
        return out.sorted { $0.name < $1.name }
    }

    private static func name(_ c: [String: Any]) -> String {
        let names = c["Names"] as? [String] ?? []
        return String((names.first ?? (c["Id"] as? String ?? "")).drop(while: { $0 == "/" }))
    }

    /// `<label>.dmx.local` in lower case with `_` as `-`, or nil if that is not a DNS name.
    static func dnsName(_ label: String) -> String? {
        let lower = label.lowercased().replacingOccurrences(of: "_", with: "-")
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ part in
            (1...63).contains(part.count) && part.first != "-" && part.last != "-"
                && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }) else { return nil }
        let full = "\(lower).\(domain)"
        return full.count <= 253 ? full : nil
    }

    /// The port a name routes to: the `dmx.http-port` label, else 80 if the container has it,
    /// else the first of 8080, 3000, 8000, 5000 it has, else its lowest TCP port, else 80.
    static func port(_ c: [String: Any]) -> Int {
        let labels = c["Labels"] as? [String: String] ?? [:]
        if let p = labels[portLabel].flatMap({ Int($0) }), (1...65535).contains(p) { return p }
        let tcp = Set((c["Ports"] as? [[String: Any]] ?? []).compactMap { p -> Int? in
            (p["Type"] as? String ?? "tcp") == "tcp" ? p["PrivatePort"] as? Int : nil
        })
        if let preferred = [80, 8080, 3000, 8000, 5000].first(where: tcp.contains) { return preferred }
        return tcp.min() ?? 80
    }

    // MARK: - DNS

    /// The reply to a DNS query: A 127.0.0.1 for any name under dmx.local, an empty answer for
    /// other types there, REFUSED for names elsewhere. Nil for what is not a query.
    static func dnsAnswer(_ query: [UInt8]) -> [UInt8]? {
        guard query.count >= 17, query[2] & 0x80 == 0, query[4] == 0, query[5] == 1 else { return nil }
        var offset = 12
        var labels: [String] = []
        while true {
            guard offset < query.count else { return nil }
            let length = Int(query[offset])
            offset += 1
            if length == 0 { break }
            guard length < 64, offset + length <= query.count else { return nil }
            labels.append(String(decoding: query[offset..<offset + length], as: UTF8.self).lowercased())
            offset += length
        }
        guard offset + 4 <= query.count else { return nil }
        let type = UInt16(query[offset]) << 8 | UInt16(query[offset + 1])
        let questionEnd = offset + 4
        let name = labels.joined(separator: ".")
        let ours = name == domain || name.hasSuffix(".\(domain)")
        let opcode = (query[2] >> 3) & 0x0f
        var reply: [UInt8] = [query[0], query[1]]
        // QR, the opcode, authoritative, recursion desired as asked; rcode 0, 4 (not
        // implemented) for other opcodes, 5 (refused) outside dmx.local.
        let rcode: UInt8 = opcode != 0 ? 4 : (ours ? 0 : 5)
        reply += [0x80 | (opcode << 3) | 0x04 | (query[2] & 0x01), rcode]
        let answer = rcode == 0 && type == 1
        reply += [0, 1, 0, answer ? 1 : 0, 0, 0, 0, 0]
        reply += query[12..<questionEnd]
        if answer {
            // The question's name, A, IN, a TTL of 5 s (names follow containers), 127.0.0.1.
            reply += [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 5, 0, 4, 127, 0, 0, 1]
        }
        return reply
    }

    // MARK: - HTTP and TLS

    /// The host the request names (the Host header without a port), lower case, if the bytes
    /// hold a complete request head; `.incomplete` if more bytes are needed.
    enum Head: Equatable { case incomplete, host(String?) }

    static func requestHost(_ bytes: [UInt8]) -> Head {
        guard let end = bytes.firstRange(of: [13, 10, 13, 10]) else { return .incomplete }
        let head = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            guard line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "host" else { continue }
            var host = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
            if host.hasPrefix("[") { return .host(host) }  // IPv6 literal: never one of ours
            if let c = host.lastIndex(of: ":") { host = String(host[..<c]) }
            if host.hasSuffix(".") { host.removeLast() }
            return .host(host)
        }
        return .host(nil)
    }

    /// The server name of a TLS ClientHello, or `.incomplete` if more bytes are needed. Nil
    /// inside `.host` if the bytes are not a ClientHello or carry no name.
    static func serverName(_ b: [UInt8]) -> Head {
        guard b.count >= 5 else { return .incomplete }
        guard b[0] == 22, b[1] == 3 else { return .host(nil) }
        let recordEnd = 5 + (Int(b[3]) << 8 | Int(b[4]))
        guard b.count >= recordEnd else { return .incomplete }
        // Handshake: type 1, 3-byte length, version, random, then variable fields.
        var i = 5
        guard recordEnd >= i + 4 + 2 + 32 + 1, b[i] == 1 else { return .host(nil) }
        i += 4 + 2 + 32
        func skip(_ lengthBytes: Int) -> Bool {
            guard i + lengthBytes <= recordEnd else { return false }
            var n = 0
            for k in 0..<lengthBytes { n = n << 8 | Int(b[i + k]) }
            i += lengthBytes + n
            return i <= recordEnd
        }
        guard skip(1), skip(2), skip(1), i + 2 <= recordEnd else { return .host(nil) }  // session, ciphers, compression
        let extensionsEnd = min(recordEnd, i + 2 + (Int(b[i]) << 8 | Int(b[i + 1])))
        i += 2
        while i + 4 <= extensionsEnd {
            let type = Int(b[i]) << 8 | Int(b[i + 1]), length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            i += 4
            guard i + length <= extensionsEnd else { return .host(nil) }
            if type == 0 {
                // server_name_list: length, then entries of type (0 = host_name), length, name.
                var j = i + 2
                while j + 3 <= i + length {
                    let kind = b[j], n = Int(b[j + 1]) << 8 | Int(b[j + 2])
                    j += 3
                    guard j + n <= i + length else { break }
                    if kind == 0 { return .host(String(decoding: b[j..<j + n], as: UTF8.self).lowercased()) }
                    j += n
                }
                return .host(nil)
            }
            i += length
        }
        return .host(nil)
    }

    /// A short plain-text HTTP reply that closes the connection.
    static func httpReply(_ status: String, _ body: String) -> [UInt8] {
        let text = body.hasSuffix("\n") ? body : body + "\n"
        return Array(("HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(text.utf8.count)\r\n" +
                      "Connection: close\r\nCache-Control: no-store\r\n\r\n" + text).utf8)
    }
}
