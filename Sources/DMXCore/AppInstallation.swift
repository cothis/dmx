import Foundation

/// One installation owns both executables. The terminal link follows whole-bundle replacements;
/// never replace a sealed helper inside an installed .app.
public enum AppInstallation {
    public static let identifier = "io.github.cothis.dmx.menu"
    public static var defaultDestination: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/dmx.app")
    }
    public struct Report: Encodable, Sendable {
        public let ok = true
        public let version: String
        public let app: String
        public let cli: String?
    }

    /// Recognition is deliberately stricter than just finding `.app` in a path.
    static func containing(_ executable: URL) -> URL? {
        let macos = executable.deletingLastPathComponent()
        let contents = macos.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard executable.lastPathComponent == "dmx", macos.lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents", app.pathExtension == "app",
              let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
              info["CFBundleIdentifier"] as? String == identifier else { return nil }
        return app
    }

    /// Only stdout is extracted from an archive, into regular files made by us. tar never gets
    /// to materialize archive links or choose a destination path (including `..` or absolute paths).
    static func unpack(_ archive: URL, into work: URL) throws -> URL {
        let listing = try run("/usr/bin/tar", ["-tzf", archive.path], limit: 32_768)
        guard let names = String(data: listing, encoding: .utf8)?.split(separator: "\n").map(String.init),
              !names.isEmpty, names.count <= 128 else { throw invalid("invalid archive listing") }
        var seen = Set<String>()
        var files: [String] = []
        for raw in names {
            let name = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            guard seen.insert(name).inserted else { throw invalid("duplicate archive member") }
            if ["dmx", "LICENSE", "THIRD_PARTY.md"].contains(name) { continue }
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard components.first == "dmx.app", components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 47, 95].contains($0) }) else {
                throw invalid("unsafe archive member")
            }
            if !raw.hasSuffix("/") { files.append(name) }
        }
        guard files.contains("dmx.app/Contents/Info.plist"), files.contains("dmx.app/Contents/MacOS/dmx"),
              files.contains("dmx.app/Contents/MacOS/dmx-menu") else { throw invalid("archive has no complete dmx.app") }
        var total = 0
        for file in files {
            let data = try run("/usr/bin/tar", ["-xOf", archive.path, file], limit: 64 << 20)
            total += data.count
            guard total <= 128 << 20 else { throw invalid("app exceeds the size limit") }
            let target = work.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .withoutOverwriting)
            let executable = file == "dmx.app/Contents/MacOS/dmx" || file == "dmx.app/Contents/MacOS/dmx-menu"
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: target.path)
        }
        return work.appendingPathComponent("dmx.app")
    }

    public static func install(archive: URL? = nil, bundle: URL? = nil, destination: URL = defaultDestination,
                               binDirectory: URL? = nil, allowSigningChange: Bool = false) throws -> Report {
        do { return try installChecked(archive: archive, bundle: bundle, destination: destination, binDirectory: binDirectory, allowSigningChange: allowSigningChange) }
        catch let error as DMXError { throw error }
        catch { throw DMXError("app_install_failed", "cannot install dmx.app: \(error.localizedDescription)", hint: "check permissions and run `dmx app install` again") }
    }

    private static func installChecked(archive: URL?, bundle: URL?, destination: URL, binDirectory: URL?, allowSigningChange: Bool) throws -> Report {
        guard (archive == nil) != (bundle == nil) else { throw invalid("name exactly one archive or bundle") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("dmx-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let source = try archive.map { try unpack($0, into: work) } ?? bundle!
        let version = try verify(source, requiringInstalledTeamAt: allowSigningChange ? nil : destination)
        try replace(source: source, destination: destination, binDirectory: binDirectory, allowSigningChange: allowSigningChange)
        return Report(version: version, app: destination.path, cli: binDirectory?.appendingPathComponent("dmx").path)
    }

    /// Every downloaded executable is checked against the current CLI's signing team before it
    /// can run. Source builds still verify sealed contents but cannot assert an Apple identity.
    static func verify(_ app: URL, version expectedVersion: String = dmxVersion,
                       requiringInstalledTeamAt installedApp: URL? = nil) throws -> String {
        let helper = app.appendingPathComponent("Contents/MacOS/dmx")
        guard try FileManager.default.attributesOfItem(atPath: app.path)[.type] as? FileAttributeType == .typeDirectory,
              containing(helper)?.standardizedFileURL.path == app.standardizedFileURL.path,
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleExecutable"] as? String == "dmx-menu",
              let version = info["CFBundleShortVersionString"] as? String, version == expectedVersion else {
            throw invalid("bundle identity or version does not match this dmx")
        }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], limit: 8192)
        let checker = SelfUpdate(current: dmxVersion)
        _ = try checker.checkSignature(of: app)
        _ = try checker.checkSignature(of: helper)
        if let installedApp, exists(installedApp), SelfUpdate.teamIdentifier(of: installedApp) != nil {
            let installed = SelfUpdate(current: dmxVersion, executable: installedApp)
            _ = try installed.checkSignature(of: app)
            _ = try installed.checkSignature(of: helper)
        }
        try checker.check(binary: helper, is: version)
        return version
    }

    /// Atomically exchange complete directories; an existing app never disappears, even if
    /// the updater dies. The CLI rename is atomic too. Roll back the exchange if it fails.
    static func replace(source: URL, destination: URL, binDirectory: URL?, version: String = dmxVersion,
                        allowSigningChange: Bool = false,
                        commitLink: (URL, URL) throws -> Void = atomicRename) throws {
        let fm = FileManager.default
        let destination = destination.standardizedFileURL
        guard destination.pathExtension == "app", source.resolvingSymlinksInPath().path != destination.resolvingSymlinksInPath().path else { throw invalid("choose a different .app destination") }
        if let binDirectory {
            let bin = binDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard !bin.hasPrefix(destination.resolvingSymlinksInPath().path + "/"), !bin.hasPrefix(source.resolvingSymlinksInPath().path + "/") else {
                throw invalid("CLI links must live outside the signed app")
            }
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = destination.deletingLastPathComponent().appendingPathComponent(".dmx-install.lock")
        let lockFD = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw invalid("cannot lock the app destination") }
        defer { _ = flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else { throw invalid("cannot lock the app destination") }
        if exists(destination) {
            guard try fm.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType == .typeDirectory,
                  containing(destination.appendingPathComponent("Contents/MacOS/dmx"))?.path == destination.path else {
                throw invalid("refusing to replace a different app or a link at \(destination.path)")
            }
        }
        let token = UUID().uuidString
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".dmx-\(token).app")
        let cli = binDirectory?.standardizedFileURL.appendingPathComponent("dmx")
        let link = binDirectory?.standardizedFileURL.appendingPathComponent(".dmx-\(token).new")
        var preserveRecovery = false
        defer { if !preserveRecovery { try? fm.removeItem(at: staged) }; if let link { try? fm.removeItem(at: link) } }
        try fm.copyItem(at: source, to: staged)
        _ = try verify(staged, version: version, requiringInstalledTeamAt: allowSigningChange ? nil : destination)
        if let cli, let link {
            try fm.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
            if exists(cli), try fm.attributesOfItem(atPath: cli.path)[.type] as? FileAttributeType == .typeDirectory {
                throw invalid("the CLI destination is a directory")
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: destination.appendingPathComponent("Contents/MacOS/dmx"))
        }
        let hadApp = exists(destination)
        var committed = false
        do {
            if hadApp { try exchange(staged, destination) }
            else { try atomicRename(staged, destination) }
            committed = true
            if let cli, let link { try commitLink(link, cli) }
        } catch {
            let original = error
            if committed {
                do {
                    if hadApp { try exchange(staged, destination) }
                    else { try fm.removeItem(at: destination) }
                } catch {
                    preserveRecovery = true
                    throw DMXError("app_rollback_failed", "install failed; the previous app remains at \(staged.path)",
                                   hint: "restore that app, then run `dmx app install` again")
                }
            }
            throw DMXError("app_install_failed", "could not install dmx.app: \(original.localizedDescription)", hint: "check the destination permissions, then run `dmx app install` again")
        }
    }

    static func atomicRename(_ from: URL, _ to: URL) throws {
        guard rename(from.path, to.path) == 0 else { throw invalid("rename failed: \(String(cString: strerror(errno)))") }
    }

    private static func exchange(_ first: URL, _ second: URL) throws {
        guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw invalid("app exchange failed: \(String(cString: strerror(errno)))")
        }
    }

    private static func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }
    private static func invalid(_ message: String) -> DMXError {
        DMXError("app_invalid", message, hint: "download the complete release with its `install.sh`, then retry")
    }

    private static func run(_ executable: String, _ arguments: [String], limit: Int) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        var result = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            guard result.count + chunk.count <= limit else {
                process.terminate(); process.waitUntilExit(); throw invalid("tool output exceeds the size limit")
            }
            result.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw invalid("\(URL(fileURLWithPath: executable).lastPathComponent) rejected the app or archive") }
        return result
    }
}
