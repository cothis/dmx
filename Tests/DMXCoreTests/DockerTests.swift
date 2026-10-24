import Foundation
import Testing
@testable import DMXCore

/// The host side of Docker support that needs no VM: the docker context, the launchd job,
/// which published ports become forwards, and the names the gateway's DNS answers.
@Suite struct DockerTests {
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
        #expect(aaaa.map { Array($0[6..<8]) } == [0, 0])     // no IPv6 address, no error
        #expect(query("example.com", type: 1).withUnsafeBytes { LocalDNS.answer($0) } == nil)
    }
}
