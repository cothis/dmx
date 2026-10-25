import Foundation

/// dockerd's `daemon.json`: the user's Docker Engine settings with dmx's own keys on top. The
/// user's file is `daemon.json` in the docker config directory (`~/.docker`, or `$DOCKER_CONFIG`),
/// where Docker Desktop keeps its Docker Engine settings, so registry mirrors, insecure
/// registries, proxies or BuildKit's garbage collection carry over. Read when dockerd starts,
/// once per boot: `dmx stop` applies a change.
enum DockerEngineConfig {
    /// What dmx needs dockerd to do. `host-gateway-ips` is the Mac (its IPv4 and IPv6 address in
    /// the guest network), so `--add-host x:host-gateway` works as on Docker Desktop; the host
    /// powers the guest off within 10 s, so containers get 5 s to stop.
    static var required: [String: Any] { [
        "hosts": ["unix:///var/run/docker.sock"],
        "host-gateway-ips": ["192.168.127.254", "fd64:646d:7800::254"],
        "shutdown-timeout": 5,
    ] }
    /// Keys only dmx sets: the ones above, and the guest's own paths and sockets.
    static let owned: Set<String> = Set(required.keys).union(["data-root", "exec-root", "pidfile", "containerd"])

    static func file(configDir: URL = DockerContext.configDir()) -> URL {
        configDir.appendingPathComponent("daemon.json")
    }

    /// The JSON to give dockerd, and the user's keys left out because dmx owns them. The Mac's
    /// proxy becomes dockerd's `proxies` unless the user's file sets them.
    static func build(userFile: URL, proxy: HostProxy? = nil) throws -> (json: String, ignored: [String]) {
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: userFile) {
            let parsed: Any
            do {
                parsed = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw invalid(userFile, "it is not valid JSON")
            }
            guard let object = parsed as? [String: Any] else { throw invalid(userFile, "it is not a JSON object") }
            settings = object
        }
        let ignored = settings.keys.filter(owned.contains).sorted()
        for key in owned { settings[key] = nil }
        settings.merge(required) { _, dmx in dmx }
        if settings["proxies"] == nil, let proxy { settings["proxies"] = proxy.daemonJSON }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        return (String(decoding: data, as: UTF8.self), ignored)
    }

    private static func invalid(_ file: URL, _ why: String) -> DMXError {
        DMXError("docker_config_invalid", "\(file.path): \(why)",
                 hint: "fix the JSON or move the file away, then run the docker command again")
    }
}
