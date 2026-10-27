import Foundation
import Testing
@testable import DMXCore

/// Installing the docker CLI and plugins, with stand-ins served from file URLs: placement,
/// sha256 checks, the docker config and the links on PATH.
@Suite struct DockerToolsTests {
    struct Fixture {
        let root: URL
        let paths: Paths
        let configDir: URL
        let environment: [String: String]
        let tools: [DockerTools.Tool]

        init() throws {
            let fm = FileManager.default
            root = URL(fileURLWithPath: NSTemporaryDirectory() + "dmx-tools-\(UUID().uuidString)")
            paths = Paths(environment: ["DMX_HOME": root.appendingPathComponent("dmx").path])
            configDir = root.appendingPathComponent("docker-config")
            let src = root.appendingPathComponent("src")
            try fm.createDirectory(at: src.appendingPathComponent("docker"), withIntermediateDirectories: true)
            try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
            try Data(#"{"auths": {"example.com": {}}, "cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]}"#.utf8)
                .write(to: configDir.appendingPathComponent("config.json"))

            let cli = Data("#!/bin/sh\necho cli\n".utf8)
            try cli.write(to: src.appendingPathComponent("docker/docker"))
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-czf", src.appendingPathComponent("docker.tgz").path, "-C", src.path, "docker/docker"]
            try tar.run()
            tar.waitUntilExit()
            let plugin = Data("#!/bin/sh\necho plugin\n".utf8)
            try plugin.write(to: src.appendingPathComponent("compose-bin"))

            let tgz = src.appendingPathComponent("docker.tgz")
            let tgzSize = try fm.attributesOfItem(atPath: tgz.path)[.size] as! Int
            tools = [
                DockerTools.Tool(name: "docker", version: "1", url: tgz, sha256: try sha256Hex(of: tgz), size: tgzSize,
                                 member: ("docker/docker", try sha256Hex(of: src.appendingPathComponent("docker/docker"))),
                                 file: "docker", plugin: false),
                DockerTools.Tool(name: "compose", version: "2", url: src.appendingPathComponent("compose-bin"),
                                 sha256: try sha256Hex(of: src.appendingPathComponent("compose-bin")), size: plugin.count,
                                 member: nil, file: "docker-compose", plugin: true),
            ]
            let home = root.appendingPathComponent("home")
            environment = ["HOME": home.path, "PATH": "\(home.path)/.local/bin:/usr/bin:/bin"]
        }
    }

    @Test func installTwiceThenUninstall() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let report = try await DockerTools.install(paths: f.paths, configDir: f.configDir, environment: f.environment, tools: f.tools)
        #expect(report.tools.map(\.state) == ["installed", "installed"])
        let docker = f.paths.dockerBin.appendingPathComponent("docker")
        #expect(FileManager.default.isExecutableFile(atPath: docker.path))
        #expect(FileManager.default.isExecutableFile(atPath: f.paths.cliPlugins.appendingPathComponent("docker-compose").path))
        #expect(!FileManager.default.fileExists(atPath: f.paths.downloads.path))
        let link = f.root.appendingPathComponent("home/.local/bin/docker")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == docker.path)
        #expect(report.links.map(\.state) == ["created"])
        #expect(report.dmxDockerOnPath && report.dockerOnPath == link.path && report.hint == nil)
        var config = try JSONSerialization.jsonObject(with: Data(contentsOf: f.configDir.appendingPathComponent("config.json"))) as? [String: Any]
        // Ours first, so it wins over Homebrew's copy of the same plugin; other keys kept.
        #expect(config?["cliPluginsExtraDirs"] as? [String] == [f.paths.cliPlugins.path, "/opt/homebrew/lib/docker/cli-plugins"])
        #expect(config?["auths"] != nil)

        let again = try await DockerTools.install(paths: f.paths, configDir: f.configDir, environment: f.environment, tools: f.tools)
        #expect(again.tools.map(\.state) == ["present", "present"])
        #expect(again.links.map(\.state) == ["present"])
        config = try JSONSerialization.jsonObject(with: Data(contentsOf: f.configDir.appendingPathComponent("config.json"))) as? [String: Any]
        #expect((config?["cliPluginsExtraDirs"] as? [String])?.count == 2)

        try DockerTools.uninstall(paths: f.paths, configDir: f.configDir, environment: f.environment, tools: f.tools)
        #expect(!FileManager.default.fileExists(atPath: docker.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
        config = try JSONSerialization.jsonObject(with: Data(contentsOf: f.configDir.appendingPathComponent("config.json"))) as? [String: Any]
        #expect(config?["cliPluginsExtraDirs"] as? [String] == ["/opt/homebrew/lib/docker/cli-plugins"])
        #expect(DockerTools.status(paths: f.paths, configDir: f.configDir, environment: f.environment, tools: f.tools).tools.map(\.state) == ["missing", "missing"])
    }

    @Test func mirrorServesTheSameFiles() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // Upstream is unreachable; the mirror has the files under their upstream names.
        let gone = f.tools.map { t in
            DockerTools.Tool(name: t.name, version: t.version, url: URL(fileURLWithPath: "/nonexistent/\(t.url.lastPathComponent)"),
                             sha256: t.sha256, size: t.size, member: t.member, file: t.file, plugin: t.plugin)
        }
        let mirror = f.root.appendingPathComponent("src").absoluteString
        var environment = f.environment
        environment["DMX_TOOLS_URL"] = mirror
        let report = try await DockerTools.install(paths: f.paths, configDir: f.configDir, environment: environment, tools: gone)
        #expect(report.tools.map(\.state) == ["installed", "installed"])
        #expect(report.tools.allSatisfy { $0.url.hasPrefix(mirror.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) })

        // The setting does the same when the variable is unset; the variable wins over it.
        var config = Config()
        try config.set("tools_url", "https://mirror.example.com/dmx-tools/")
        #expect(config.toolsUrl == "https://mirror.example.com/dmx-tools")
        try config.save(f.paths)
        let listed = DockerTools.status(paths: f.paths, configDir: f.configDir, environment: f.environment, tools: gone)
        #expect(listed.tools.first?.url == "https://mirror.example.com/dmx-tools/docker.tgz")
        #expect(DockerTools.status(paths: f.paths, configDir: f.configDir, environment: environment, tools: gone).tools.first?.url.hasPrefix("file:") == true)
        #expect(throws: DMXError.self) { try config.set("release_url", "ftp://mirror.example.com") }
        #expect(GuestStore(paths: f.paths, environment: [:]).baseURL == GuestRelease.defaultBaseURL)
        try config.set("release_url", "https://mirror.example.com/dmx")
        try config.save(f.paths)
        #expect(GuestStore(paths: f.paths, environment: [:]).baseURL == "https://mirror.example.com/dmx")
    }

    @Test func checksumMismatchDeletesTheDownload() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let t = f.tools[1]
        let bad = DockerTools.Tool(name: t.name, version: t.version, url: t.url, sha256: String(repeating: "0", count: 64),
                                   size: t.size, member: nil, file: t.file, plugin: true)
        do {
            _ = try await DockerTools.install(paths: f.paths, configDir: f.configDir, environment: f.environment, tools: [bad])
            Issue.record("installed a file with the wrong sha256")
        } catch let error as DMXError {
            #expect(error.code == "checksum_mismatch")
        }
        #expect(!FileManager.default.fileExists(atPath: f.paths.cliPlugins.appendingPathComponent("docker-compose").path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: f.paths.downloads.path))?.isEmpty ?? true)
    }

    @Test func leavesOtherFilesOnPathAlone() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let bin = f.root.appendingPathComponent("home/.local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bin.appendingPathComponent("docker"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("docker").path)
        let report = try await DockerTools.install(paths: f.paths, configDir: f.configDir, environment: f.environment, tools: f.tools)
        #expect(report.links.map(\.state) == ["skipped"])
        #expect(!report.dmxDockerOnPath && report.hint?.contains("export PATH") == true)
        try DockerTools.uninstall(paths: f.paths, configDir: f.configDir, environment: f.environment, tools: f.tools)
        #expect(FileManager.default.fileExists(atPath: bin.appendingPathComponent("docker").path))
    }

    @Test func replacesALinkThatPointsAtNothing() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let bin = f.root.appendingPathComponent("home/.local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // What a deleted DMX_HOME (or an uninstalled engine) leaves behind.
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("docker").path,
                                                   withDestinationPath: f.root.appendingPathComponent("gone/bin/docker").path)
        #expect(DockerTools.status(paths: f.paths, configDir: f.configDir, environment: f.environment, tools: f.tools)
            .links.map(\.state) == ["broken"])
        let report = try await DockerTools.install(paths: f.paths, configDir: f.configDir, environment: f.environment, tools: f.tools)
        #expect(report.links.map(\.state) == ["replaced"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bin.appendingPathComponent("docker").path)
            == f.paths.dockerBin.appendingPathComponent("docker").path)
        #expect(report.dmxDockerOnPath)
    }

    @Test func pinsAreComplete() {
        for tool in DockerTools.pinned {
            #expect(tool.sha256.count == 64 && tool.url.scheme == "https" && tool.size > 0)
        }
        #expect(Set(DockerTools.pinned.map(\.file)) == ["docker", "docker-credential-osxkeychain", "docker-compose", "docker-buildx"])
    }
}
