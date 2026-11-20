import Foundation
import Testing
@testable import DMXCore

/// `dmx import` without engines: what it selects, the order it creates things in, and the create
/// requests it builds from another engine's inspect output. scripts/test-import.py runs it
/// against a real second engine.
@Suite struct ImportTests {
    static let webID = String(repeating: "a", count: 64)
    static let sideID = String(repeating: "b", count: 64)
    static let anon = String(repeating: "c", count: 64)

    static func container(_ id: String, _ name: String, inspect extra: [String: JSONValue] = [:], running: Bool = false,
                          labels: [String: String] = [:]) -> Import.Container {
        var inspect: [String: JSONValue] = [
            "Id": .string(id), "Name": .string("/" + name), "Image": "sha256:img",
            "Config": .object(["Hostname": .string(String(id.prefix(12))), "Image": "web:1", "MacAddress": "02:42:ac:11:00:02",
                               "Labels": .object(labels.mapValues(JSONValue.string))]),
            "HostConfig": .object(["NetworkMode": "proj_default", "Runtime": "runc"]),
        ]
        for (k, v) in extra { inspect[k] = v }
        return Import.Container(id: id, name: name, imageID: "sha256:img", running: running, labels: labels, inspect: .object(inspect))
    }

    @Test func buildsAContainerRequestWithoutWhatBelongedToTheOldContainer() {
        let c = Self.container(Self.webID, "web", inspect: [
            "NetworkSettings": .object(["Networks": .object([
                "proj_default": .object(["Aliases": .array(["web", .string(String(Self.webID.prefix(12)))]), "IPAMConfig": .null,
                                         "NetworkID": "old", "EndpointID": "old", "IPAddress": "172.18.0.2"]),
            ])]),
        ])
        let body = Import.containerBody(c, image: "web:1", containers: [c], runtimes: ["runc", "io.containerd.runc.v2"]) { _ in nil }
        #expect(body["Image"] == "web:1")
        #expect(body["Hostname"] == nil)
        #expect(body["MacAddress"] == nil)
        #expect(body["HostConfig"]?["Runtime"] == "runc")
        let endpoint = body["NetworkingConfig"]?["EndpointsConfig"]?["proj_default"]
        #expect(endpoint?["Aliases"] == ["web"])
        #expect(endpoint?["NetworkID"] == nil)
        #expect(endpoint?["IPAddress"] == nil)
        #expect(endpoint?["IPAMConfig"] == nil)
    }

    @Test func keepsAHostnameSomeoneChoseAndDropsARuntimeDmxLacks() {
        var c = Self.container(Self.webID, "web")
        var inspect = c.inspect.object!
        var config = inspect["Config"]!.object!
        config["Hostname"] = "db.local"
        inspect["Config"] = .object(config)
        var host = inspect["HostConfig"]!.object!
        host["Runtime"] = "sysbox-runc"
        inspect["HostConfig"] = .object(host)
        c = Import.Container(id: c.id, name: c.name, imageID: c.imageID, running: false, labels: [:], inspect: .object(inspect))
        let body = Import.containerBody(c, image: "web:1", containers: [c], runtimes: ["runc"]) { _ in nil }
        #expect(body["Hostname"] == "db.local")
        #expect(body["HostConfig"]?["Runtime"] == nil)
    }

    /// dockerd keeps `container:NAME` as written and Compose compares the ID, and a container in
    /// another's namespace shows that one's hostname, which dockerd refuses on create.
    @Test func namesAnotherContainerByItsNewIDAndDropsItsHostname() {
        let web = Self.container(Self.webID, "web")
        let side = Self.container(Self.sideID, "side", inspect: [
            "Config": .object(["Hostname": .string(String(Self.webID.prefix(12))), "Domainname": "x", "Image": "web:1"]),
            "HostConfig": .object(["NetworkMode": .string("container:" + Self.webID), "IpcMode": "container:web",
                                   "PidMode": "host", "VolumesFrom": .array([.string(String(Self.webID.prefix(12)) + ":ro"), ""])]),
        ])
        let body = Import.containerBody(side, image: "web:1", containers: [web, side], runtimes: []) { $0 == "web" ? "NEWID" : nil }
        #expect(body["HostConfig"]?["NetworkMode"] == "container:NEWID")
        #expect(body["HostConfig"]?["IpcMode"] == "container:NEWID")
        #expect(body["HostConfig"]?["PidMode"] == "host")
        #expect(body["HostConfig"]?["VolumesFrom"] == ["NEWID:ro"])
        #expect(body["Hostname"] == nil)
        #expect(body["Domainname"] == nil)
        #expect(body["NetworkingConfig"] == nil)
        // Created first, whatever the source listed first.
        #expect(Import.dependencies(side, containers: [web, side]) == ["web", "web", "web"])
    }

    @Test func ordersContainersAfterWhatTheyReferTo() throws {
        let web = Self.container(Self.webID, "web")
        let side = Self.container(Self.sideID, "side", inspect: [
            "HostConfig": .object(["NetworkMode": .string("container:" + Self.webID), "Links": ["/web:/side/web"]]),
        ])
        let inventory = Import.Inventory(containers: [side, web])
        let selection = try Import.Selection(inventory, projects: [])
        #expect(selection.orderedContainers.map(\.name) == ["web", "side"])
    }

    /// Image VOLUMEs and `-v /path` are anonymous; `-v name:/path`, binds and --mount with a
    /// source are not, and --volumes-from belongs to the other container.
    @Test func findsAnonymousVolumes() {
        let c = Self.container(Self.webID, "web", inspect: [
            "HostConfig": .object(["Binds": ["data:/data:rw", "/Users/me/src:/src"],
                                   "Mounts": .array([.object(["Type": "volume", "Source": "cache", "Target": "/cache"]),
                                                     .object(["Type": "volume", "Target": "/tmpvol"])])]),
            "Mounts": .array([
                .object(["Type": "volume", "Name": "data", "Destination": "/data"]),
                .object(["Type": "bind", "Source": "/Users/me/src", "Destination": "/src"]),
                .object(["Type": "volume", "Name": "cache", "Destination": "/cache"]),
                .object(["Type": "volume", "Name": .string(Self.anon), "Destination": "/var/lib/data"]),
                .object(["Type": "volume", "Name": "dddd", "Destination": "/tmpvol"]),
            ]),
        ])
        #expect(Import.anonymousVolumes(c).map(\.dest) == ["/var/lib/data", "/tmpvol"])
        let inherits = Self.container(Self.sideID, "side", inspect: [
            "HostConfig": .object(["VolumesFrom": ["web"]]),
            "Mounts": .array([.object(["Type": "volume", "Name": .string(Self.anon), "Destination": "/var/lib/data"])]),
        ])
        #expect(Import.anonymousVolumes(inherits).isEmpty)
    }

    @Test func selectsAComposeProjectAndWhatItUses() throws {
        let project = ["com.docker.compose.project": "shop"]
        let web = Self.container(Self.webID, "shop-web-1", inspect: [
            "Mounts": .array([.object(["Type": "volume", "Name": "shared", "Destination": "/s"]),
                              .object(["Type": "volume", "Name": .string(Self.anon), "Destination": "/a"])]),
            "NetworkSettings": .object(["Networks": .object(["shop_default": .object([:])])]),
        ], labels: project)
        let other = Self.container(Self.sideID, "blog-1", labels: ["com.docker.compose.project": "blog"])
        let inventory = Import.Inventory(
            images: [Import.Image(id: "sha256:img", tags: ["web:1"], digests: [], size: 1),
                     Import.Image(id: "sha256:other", tags: ["blog:1"], digests: [], size: 1)],
            volumes: [Import.Volume(name: "shop_data", driver: "local", labels: project, options: [:]),
                      Import.Volume(name: "shared", driver: "local", labels: [:], options: [:]),
                      Import.Volume(name: "blog_data", driver: "local", labels: ["com.docker.compose.project": "blog"], options: [:]),
                      Import.Volume(name: Self.anon, driver: "local", labels: [:], options: [:])],
            networks: [Import.Network(name: "bridge", id: "1", driver: "bridge", labels: [:], raw: [:]),
                       Import.Network(name: "shop_default", id: "2", driver: "bridge", labels: project, raw: [:]),
                       Import.Network(name: "blog_default", id: "3", driver: "bridge", labels: [:], raw: [:])],
            containers: [web, other])
        let shop = try Import.Selection(inventory, projects: ["shop"])
        #expect(shop.containers.map(\.name) == ["shop-web-1"])
        #expect(shop.images.map(\.id) == ["sha256:img"])
        // Anonymous volumes go with their containers, not on their own.
        #expect(shop.volumes.map(\.name) == ["shop_data", "shared"])
        #expect(shop.networks.map(\.name) == ["shop_default"])

        let all = try Import.Selection(inventory, projects: [])
        #expect(all.volumes.map(\.name) == ["shop_data", "shared", "blog_data"])
        #expect(all.networks.map(\.name) == ["shop_default", "blog_default"])

        #expect(throws: DMXError.self) { try Import.Selection(inventory, projects: ["nope"]) }
        do { _ = try Import.Selection(inventory, projects: ["nope"]) } catch let error as DMXError {
            #expect(error.code == "import_no_project")
            #expect(error.hint?.contains("blog, shop") == true)
        } catch {}
    }

    @Test func createsNetworksWithoutTheOtherVMsBridgeOrItsAutomaticSubnets() throws {
        let ipam: JSONValue = ["Driver": "default", "Config": [["Subnet": "172.30.0.0/16"]]]
        let network = Import.Network(name: "shop_default", id: "2", driver: "bridge", labels: ["com.docker.compose.network": "default"],
                                     raw: ["Internal": true, "IPAM": ipam,
                                           "Options": ["com.docker.network.bridge.name": "br-1234", "com.docker.network.driver.mtu": "1400"]])
        let plain = Self.container(Self.webID, "web", inspect: ["NetworkSettings": .object(["Networks": .object(["shop_default": .object([:])])])])
        let body = Import.networkBody(network, selection: try Import.Selection(Import.Inventory(containers: [plain]), projects: []))
        #expect(body["Internal"] == true)
        #expect(body["Options"] == ["com.docker.network.driver.mtu": "1400"])
        #expect(body["IPAM"] == nil)
        #expect(body["Labels"] == ["com.docker.compose.network": "default"])

        let fixed = Self.container(Self.webID, "web", inspect: ["NetworkSettings": .object(["Networks": .object([
            "shop_default": .object(["IPAMConfig": ["IPv4Address": "172.30.0.10"]]),
        ])])])
        let withIP = Import.networkBody(network, selection: try Import.Selection(Import.Inventory(containers: [fixed]), projects: []))
        #expect(withIP["IPAM"] == ipam)
    }

    @Test func warnsOfMacPathsDmxDoesNotShare() {
        let c = Self.container(Self.webID, "web", inspect: ["Mounts": .array([
            .object(["Type": "bind", "Source": "/Users/me/src"]), .object(["Type": "bind", "Source": "/tmp/x"]),
            .object(["Type": "bind", "Source": "/opt/homebrew/etc"]), .object(["Type": "bind", "Source": "/var/run/docker.sock"]),
            .object(["Type": "bind", "Source": "/etc/localtime"]),
        ])])
        #expect(Import.unsharedBinds(c, shares: Share.defaults) == ["/opt/homebrew/etc"])
        #expect(Import.unsharedBinds(c, shares: [Share(path: "/Users/me")]) == ["/tmp/x", "/opt/homebrew/etc"])
    }

    @Test func refusesASourceItCannotUse() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(environment: ["DMX_HOME": root.appendingPathComponent(".dmx").path])
        func code(_ from: String?) async -> String? {
            do { _ = try await Import.resolveSource(from, paths: paths, home: root); return nil } catch let e as DMXError {
                #expect(e.hint != nil)
                return e.code
            } catch { return "\(error)" }
        }
        #expect(await code("podman") == "import_bad_source")
        #expect(await code("unix://" + paths.dockerSocket.path) == "import_bad_source")
        #expect(await code("colima") == "import_source_unreachable")
        #expect(await code(nil) == "import_no_source")
    }
}
