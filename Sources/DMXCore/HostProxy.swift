import CFNetwork
import Foundation

/// The Mac's HTTP and HTTPS proxy (System Settings, Network, Proxies), as dockerd's `proxies`, so
/// image pulls work on a network whose only way out is a proxy, as on Docker Desktop. A proxy on
/// the Mac's loopback is reached from the guest at the gateway's host address. Proxy
/// auto-configuration (PAC) files are not evaluated.
public struct HostProxy: Equatable, Sendable {
    public var http: String?
    public var https: String?
    public var noProxy: [String]

    /// The Mac as the guest reaches it (`host.dmx.internal`, the NAT's host address).
    static let hostAddress = "192.168.127.254"
    /// Never through the proxy: the guest itself, the Mac, and the names dmx's DNS answers for it.
    static let always = ["localhost", "127.0.0.0/8", "192.168.127.0/24",
                         "host.docker.internal", "gateway.docker.internal", "host.dmx.internal"]

    public var isEmpty: Bool { http == nil && https == nil }

    /// What the system settings name now; nil when no HTTP or HTTPS proxy is on.
    public static func system() -> (proxy: HostProxy?, pac: Bool) {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return (nil, false) }
        return parse(settings)
    }

    /// `settings` in the shape of `CFNetworkCopySystemProxySettings` (`scutil --proxy`).
    static func parse(_ settings: [String: Any]) -> (proxy: HostProxy?, pac: Bool) {
        func url(_ prefix: String) -> String? {
            guard (settings["\(prefix)Enable"] as? Int ?? 0) != 0,
                  let host = settings["\(prefix)Proxy"] as? String, !host.isEmpty else { return nil }
            let port = settings["\(prefix)Port"] as? Int ?? 0
            let loopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
            let name = loopback ? hostAddress : host.contains(":") ? "[\(host)]" : host
            return "http://\(name)" + (port > 0 ? ":\(port)" : "")
        }
        let pac = (settings["ProxyAutoConfigEnable"] as? Int ?? 0) != 0
        let proxy = HostProxy(http: url("HTTP"), https: url("HTTPS"),
                              noProxy: Self.always + (settings["ExceptionsList"] as? [String] ?? []).compactMap(noProxyEntry))
        return (proxy.isEmpty ? nil : proxy, pac)
    }

    /// An exception as Go's NO_PROXY understands it: `*.local` → `.local`; macOS's short CIDR
    /// (`169.254/16`) gets its missing zero octets.
    static func noProxyEntry(_ exception: String) -> String? {
        let entry = exception.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return nil }
        if entry.hasPrefix("*.") { return String(entry.dropFirst()) }
        let parts = entry.split(separator: "/", maxSplits: 1)
        if parts.count == 2, let bits = Int(parts[1]), (0...32).contains(bits) {
            var octets = parts[0].split(separator: ".").map(String.init)
            guard (1...4).contains(octets.count), octets.allSatisfy({ UInt8($0) != nil }) else { return entry }
            while octets.count < 4 { octets.append("0") }
            return octets.joined(separator: ".") + "/\(bits)"
        }
        return entry
    }

    /// dockerd's `proxies` object.
    var daemonJSON: [String: Any] {
        var out: [String: Any] = ["no-proxy": noProxy.joined(separator: ",")]
        if let http { out["http-proxy"] = http }
        if let https { out["https-proxy"] = https }
        return out
    }
}
