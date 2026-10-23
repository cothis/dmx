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
public func runDoctor(paths: Paths) -> DoctorReport {
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

    let fm = FileManager.default
    let haveGuest = fm.fileExists(atPath: paths.kernel.path) && fm.fileExists(atPath: paths.initramfs.path)
    var guestDetail = paths.guest.path
    if haveGuest,
       let data = try? Data(contentsOf: paths.manifest),
       let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let kernel = manifest["kernel"] as? String {
        guestDetail = "kernel \(kernel) in \(paths.guest.path)"
    }
    checks.append(Check(
        name: "guest",
        ok: haveGuest,
        detail: haveGuest ? guestDetail : "no kernel/initramfs in \(paths.guest.path)",
        hint: haveGuest ? nil : "run `make guest`"
    ))

    return DoctorReport(ok: checks.allSatisfy(\.ok), home: paths.home.path, checks: checks)
}

private func hasEntitlement(_ name: String) -> Bool {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let value = SecTaskCopyValueForEntitlement(task, name as CFString, nil)
    return (value as? Bool) == true
}
