import Foundation

/// Whether macOS lets this process reach the local network (Privacy & Security > Local Network).
///
/// A process launchd started has no app to inherit the permission from, so the daemon `dmx install`
/// sets up needs its own, and until the Mac's owner answers macOS's prompt its sockets cannot reach
/// LAN addresses and, inside dmx.app, mDNSResponder does not answer `.local` names. The public
/// internet is not affected. A process started from a terminal inherits the terminal's permission,
/// so only the daemon can answer this for the VM; asking from the CLI would measure the wrong process.
public enum LocalNetworkAccess: String, Codable, Sendable {
    case allowed, blocked
    /// There is nothing to tell: no network, or an error that is not about the permission.
    case unknown

    /// A value from a newer daemon must not make the whole status unreadable.
    public init(from decoder: Decoder) throws {
        self = LocalNetworkAccess(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    public static let settings = "System Settings > Privacy & Security > Local Network"
    public static let blockedDetail = "macOS is blocking the engine's local network access: containers cannot reach LAN addresses and .local names may not resolve (the public internet works)"
    public static let blockedHint = "allow dmx in the macOS prompt or in \(settings) (an engine started from a terminal uses that terminal's entry)"
    /// The probe sees sockets. mDNSResponder decides `.local` names for dmx.app on its own, and a
    /// process started from a terminal can have open sockets and still get no answer from it.
    public static let allowedDetail = "containers can reach LAN addresses (.local names can still need dmx allowed in \(settings))"

    /// Link-local multicast is local network traffic by definition, needs no address of this
    /// network, and cannot leave the link. The discard port, not mDNS's: no responder sees it.
    private static let group: UInt32 = 0xe000_00fb  // 224.0.0.251
    private static let port: UInt16 = 9

    /// Asks the kernel by sending one empty datagram. Macs that have not decided get macOS's prompt
    /// from this, once, which is the point: the answer then holds for the first real connection.
    public static func probe() -> LocalNetworkAccess {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .unknown }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let endpoint = HostEndpoint.v4(group, port)
        if endpoint.withSockaddr({ connect(fd, $0, $1) }) != 0 { return classify(connectError: errno, sendError: 0) }
        return classify(connectError: 0, sendError: Darwin.send(fd, nil, 0, 0) < 0 ? errno : 0)
    }

    /// A blocked socket connects and then fails to send with EPIPE, which a datagram socket cannot
    /// get for any other reason. A route's absence (no network) is an error from `connect` and says
    /// nothing about the permission.
    static func classify(connectError: Int32, sendError: Int32) -> LocalNetworkAccess {
        if connectError != 0 { return .unknown }
        switch sendError {
        case 0: return .allowed
        case EPIPE: return .blocked
        default: return .unknown
        }
    }
}
