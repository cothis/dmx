import Foundation
import Security
import Testing
@testable import DMXCore

/// Local names without a VM: the name table from Docker's listing, the DNS answers, the Host
/// and TLS server name parsers, and the CA's certificates as macOS evaluates them.
/// scripts/test-names.py runs them against containers on the real VM.
@Suite struct LocalNamesTests {
    static func container(_ name: String, id: String? = nil, ip: String? = "172.17.0.2", network: String = "bridge",
                          mode: String = "bridge", ports: [Int] = [], labels: [String: String] = [:]) -> [String: Any] {
        var networks: [String: Any] = [:]
        if let ip { networks[network] = ["IPAddress": ip] }
        return ["Id": id ?? String(repeating: name.first.map(String.init) ?? "x", count: 64), "Names": ["/" + name],
                "Labels": labels, "HostConfig": ["NetworkMode": mode],
                "Ports": ports.map { ["PrivatePort": $0, "Type": "tcp"] as [String: Any] },
                "NetworkSettings": ["Networks": networks]]
    }

    @Test func namesFromContainersAndComposeServices() {
        let compose = ["com.docker.compose.project": "shop", "com.docker.compose.service": "front"]
        let entries = LocalNames.entries([
            Self.container("web", ports: [443, 80]),
            Self.container("shop-front-2", ip: "172.18.0.4", network: "shop_default", mode: "shop_default", ports: [3000],
                           labels: compose.merging(["com.docker.compose.container-number": "2"]) { $1 }),
            Self.container("shop-front-1", ip: "172.18.0.3", network: "shop_default", mode: "shop_default", ports: [3000],
                           labels: compose.merging(["com.docker.compose.container-number": "1"]) { $1 }),
            Self.container("My_App", ip: "172.17.0.5", ports: [9000, 5000]),
            Self.container("api", ip: "172.17.0.6", ports: [8080], labels: [LocalNames.portLabel: "9229"]),
            Self.container("bad..name"),
        ])
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(byName["web.dmx.local"]?.port == 80)
        #expect(byName["web.dmx.local"]?.address == "172.17.0.2")
        // The lowest-numbered replica takes the service name.
        #expect(byName["front.shop.dmx.local"]?.container == "shop-front-1")
        #expect(byName["front.shop.dmx.local"]?.address == "172.18.0.3")
        #expect(byName["shop-front-2.dmx.local"]?.port == 3000)
        #expect(byName["my-app.dmx.local"]?.port == 5000)
        #expect(byName["api.dmx.local"]?.port == 9229)
        #expect(!entries.contains { $0.container == "bad..name" })
    }

    @Test func sharedAndHostNetworks() {
        let web = Self.container("web", id: String(repeating: "a", count: 64), ip: "172.17.0.2")
        let side = Self.container("side", id: String(repeating: "b", count: 64), ip: nil, mode: "container:" + String(repeating: "a", count: 64))
        let host = Self.container("hosted", ip: nil, mode: "host", ports: [])
        let gone = Self.container("orphan", ip: nil, mode: "container:" + String(repeating: "f", count: 64))
        let byName = Dictionary(uniqueKeysWithValues: LocalNames.entries([web, side, host, gone]).map { ($0.name, $0) })
        #expect(byName["side.dmx.local"]?.address == "172.17.0.2")
        #expect(byName["hosted.dmx.local"]?.address == "127.0.0.1")
        #expect(byName["hosted.dmx.local"]?.port == 80)
        #expect(byName["orphan.dmx.local"] == nil)
    }

    @Test func aServiceNameWinsOverAContainerNamedLikeIt() {
        let entries = LocalNames.entries([
            Self.container("front.shop", ip: "172.17.0.9"),
            Self.container("shop-front-1", ip: "172.18.0.3",
                           labels: ["com.docker.compose.project": "shop", "com.docker.compose.service": "front"]),
        ])
        #expect(entries.first { $0.name == "front.shop.dmx.local" }?.container == "shop-front-1")
    }

    static func query(_ name: String, type: UInt16, opcode: UInt8 = 0) -> [UInt8] {
        var q: [UInt8] = [0x12, 0x34, (opcode << 3) | 0x01, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") { q.append(UInt8(label.utf8.count)); q += Array(label.utf8) }
        q += [0, UInt8(type >> 8), UInt8(type & 0xff), 0, 1]
        return q
    }

    @Test func dnsAnswersLoopbackUnderDmxLocalOnly() throws {
        let a = try #require(LocalNames.dnsAnswer(Self.query("Web.DMX.local", type: 1)))
        #expect(a[0] == 0x12 && a[1] == 0x34)
        #expect(a[3] & 0x0f == 0)                    // NOERROR
        #expect(a[6] == 0 && a[7] == 1)              // one answer
        #expect(Array(a.suffix(4)) == [127, 0, 0, 1])
        let aaaa = try #require(LocalNames.dnsAnswer(Self.query("web.dmx.local", type: 28)))
        #expect(aaaa[3] & 0x0f == 0 && aaaa[7] == 0)  // no IPv6 address: names listen on IPv4
        let other = try #require(LocalNames.dnsAnswer(Self.query("example.com", type: 1)))
        #expect(other[3] & 0x0f == 5)                // REFUSED
        let lookalike = try #require(LocalNames.dnsAnswer(Self.query("evildmx.local", type: 1)))
        #expect(lookalike[3] & 0x0f == 5)
        let update = try #require(LocalNames.dnsAnswer(Self.query("web.dmx.local", type: 1, opcode: 5)))
        #expect(update[3] & 0x0f == 4)
        #expect(LocalNames.dnsAnswer([1, 2, 3]) == nil)
        var response = Self.query("web.dmx.local", type: 1)
        response[2] |= 0x80
        #expect(LocalNames.dnsAnswer(response) == nil)
    }

    @Test func hostHeader() {
        func host(_ s: String) -> LocalNames.Head { LocalNames.requestHost(Array(s.utf8)) }
        #expect(host("GET / HTTP/1.1\r\nHost: Web.dmx.local:8080\r\n\r\n") == .host("web.dmx.local"))
        #expect(host("GET / HTTP/1.1\r\nhost:web.dmx.local.\r\nAccept: */*\r\n\r\nbody") == .host("web.dmx.local"))
        #expect(host("GET / HTTP/1.1\r\nHost: web.dmx.local\r\n") == .incomplete)
        #expect(host("GET / HTTP/1.0\r\n\r\n") == .host(nil))
        #expect(host("GET / HTTP/1.1\r\nHost: [::1]:80\r\n\r\n") == .host("[::1]:80"))
    }

    /// A TLS 1.2-style ClientHello with a server_name extension (and one before it).
    static func clientHello(_ name: String?) -> [UInt8] {
        var extensions: [UInt8] = [0x00, 0x0b, 0x00, 0x02, 0x01, 0x00]  // ec_point_formats
        if let name {
            let n = Array(name.utf8)
            let list: [UInt8] = [0] + [UInt8(n.count >> 8), UInt8(n.count & 0xff)] + n
            let ext: [UInt8] = [UInt8(list.count >> 8), UInt8(list.count & 0xff)] + list
            extensions += [0, 0, UInt8(ext.count >> 8), UInt8(ext.count & 0xff)] + ext
        }
        var body: [UInt8] = [3, 3] + [UInt8](repeating: 7, count: 32) + [0] + [0, 2, 0x13, 0x01] + [1, 0]
        body += [UInt8(extensions.count >> 8), UInt8(extensions.count & 0xff)] + extensions
        let handshake: [UInt8] = [1, 0, UInt8(body.count >> 8), UInt8(body.count & 0xff)] + body
        return [22, 3, 1, UInt8(handshake.count >> 8), UInt8(handshake.count & 0xff)] + handshake
    }

    @Test func tlsServerName() {
        let hello = Self.clientHello("Front.Shop.dmx.local")
        #expect(LocalNames.serverName(hello) == .host("front.shop.dmx.local"))
        #expect(LocalNames.serverName(Array(hello.prefix(20))) == .incomplete)
        #expect(LocalNames.serverName(Self.clientHello(nil)) == .host(nil))
        #expect(LocalNames.serverName(Array("GET / HTTP/1.1\r\n".utf8)) == .host(nil))
    }

    static func evaluate(_ leaf: Data, _ authority: NameAuthority, name: String) -> Bool {
        let leafCert = SecCertificateCreateWithData(nil, leaf as CFData)!
        let ca = SecCertificateCreateWithData(nil, authority.certificate as CFData)!
        var trust: SecTrust?
        SecTrustCreateWithCertificates([leafCert, ca] as CFArray, SecPolicyCreateSSL(true, name as CFString), &trust)
        SecTrustSetAnchorCertificates(trust!, [ca] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust!, true)
        return SecTrustEvaluateWithError(trust!, nil)
    }

    @Test func authorityIssuesOnlyNamesUnderDmxLocal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dmx-names-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let authority = try NameAuthority.loadOrCreate(dir)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("ca.key").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let key = try P256Key.generate()
        #expect(Self.evaluate(try authority.issue("web.dmx.local", leafKey: key), authority, name: "web.dmx.local"))
        #expect(Self.evaluate(try authority.issue("front.shop.dmx.local", leafKey: key), authority, name: "front.shop.dmx.local"))
        // The name constraints: a leaf the CA signed for another name is not accepted.
        #expect(!Self.evaluate(try authority.issue("example.com", leafKey: key), authority, name: "example.com"))
        #expect(!Self.evaluate(try authority.issue("evildmx.local", leafKey: key), authority, name: "evildmx.local"))
        #expect(!Self.evaluate(try authority.issue("web.dmx.local", leafKey: key), authority, name: "other.dmx.local"))
        // Loading gives the same CA, and it still signs.
        let again = try #require(try NameAuthority.load(dir))
        #expect(again.sha1 == authority.sha1)
        #expect(Self.evaluate(try again.issue("api.dmx.local", leafKey: key), authority, name: "api.dmx.local"))
        _ = try again.identity("api.dmx.local", leafKey: key)
    }

    @Test func resolverFileNamesThePort() {
        var s = LocalNames.Settings()
        s.dnsPort = 15353
        #expect(LocalNames.resolverText(s) == "# dmx local names (`dmx names`)\nnameserver 127.0.0.1\nport 15353\n")
    }
}
