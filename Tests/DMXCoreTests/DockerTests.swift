import Foundation
import dnssd
import Testing
@testable import DMXCore

/// The host side of Docker support that needs no VM: the docker context, the launchd job,
/// which published ports become forwards, and the names the gateway's DNS answers.
@Suite struct DockerTests {
    @Test func certificatesFromAFile() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory() + "dmx-ca-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let text = "comment\n-----BEGIN CERTIFICATE-----\r\nAAAA\r\nBBBB\r\n-----END CERTIFICATE-----\r\n"
            + "-----BEGIN PRIVATE KEY-----\nCCCC\n-----END PRIVATE KEY-----\n"
            + "  -----BEGIN CERTIFICATE-----\nDDDD\n-----END CERTIFICATE-----"
        #expect(HostCertificates.pemBlocks(text) == ["-----BEGIN CERTIFICATE-----\nAAAA\nBBBB\n-----END CERTIFICATE-----\n",
                                                     "-----BEGIN CERTIFICATE-----\nDDDD\n-----END CERTIFICATE-----\n"])
        try Data(text.utf8).write(to: home.appendingPathComponent(HostCertificates.fileName))
        let found = HostCertificates.pem(home: home)
        #expect(found.file == 2)
        #expect(found.pem.hasSuffix("-----BEGIN CERTIFICATE-----\nDDDD\n-----END CERTIFICATE-----\n"))
        #expect(HostCertificates.pem(Data([1, 2, 3])) == "-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----\n")
    }

    @Test func systemProxyForDockerd() throws {
        let off = HostProxy.parse(["ExceptionsList": ["*.local", "169.254/16"], "FTPPassive": 1])
        #expect(off.proxy == nil && !off.pac)

        let on = HostProxy.parse(["HTTPEnable": 1, "HTTPProxy": "proxy.corp.example", "HTTPPort": 8080,
                                  "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 3128,
                                  "ExceptionsList": ["*.local", "169.254/16", "10.0.0.0/8", "intranet"],
                                  "ProxyAutoConfigEnable": 1])
        #expect(on.pac)
        let proxy = try #require(on.proxy)
        #expect(proxy.http == "http://proxy.corp.example:8080")
        #expect(proxy.https == "http://192.168.127.254:3128")  // the Mac's loopback, from the guest
        #expect(proxy.noProxy.suffix(4) == [".local", "169.254.0.0/16", "10.0.0.0/8", "intranet"])
        #expect(proxy.noProxy.contains("host.docker.internal") && proxy.noProxy.contains("192.168.127.0/24"))
        // Turned off, a proxy host still in the settings is not used.
        #expect(HostProxy.parse(["HTTPEnable": 0, "HTTPProxy": "proxy.corp.example", "HTTPPort": 8080]).proxy == nil)
        #expect(HostProxy.parse(["HTTPSEnable": 1, "HTTPSProxy": "::1", "HTTPSPort": 3128]).proxy?.https == "http://192.168.127.254:3128")
        #expect(HostProxy.parse(["HTTPSEnable": 1, "HTTPSProxy": "fd00::1", "HTTPSPort": 3128]).proxy?.https == "http://[fd00::1]:3128")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "dmx-proxy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = DockerEngineConfig.file(configDir: dir)
        func proxies() throws -> [String: Any]? {
            let json = try DockerEngineConfig.build(userFile: file, proxy: proxy).json
            return (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["proxies"] as? [String: Any]
        }
        #expect(try proxies()?["https-proxy"] as? String == "http://192.168.127.254:3128")
        // The user's own proxies win, whole.
        try Data(#"{"proxies": {"http-proxy": "http://other:1"}}"#.utf8).write(to: file)
        #expect(try proxies()?["http-proxy"] as? String == "http://other:1")
        #expect(try proxies()?["https-proxy"] == nil)
    }

    @Test func engineConfigKeepsUserSettingsUnderDmxKeys() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "dmx-daemon-json-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = DockerEngineConfig.file(configDir: dir)

        // No file: dmx's keys alone.
        let none = try DockerEngineConfig.build(userFile: file)
        let bare = try JSONSerialization.jsonObject(with: Data(none.json.utf8)) as? [String: Any]
        #expect(bare?["hosts"] as? [String] == ["unix:///var/run/docker.sock"])
        #expect(bare?["shutdown-timeout"] as? Int == 5)
        #expect(none.ignored.isEmpty)

        try Data(#"{"registry-mirrors": ["https://mirror.example"], "hosts": ["tcp://0.0.0.0:2375"], "data-root": "/x", "builder": {"gc": {"enabled": true}}}"#.utf8).write(to: file)
        let merged = try DockerEngineConfig.build(userFile: file)
        let object = try JSONSerialization.jsonObject(with: Data(merged.json.utf8)) as? [String: Any]
        #expect(object?["registry-mirrors"] as? [String] == ["https://mirror.example"])
        #expect(object?["builder"] != nil)
        #expect(object?["hosts"] as? [String] == ["unix:///var/run/docker.sock"])
        #expect(object?["data-root"] == nil)
        #expect(merged.ignored == ["data-root", "hosts"])

        for bad in ["{\"registry-mirrors\": [", "[1, 2]"] {
            try Data(bad.utf8).write(to: file)
            #expect(throws: DMXError.self) { try DockerEngineConfig.build(userFile: file) }
        }
    }

    @Test func engineLoggingDefaultsRespectExplicitChoices() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "dmx-log-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("daemon.json")
        func build(_ input: String) throws -> [String: Any] {
            try Data(input.utf8).write(to: file)
            let json = try DockerEngineConfig.build(userFile: file).json
            return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        let bare = try build("{}")
        #expect(bare["log-driver"] as? String == "json-file")
        #expect(bare["log-opts"] as? [String: String] == ["max-size": "10m", "max-file": "2"])
        let custom = try build(#"{"log-driver":"json-file","log-opts":{"max-size":"25m","labels":"task"}}"#)
        #expect(custom["log-opts"] as? [String: String] == ["max-size": "25m", "max-file": "2", "labels": "task"])
        for driver in ["local", "none", "syslog"] {
            let other = try build("{\"log-driver\":\"\(driver)\"}")
            #expect(other["log-driver"] as? String == driver)
            #expect(other["log-opts"] == nil)
        }
        let other = try build(#"{"log-driver":"syslog","log-opts":{"syslog-address":"udp://localhost:514"}}"#)
        #expect(other["log-opts"] as? [String: String] == ["syslog-address": "udp://localhost:514"])
        for bad in [#"{"log-opts":{"max-size":10}}"#, #"{"log-opts":[]}"#, #"{"log-opts":null}"#] {
            #expect(throws: DMXError.self) { try build(bad) }
        }
    }

    @Test func contextInstallAndUninstall() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "dmx-docker-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("config.json")
        try Data(#"{"auths": {"example.com": {}}, "currentContext": "other"}"#.utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)

        let socket = URL(fileURLWithPath: "/tmp/dmx-x/docker.sock")
        let report = try DockerContext.install(socket: socket, configDir: dir)
        #expect(report == DockerContext.Report(name: "dmx", host: "unix:///tmp/dmx-x/docker.sock", configDir: dir.path, selected: true))
        // The docker CLI's store: meta.json under the sha256 of the name.
        let metaDir = DockerContext.metaDir(dir)
        #expect(metaDir.lastPathComponent.count == 64)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: metaDir.appendingPathComponent("meta.json"))) as? [String: Any]
        #expect(object?["Name"] as? String == "dmx")
        #expect(((object?["Endpoints"] as? [String: Any])?["docker"] as? [String: Any])?["Host"] as? String == "unix:///tmp/dmx-x/docker.sock")
        var saved = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
        #expect(saved?["currentContext"] as? String == "dmx")
        #expect(saved?["auths"] != nil)
        #expect(try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int == 0o600)

        try DockerContext.uninstall(configDir: dir)
        saved = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
        #expect(saved?["currentContext"] == nil)
        #expect(saved?["auths"] != nil)
        #expect(!FileManager.default.fileExists(atPath: metaDir.path))
    }

    @Test func socketLinkTakesOnlyAFreePath() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "dmx-sock-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let socket = dir.appendingPathComponent("dmx/docker.sock")
        let link = dir.appendingPathComponent(".docker/run/docker.sock")
        let fm = FileManager.default

        // A free path (and a missing directory) gets the link; a second install changes nothing.
        #expect(DockerSocketLink.install(socket: socket, link: link).linked)
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == socket.path)
        #expect(DockerSocketLink.install(socket: socket, link: link) == .init(path: link.path, target: socket.path, linked: true, skipped: nil))

        // Docker Desktop serving its socket there keeps it; once nothing serves it, dmx takes over.
        unlink(link.path)
        var address = try unixAddress(link)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0)
        listen(fd, 1)
        let kept = DockerSocketLink.install(socket: socket, link: link)
        #expect(!kept.linked && kept.skipped != nil)
        close(fd)
        #expect(DockerSocketLink.install(socket: socket, link: link).linked)

        // A link to another engine's existing socket stays; a dangling one is replaced.
        let other = dir.appendingPathComponent("other.sock")
        try Data().write(to: other)
        unlink(link.path)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: other.path)
        #expect(!DockerSocketLink.install(socket: socket, link: link).linked)
        DockerSocketLink.uninstall(socket: socket, link: link)
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == other.path)
        try fm.removeItem(at: other)
        #expect(DockerSocketLink.install(socket: socket, link: link).linked)

        DockerSocketLink.uninstall(socket: socket, link: link)
        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil)
    }

    @Test func contextLeavesABrokenConfigAlone() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "dmx-docker-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("config.json"))
        #expect(throws: DMXError.self) { try DockerContext.install(socket: URL(fileURLWithPath: "/tmp/d.sock"), configDir: dir) }
        #expect(try String(contentsOf: dir.appendingPathComponent("config.json"), encoding: .utf8) == "not json")
    }

    @Test func launchdJobHasBothSockets() throws {
        let paths = Paths(environment: ["DMX_HOME": "/tmp/dmx-x"])
        let data = try LaunchAgent.plistData(paths: paths, executable: "/usr/local/bin/dmx")
        let job = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let sockets = job?["Sockets"] as? [String: [String: Any]]
        #expect(sockets?["Listeners"]?["SockPathName"] as? String == "/tmp/dmx-x/dmx.sock")
        #expect(sockets?["Docker"]?["SockPathName"] as? String == "/tmp/dmx-x/docker.sock")
        #expect(sockets?["Docker"]?["SockPathMode"] as? Int == 0o600)
    }

    @Test func publishedPorts() {
        let containers: [[String: Any]] = [
            ["Ports": [
                ["IP": "0.0.0.0", "PrivatePort": 80, "PublicPort": 8080, "Type": "tcp"],
                ["IP": "::", "PrivatePort": 80, "PublicPort": 8080, "Type": "tcp"],
                ["IP": "0.0.0.0", "PrivatePort": 53, "PublicPort": 5353, "Type": "udp"],
                ["PrivatePort": 9000, "Type": "tcp"],
            ]],
            ["Ports": [["IP": "127.0.0.1", "PrivatePort": 80, "PublicPort": 8081, "Type": "tcp"]]],
        ]
        #expect(DockerBridge.published(containers) == [
            PortForward(hostAddress: "0.0.0.0", hostPort: 8080, guestPort: 8080),
            PortForward(hostAddress: "0.0.0.0", hostPort: 5353, guestPort: 5353, proto: "udp"),
            PortForward(hostAddress: "127.0.0.1", hostPort: 8081, guestPort: 8081),
        ])
    }

    /// The ports reserved before a container starts, from its HostConfig as dockerd stores it.
    @Test func portBindingsBeforeStart() {
        let container: [String: Any] = ["HostConfig": [
            "NetworkMode": "bridge",
            "PortBindings": [
                "80/tcp": [["HostIp": "", "HostPort": "8080"], ["HostIp": "::", "HostPort": "8080"]],
                "53/udp": [["HostIp": "127.0.0.1", "HostPort": "5353"]],
                "81/tcp": [["HostIp": "", "HostPort": ""]],
                "82/tcp": [["HostIp": "", "HostPort": "9000-9010"]],
                "83/sctp": [["HostIp": "", "HostPort": "9100"]],
                "84/tcp": [["HostIp": "10.0.0.1", "HostPort": "9200"]],
            ],
        ]]
        #expect(DockerBridge.bindings(container) == [
            PortForward(hostAddress: "127.0.0.1", hostPort: 5353, guestPort: 5353, proto: "udp"),
            PortForward(hostAddress: "0.0.0.0", hostPort: 8080, guestPort: 8080),
        ])
        #expect(DockerBridge.bindings(["HostConfig": ["NetworkMode": "host", "PortBindings": ["80/tcp": [["HostPort": "80"]]]]]).isEmpty)
    }

    /// Which requests the Docker socket's proxy acts on, and how it finds where they end.
    @Test func dockerRequests() throws {
        func request(_ text: String) -> DockerRequest? { DockerRequest(Data(text.utf8)) }
        let start = try #require(request("POST /v1.51/containers/abc123/start HTTP/1.1\r\nHost: api.moby.localhost\r\nContent-Length: 0\r\n\r\n"))
        #expect(start.startedContainer == "abc123" && start.body == .none && !start.upgrades)
        #expect(request("POST /containers/web/restart?t=2 HTTP/1.1\r\nHost: docker\r\n\r\n")?.startedContainer == "web")
        #expect(request("GET /v1.51/containers/abc/start HTTP/1.1\r\n\r\n")?.startedContainer == nil)
        #expect(request("POST /v1.51/containers/create?name=x HTTP/1.1\r\nContent-Length: 12\r\n\r\n")?.startedContainer == nil)
        #expect(request("POST /v1.51/containers/create HTTP/1.1\r\nContent-Length: 12\r\n\r\n")?.body == .length(12))
        #expect(request("POST /build HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")?.body == .chunked)
        let attach = try #require(request("POST /v1.51/containers/abc/attach?stream=1 HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n"))
        #expect(attach.upgrades && attach.startedContainer == nil)
        #expect(request("POST /x HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n") == nil)
        #expect(request("not http\r\n\r\n") == nil)
    }

    @Test func portSpecs() throws {
        #expect(try PortForward(parsing: "5353:53/udp") == PortForward(hostPort: 5353, guestPort: 53, proto: "udp"))
        #expect(try PortForward(parsing: "0.0.0.0:8080:80/tcp") == PortForward(hostAddress: "0.0.0.0", hostPort: 8080, guestPort: 80))
        #expect(throws: DMXError.self) { try PortForward(parsing: "8080:80/sctp") }
        #expect(PortForward(hostPort: 53, guestPort: 53, proto: "udp").overlaps(PortForward(hostPort: 53, guestPort: 53)) == false)
    }

    /// A query as a resolver sends it: id, RD set, one question, an EDNS record after it.
    func query(_ name: String, type: UInt16) -> [UInt8] {
        var q: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 1]
        for label in name.split(separator: ".") { q.append(UInt8(label.utf8.count)); q += Array(label.utf8) }
        q += [0, UInt8(type >> 8), UInt8(type & 0xff), 0, 1]
        q += [0, 0, 41, 4, 0xd0, 0, 0, 0, 0, 0, 0]
        return q
    }

    /// Reads a name at `offset`, following pointers, as a resolver's parser does; `offset` ends
    /// just past the name where it first appears. Pointers must lead backwards.
    func readName(_ m: [UInt8], _ offset: inout Int) throws -> String {
        var labels: [String] = []
        var at = offset, jumped = false
        while true {
            let length = Int(m[at])
            if length & 0xc0 == 0xc0 {
                let target = (length & 0x3f) << 8 | Int(m[at + 1])
                try #require(target < at)
                if !jumped { offset = at + 2 }
                jumped = true
                at = target
            } else if length == 0 {
                if !jumped { offset = at + 1 }
                return labels.joined(separator: ".")
            } else {
                labels.append(String(decoding: m[(at + 1)..<(at + 1 + length)], as: UTF8.self))
                at += 1 + length
            }
        }
    }

    /// One DNS over TCP connection driven through a socket pair with a scripted resolver.
    final class DNSPipe {
        let queue = DispatchQueue(label: "dns-tcp-test")
        let client: Int32
        var connection: DNSConnection?
        var finished = false
        var waiting: [(id: UInt16, reply: ([UInt8]) -> Void)] = []

        /// `immediate` answers every query at once; otherwise replies wait for `release`.
        init(immediate: Bool) {
            var pair: [Int32] = [0, 0]
            socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
            client = pair[0]
            queue.sync {
                connection = DNSConnection(fd: pair[1], queue: queue, answer: { [unowned self] query, reply in
                    let response = DNSConnection.failure(query, code: 0)
                    if immediate { reply(response) } else { self.waiting.append((query.u16(0), { _ in reply(response) })) }
                }, finished: { [unowned self] _ in self.finished = true })
            }
        }

        /// Ends the connection, whose socket events would otherwise outlive it.
        func finish() {
            queue.sync { connection?.close() }
            close(client)
        }

        func send(_ bytes: [UInt8]) { bytes.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) } }

        func frame(id: UInt16) -> [UInt8] {
            var q: [UInt8] = []
            q.be16(14)
            q.be16(id)
            q += [0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]
            return q
        }

        /// The ids of the next `count` replies.
        func replies(_ count: Int) -> [UInt16] {
            var ids: [UInt16] = []
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            for _ in 0..<count {
                var head = [UInt8](repeating: 0, count: 2 + 12)
                var got = 0
                while got < head.count {
                    let n = head.withUnsafeMutableBytes { read(client, $0.baseAddress! + got, $0.count - got) }
                    if n <= 0 { return ids }
                    got += n
                }
                ids.append(UInt16(head[2]) << 8 | UInt16(head[3]))
            }
            return ids
        }

        func waitUntil(_ condition: () -> Bool) -> Bool {
            for _ in 0..<500 {
                if queue.sync(execute: condition) { return true }
                usleep(10_000)
            }
            return false
        }
    }

    @Test func dnsOverTCPAnswersInOrderAcrossSplitWrites() throws {
        let pipe = DNSPipe(immediate: true)
        defer { pipe.finish() }
        // Two queries in one write, then one split across three.
        pipe.send(pipe.frame(id: 1) + pipe.frame(id: 2))
        #expect(pipe.replies(2) == [1, 2])
        let third = pipe.frame(id: 3)
        pipe.send(Array(third[..<1]))
        usleep(20_000)
        pipe.send(Array(third[1..<5]))
        usleep(20_000)
        pipe.send(Array(third[5...]))
        #expect(pipe.replies(1) == [3])
    }

    @Test func dnsOverTCPKeepsReplyOrderAndItsLimit() throws {
        let pipe = DNSPipe(immediate: false)
        defer { pipe.finish() }
        for id in 1...UInt16(DNSConnection.maxInFlight + 2) { pipe.send(pipe.frame(id: id)) }
        // No more than the limit starts until a reply goes out.
        #expect(pipe.waitUntil { pipe.waiting.count == DNSConnection.maxInFlight })
        usleep(50_000)
        #expect(pipe.queue.sync { pipe.waiting.count } == DNSConnection.maxInFlight)
        // Answered last to first, the replies still go out as asked.
        pipe.queue.sync {
            let started = pipe.waiting
            pipe.waiting.removeAll()
            for entry in started.reversed() { entry.reply([]) }
        }
        #expect(pipe.replies(DNSConnection.maxInFlight) == Array(1...UInt16(DNSConnection.maxInFlight)))
        // Those that waited start now.
        #expect(pipe.waitUntil { pipe.waiting.count == 2 })
        pipe.queue.sync {
            let started = pipe.waiting
            pipe.waiting.removeAll()
            for entry in started { entry.reply([]) }
        }
        #expect(pipe.replies(2) == [UInt16(DNSConnection.maxInFlight + 1), UInt16(DNSConnection.maxInFlight + 2)])
    }

    @Test func dnsOverTCPFinishesWhatWasAskedBeforeTheClientClosedItsSide() throws {
        let pipe = DNSPipe(immediate: false)
        defer { pipe.finish() }
        pipe.send(pipe.frame(id: 7))
        shutdown(pipe.client, SHUT_WR)
        #expect(pipe.waitUntil { pipe.waiting.count == 1 })
        usleep(20_000)
        #expect(pipe.queue.sync { !pipe.finished })
        pipe.queue.sync { pipe.waiting.removeFirst().reply([]) }
        #expect(pipe.replies(1) == [7])
        #expect(pipe.waitUntil { pipe.finished })
        // A length too short to hold a header ends the connection.
        let bad = DNSPipe(immediate: true)
        defer { bad.finish() }
        bad.send([0, 3, 1, 2, 3])
        #expect(bad.waitUntil { bad.finished })
    }

    @Test func dnsFailureKeepsTheQuerysIdAndRecursionFlag() {
        let reply = query("a.b", type: 252).withUnsafeBytes { DNSConnection.failure($0, code: 4) }
        #expect(reply == [0x12, 0x34, 0x81, 0x84, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func localNames() {
        let a = query("Host.Docker.Internal", type: 1).withUnsafeBytes { LocalDNS.answer($0) }
        #expect(a != nil)
        if let a {
            #expect(Array(a[0..<2]) == [0x12, 0x34])
            #expect(a[2] & 0x80 != 0 && a[3] & 0x0f == 0)  // a response, no error
            #expect(Array(a[6..<8]) == [0, 1])             // one answer
            #expect(Array(a.suffix(4)) == [192, 168, 127, 254])
        }
        let aaaa = query("gateway.docker.internal", type: 28).withUnsafeBytes { LocalDNS.answer($0) }
        #expect(aaaa.map { Array($0[6..<8]) } == [0, 1])
        #expect(aaaa.map { Array($0.suffix(16)) } == [0xfd, 0x64, 0x64, 0x6d, 0x78, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        let txt = query("host.dmx.internal", type: 16).withUnsafeBytes { LocalDNS.answer($0) }
        #expect(txt.map { Array($0[6..<8]) } == [0, 0])      // no such record, no error
        #expect(query("example.com", type: 1).withUnsafeBytes { LocalDNS.answer($0) } == nil)
    }

    @Test func localNetworkAccessReadsTheSocketErrors() {
        #expect(LocalNetworkAccess.classify(connectError: 0, sendError: 0) == .allowed)
        #expect(LocalNetworkAccess.classify(connectError: 0, sendError: EPIPE) == .blocked)
        // No route is not the permission, and neither is anything else.
        #expect(LocalNetworkAccess.classify(connectError: ENETUNREACH, sendError: 0) == .unknown)
        #expect(LocalNetworkAccess.classify(connectError: EHOSTUNREACH, sendError: 0) == .unknown)
        #expect(LocalNetworkAccess.classify(connectError: 0, sendError: ENOBUFS) == .unknown)

        #expect(localNetworkCheck(nil) == nil)
        #expect(localNetworkCheck(.allowed)?.hint == nil)
        // Blocked names what to do but is not a failure: the engine works.
        let blocked = localNetworkCheck(.blocked)
        #expect(blocked?.ok == true && blocked?.hint?.contains("Local Network") == true)

        // The field survives the socket, and an older daemon that lacks it still decodes.
        var status = DaemonStatus.notRunning(Paths(environment: ["DMX_HOME": "/tmp/dmx-unused"]), config: Config())
        status.localNetwork = .blocked
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = try! encoder.encode(status)
        #expect(String(decoding: data, as: UTF8.self).contains("\"local_network\":\"blocked\""))
        #expect(try! decoder.decode(DaemonStatus.self, from: data).localNetwork == .blocked)
        // A state a newer daemon adds does not make the status unreadable.
        #expect(try! decoder.decode(LocalNetworkAccess.self, from: Data("\"later\"".utf8)) == .unknown)
        status.localNetwork = nil
        #expect(try! decoder.decode(DaemonStatus.self, from: encoder.encode(status)).localNetwork == nil)
    }

    @Test func unansweredAAAAIsEmptyOnceTheNameHasAnAddress() throws {
        let question = try #require(query("Pypi.org", type: 28).withUnsafeBytes { HostDNS.Question($0) })
        #expect(question.isAAAA && !question.isA && question.key == "pypi.org.")
        let queue = DispatchQueue(label: "dns-test")
        let lookup = HostDNS.Lookup(question: question, queue: queue) { _ in }
        // Nothing known: no answer is still a failure, which the client may retry.
        #expect(lookup.response()[3] & 0x0f == 2)
        queue.sync {
            lookup.arm(.seconds(30))
            lookup.addressFound(grace: .seconds(30))
        }
        let reply = lookup.response()
        #expect(reply[3] & 0x0f == 0 && Array(reply[6..<8]) == [0, 0])
        queue.sync { lookup.timer?.cancel() }

        // An A lookup with no address never gets this treatment and keeps its failure.
        let a = try #require(query("pypi.org", type: 1).withUnsafeBytes { HostDNS.Question($0) })
        let plain = HostDNS.Lookup(question: a, queue: queue) { _ in }
        #expect(a.isA && a.key == question.key && !plain.hasIPv4Address && plain.response()[3] & 0x0f == 2)
        let add = DNSServiceFlags(kDNSServiceFlagsAdd)
        plain.received(flags: add | DNSServiceFlags(kDNSServiceFlagsMoreComing), error: 0, name: "pypi.org.", type: 1, qclass: 1, rdata: Data([151, 101, 0, 223]), ttl: 60)
        #expect(plain.hasIPv4Address)
    }

    @Test func addressFoundShortensTheWaitButNeverExtendsIt() throws {
        let question = try #require(query("pypi.org", type: 28).withUnsafeBytes { HostDNS.Question($0) })
        let queue = DispatchQueue(label: "dns-test")
        func ended(arm: Duration, grace: Duration) -> Bool {
            let lookup = HostDNS.Lookup(question: question, queue: queue) { _ in }
            let done = DispatchSemaphore(value: 0)
            lookup.finish = { done.signal() }
            queue.sync {
                lookup.arm(arm)
                lookup.addressFound(grace: grace)
            }
            defer { queue.sync { lookup.timer?.cancel() } }
            return done.wait(timeout: .now() + 5) == .success
        }
        #expect(ended(arm: .seconds(60), grace: .milliseconds(20)))
        #expect(ended(arm: .milliseconds(20), grace: .seconds(60)))
    }

    @Test func recentAddressesExpireAndStayBounded() {
        var recent = HostDNS.RecentAddresses()
        let start = ContinuousClock.now
        recent.note("pypi.org.", now: start)
        #expect(recent.contains("pypi.org.", now: start + .seconds(1)))
        #expect(!recent.contains("pypi.org.", now: start + HostDNS.RecentAddresses.horizon))
        #expect(!recent.contains("example.org.", now: start))
        for i in 0..<(HostDNS.RecentAddresses.capacity * 3) { recent.note("n\(i).", now: start + .seconds(i % 2)) }
        #expect(recent.count <= HostDNS.RecentAddresses.capacity)
        // Full of live names: a repeat answer evicts nothing, and a new name evicts only the oldest.
        var full = HostDNS.RecentAddresses()
        for i in 0..<HostDNS.RecentAddresses.capacity { full.note("n\(i).", now: start + .milliseconds(i)) }
        full.note("n5.", now: start + .seconds(1))
        #expect(full.count == HostDNS.RecentAddresses.capacity && full.contains("n0.", now: start + .seconds(1)))
        full.note("new.", now: start + .seconds(1))
        #expect(full.contains("new.", now: start + .seconds(1)) && !full.contains("n0.", now: start + .seconds(1)) && full.contains("n1.", now: start + .seconds(1)))
    }

    @Test func hostResolverReplies() throws {
        let question = try #require(query("www.Example.com", type: 1).withUnsafeBytes { HostDNS.Question($0) })
        #expect(question.name == "www.Example.com." && question.type == 1 && question.udpLimit == 1232)
        var sent: [UInt8]?
        let lookup = HostDNS.Lookup(question: question, queue: .main) { sent = $0 }
        let add = DNSServiceFlags(kDNSServiceFlagsAdd), more = DNSServiceFlags(kDNSServiceFlagsMoreComing)
        var cname: [UInt8] = []
        for label in ["example", "com"] { cname.append(UInt8(label.count)); cname += Array(label.utf8) }
        cname.append(0)
        lookup.received(flags: add | more, error: 0, name: "www.Example.com.", type: 5, qclass: 1, rdata: Data(cname), ttl: 60)
        lookup.received(flags: add | more, error: 0, name: "example.com.", type: 1, qclass: 1, rdata: Data([127, 0, 0, 1]), ttl: 60)
        lookup.received(flags: add | more, error: 0, name: "example.com.", type: 1, qclass: 1, rdata: Data([127, 0, 1, 1]), ttl: 60)
        lookup.received(flags: add | more, error: 0, name: "example.com.", type: 1, qclass: 1, rdata: Data([93, 184, 215, 14]), ttl: 60)
        let reply = lookup.response()
        #expect(Array(reply[0..<2]) == [0x12, 0x34])
        #expect(reply[2] == 0x81 && reply[3] == 0x80)  // response, RD, RA, NOERROR
        #expect(Array(reply[6..<8]) == [0, 3])          // the CNAME, the Mac's loopback as the host, the address
        #expect(reply.count > 0 && sent == nil)
        let bytes = Data(reply)
        #expect(bytes.range(of: Data([192, 168, 127, 254])) != nil && bytes.range(of: Data([127, 0, 1, 1])) == nil)

        // IPv6: the Mac's ::1 is the host's address in the guest network; link-local goes.
        #expect(HostDNS.Lookup.forGuest(type: 28, Data(repeating: 0, count: 15) + [1]) == Data(UserNet.host6.bytes))
        #expect(HostDNS.Lookup.forGuest(type: 28, Data([0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [1])) == nil)
        #expect(HostDNS.Lookup.routable(Data(repeating: 0, count: 15) + [1]))
        #expect(UserNet.host6.bytes == [0xfd, 0x64, 0x64, 0x6d, 0x78, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02, 0x54])
        #expect(IPAddress(v4: 0xc0a8_7f01).isV4 && !UserNet.gateway6.isV4 && UserNet.gateway.v4 == 0xc0a8_7f01)

        // Without EDNS a reply larger than 512 bytes is cut and marked truncated.
        var plain = query("big.example.com", type: 16)
        plain[11] = 0
        plain.removeLast(11)
        let small = try #require(plain.withUnsafeBytes { HostDNS.Question($0) })
        #expect(small.udpLimit == 512)
        let txt = HostDNS.Lookup(question: small, queue: .main) { _ in }
        for _ in 0..<5 { txt.received(flags: add | more, error: 0, name: "big.example.com.", type: 16, qclass: 1, rdata: Data(repeating: 0x41, count: 200), ttl: 60) }
        let cut = txt.response()
        #expect(cut.count <= 512 && cut[2] & 0x02 != 0)

        // An S3 bucket's name: a CNAME and eight addresses fit once names are compressed, and a
        // parser that follows the pointers reads the names back.
        var plainBucket = query("my-bucket.s3.ap-northeast-2.amazonaws.com", type: 1)
        plainBucket[11] = 0
        plainBucket.removeLast(11)
        let bucketQuestion = try #require(plainBucket.withUnsafeBytes { HostDNS.Question($0) })
        let bucket = HostDNS.Lookup(question: bucketQuestion, queue: .main) { _ in }
        var target: [UInt8] = []
        for label in ["s3-r-w", "ap-northeast-2", "amazonaws", "com"] { target.append(UInt8(label.count)); target += Array(label.utf8) }
        target.append(0)
        bucket.received(flags: add | more, error: 0, name: "my-bucket.s3.ap-northeast-2.amazonaws.com.", type: 5, qclass: 1, rdata: Data(target), ttl: 60)
        for i in 1...8 { bucket.received(flags: add | more, error: 0, name: "S3-r-w.ap-northeast-2.amazonaws.com.", type: 1, qclass: 1, rdata: Data([3, 5, 189, UInt8(i)]), ttl: 5) }
        let fits = bucket.response()
        #expect(fits.count < 300 && fits[2] & 0x02 == 0 && Array(fits[6..<8]) == [0, 9])
        var at = 12 + bucketQuestion.wire.count
        #expect(try readName(fits, &at) == "my-bucket.s3.ap-northeast-2.amazonaws.com")
        at += 10
        var data = at
        #expect(try readName(fits, &data) == "s3-r-w.ap-northeast-2.amazonaws.com")
        #expect(Int(fits[at - 2]) << 8 | Int(fits[at - 1]) == data - at)
        at = data
        for i in 1...8 {
            #expect(try readName(fits, &at).lowercased() == "s3-r-w.ap-northeast-2.amazonaws.com")
            at += 10
            #expect(Array(fits[at..<at + 4]) == [3, 5, 189, UInt8(i)])
            at += 4
        }
        #expect(at == fits.count)

        // What is cut is whole records, and a larger limit (DNS over TCP) keeps them all.
        let many = HostDNS.Lookup(question: small, queue: .main) { _ in }
        let wide = HostDNS.Lookup(question: small, limit: DNSConnection.maxReply, queue: .main) { _ in }
        for lookup in [many, wide] {
            for i in 0..<200 { lookup.received(flags: add | more, error: 0, name: "big.example.com.", type: 16, qclass: 1, rdata: Data([1, UInt8(i)]), ttl: 60) }
        }
        let shortened = many.response(), whole = wide.response()
        #expect(shortened.count <= 512 && shortened[2] & 0x02 != 0 && (shortened.count - 12 - small.wire.count) % 14 == 0)
        #expect(whole[2] & 0x02 == 0 && Array(whole[6..<8]) == [0, 200])

        // No such record (or name): an empty NOERROR.
        let none = HostDNS.Lookup(question: question, queue: .main) { _ in }
        none.received(flags: add, error: DNSServiceErrorType(kDNSServiceErr_NoSuchRecord), name: "www.Example.com.", type: 1, qclass: 1, rdata: Data(), ttl: 60)
        let empty = none.response()
        #expect(empty[3] & 0x0f == 0 && Array(empty[6..<8]) == [0, 0])
        #expect(query("a.b", type: 1).withUnsafeBytes { bytes in Array(bytes).withUnsafeBytes { HostDNS.Question($0) } } != nil)
    }
}
