import Foundation
import Security

public struct Check: Encodable, Sendable {
    public let name: String
    public let ok: Bool
    public let detail: String
    public let hint: String?
}

public struct DoctorReport: Encodable, Sendable {
    public let ok: Bool
    public let home: String
    public let checks: [Check]
}

/// Everything that has to be true before `dmx boot` can work, in the order to fix it.
/// `daemon` is the version and pid of a daemon that answers, which only an async caller can ask
/// for: after an update the old daemon keeps serving, and that is worth saying here too.
public func runDoctor(paths: Paths, daemon: (version: String, pid: Int32)? = nil,
                      daemonError: DMXError? = nil) -> DoctorReport {
    var checks: [Check] = []
    let info = ProcessInfo.processInfo

    checks.append(Check(
        name: "hypervisor",
        ok: hvSupported,
        detail: "macOS \(info.operatingSystemVersionString), \(info.activeProcessorCount) cpus, \(formatSize(info.physicalMemory)) memory",
        hint: hvSupported ? nil : "Hypervisor.framework is unavailable on this Mac (kern.hv_support is 0)"
    ))

    let entitled = hasEntitlement("com.apple.security.hypervisor")
    checks.append(Check(
        name: "entitlement",
        ok: entitled,
        detail: entitled ? "com.apple.security.hypervisor present" : "binary is not signed with com.apple.security.hypervisor",
        hint: entitled ? nil : "build with `make build`"
    ))

    checks.append(guestCheck(GuestStore(paths: paths)))

    if let daemonError {
        // Reaching a daemon that speaks another protocol is a real problem: it is another dmx's,
        // and nothing of this one works against it until it is gone.
        checks.append(Check(name: "daemon", ok: false, detail: daemonError.message, hint: daemonError.hint))
    } else if let daemon {
        // Not a failure: the VM and its containers are fine where they are, and the user decides
        // when to hand them over.
        let same = daemon.version == dmxVersion
        checks.append(Check(
            name: "daemon",
            ok: true,
            detail: same ? "dmx \(daemon.version) (pid \(daemon.pid))"
                         : "the daemon running is dmx \(daemon.version) (pid \(daemon.pid)), this dmx is \(dmxVersion)",
            hint: same ? nil : "`dmx stop` powers the VM off and the daemon exits; the next command runs \(dmxVersion)"
        ))
    }

    return DoctorReport(ok: checks.allSatisfy(\.ok), home: paths.home.path, checks: checks)
}

/// Where the guest came from, whether it is intact, and whether the next boot downloads one.
func guestCheck(_ store: GuestStore) -> Check {
    let state = store.state()
    let size = store.pin.map { formatSize(UInt64($0.bytes)) } ?? ""
    switch state.source {
    case .missing:
        guard let tag = state.pinnedTag else {
            return Check(name: "guest", ok: false, detail: "no kernel/initramfs in \(state.path)", hint: "run `make guest`")
        }
        return Check(name: "guest", ok: true, detail: "not downloaded yet; the first boot fetches release \(tag) (\(size))",
                     hint: "`dmx guest fetch` downloads it now")
    case .local:
        return Check(name: "guest", ok: true, detail: "kernel \(state.kernel ?? "?") built locally in \(state.path)", hint: nil)
    case .release:
        let problems = store.verify()
        if !problems.isEmpty {
            return Check(name: "guest", ok: false, detail: problems.joined(separator: "; "), hint: "run `dmx guest fetch --force`")
        }
        if state.needsFetch, let pinned = state.pinnedTag {
            return Check(name: "guest", ok: true, detail: "release \(state.tag ?? "?"), verified; the next boot updates it to \(pinned) (\(size))",
                         hint: "`dmx guest fetch` downloads it now")
        }
        return Check(name: "guest", ok: true, detail: "release \(state.tag ?? "?") (kernel \(state.kernel ?? "?")), verified, in \(state.path)", hint: nil)
    }
}

private func hasEntitlement(_ name: String) -> Bool {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let value = SecTaskCopyValueForEntitlement(task, name as CFString, nil)
    return (value as? Bool) == true
}
