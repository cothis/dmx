import Foundation
import Security

/// `dmx names setup`, `ls` and `remove`: the parts of local names that change macOS (trusting
/// the CA for the user, the resolver file, which needs an administrator), and their state.
extension LocalNames {
    public struct Report: Encodable, Sendable {
        public var ok = true
        public var enabled: Bool
        public var settings: Settings?
        /// SHA-1 of the CA certificate, if there is one.
        public var authority: String?
        /// Whether macOS trusts a leaf from the CA for a name under dmx.local.
        public var trusted: Bool
        /// `ok`, `missing` or `different` (another port or text).
        public var resolver: String
        public var daemon: NamesStatus?
        public var changes: [String] = []
        public var next: String?
    }

    public struct SetupOptions: Sendable {
        public var dnsPort: Int?
        public var httpPort: Int?
        public var httpsPort: Int?
        /// Change macOS: trust the CA and write the resolver file. Off, names work with
        /// `curl --resolve` and the CA file, which is how the tests run.
        public var system = true
        public init() {}
    }

    public static func setup(paths: Paths, options: SetupOptions, progress: @Sendable (String) -> Void) async throws -> Report {
        var settings = Self.settings(paths) ?? Settings()
        if let p = options.dnsPort { settings.dnsPort = p }
        if let p = options.httpPort { settings.httpPort = p }
        if let p = options.httpsPort { settings.httpsPort = p }
        settings.system = options.system
        for (name, port) in [("dns", settings.dnsPort), ("http", settings.httpPort), ("https", settings.httpsPort)] where !(1...65535).contains(port) {
            throw DMXError("bad_argument", "\(name) port \(port) is not between 1 and 65535", hint: "run `dmx names setup` with another --\(name)-port")
        }
        var changes: [String] = []
        let directory = Self.directory(paths)
        let existed = try NameAuthority.load(directory) != nil
        let authority = try NameAuthority.loadOrCreate(directory)
        if !existed { changes.append("made a CA for names under \(domain) in \(directory.path)") }
        if options.system {
            if !trusts(authority) {
                progress("trusting the CA for this user: macOS asks for your password")
                try trust(authority, directory)
                changes.append("trusted the CA for this user (it can sign names under \(domain) only)")
            }
            if resolverState(settings) != "ok" {
                progress("writing \(resolverFile): macOS asks for an administrator's password")
                try writeResolver(settings)
                changes.append("wrote \(resolverFile)")
            }
        }
        try save(settings, paths)
        var report = try await status(paths: paths, reload: true)
        report.changes = changes
        if options.system, !report.trusted || report.resolver != "ok" {
            report.ok = false
            report.next = "run `dmx names setup` again"
        } else if let names = report.daemon?.names.first {
            report.next = "open https://\(names.name)"
        } else {
            report.next = "start a container (`docker run -d --name web nginx`), then open http://web.\(domain)"
        }
        return report
    }

    public static func remove(paths: Paths, progress: @Sendable (String) -> Void) async throws -> Report {
        var changes: [String] = []
        let directory = Self.directory(paths)
        let authority = try? NameAuthority.load(directory)
        // Only a setup that changed macOS from this DMX_HOME removes the resolver file: another
        // DMX_HOME (a test's, with --no-system) must not take away the one the user set up.
        let changedSystem = Self.settings(paths)?.system ?? false
        try? FileManager.default.removeItem(at: settingsFile(paths))
        if let client = try await DaemonClient.connect(paths: paths, start: false) {
            defer { client.close() }
            _ = try? await client.reloadNames()
        }
        if let authority, trusts(authority) || keychainHas(authority) {
            progress("removing the CA from this user's trust settings: macOS may ask for your password")
            try untrust(authority, directory)
            changes.append("removed the CA from this user's keychain and trust settings")
        }
        if changedSystem, FileManager.default.fileExists(atPath: resolverFile),
           (try? String(contentsOfFile: resolverFile, encoding: .utf8))?.hasPrefix("# dmx local names") ?? false {
            progress("removing \(resolverFile): macOS asks for an administrator's password")
            try administrator("/bin/rm -f \(shellQuote(resolverFile))")
            changes.append("removed \(resolverFile)")
        }
        // Without its key the CA cannot be read, so its trust could not be checked or removed:
        // keep the certificate, or nothing would say which one to take out of the keychain.
        let unreadable = authority == nil && FileManager.default.fileExists(atPath: directory.appendingPathComponent("ca.pem").path)
        if FileManager.default.fileExists(atPath: directory.path), !unreadable {
            try FileManager.default.removeItem(at: directory)
            changes.append("removed \(directory.path)")
        }
        var report = try await status(paths: paths, reload: false)
        report.changes = changes
        if unreadable {
            report.ok = false
            report.next = "remove the \"\(NameAuthority.commonName)\" certificate in Keychain Access, then delete \(directory.path)"
        }
        return report
    }

    public static func status(paths: Paths, reload: Bool = false) async throws -> Report {
        let settings = Self.settings(paths)
        let authority = try? NameAuthority.load(directory(paths))
        var daemon: NamesStatus?
        if let client = try await DaemonClient.connect(paths: paths, start: reload && settings != nil) {
            defer { client.close() }
            daemon = reload ? try await client.reloadNames() : try await client.names()
        }
        return Report(enabled: settings != nil, settings: settings, authority: authority?.sha1,
                      trusted: authority.map(trusts) ?? false, resolver: settings.map(resolverState) ?? (FileManager.default.fileExists(atPath: resolverFile) ? "different" : "missing"),
                      daemon: daemon,
                      next: settings == nil ? "run `dmx names setup`" : nil)
    }

    // MARK: macOS

    static func resolverState(_ settings: Settings) -> String {
        guard let text = try? String(contentsOfFile: resolverFile, encoding: .utf8) else { return "missing" }
        return text == resolverText(settings) ? "ok" : "different"
    }

    /// Whether macOS accepts a leaf from `authority` for a name under dmx.local, as Safari and
    /// curl would.
    public static func trusts(_ authority: NameAuthority) -> Bool {
        let name = "check.\(domain)"
        guard let key = try? P256Key.generate(), let leaf = try? authority.issue(name, leafKey: key),
              let leafCert = SecCertificateCreateWithData(nil, leaf as CFData),
              let caCert = SecCertificateCreateWithData(nil, authority.certificate as CFData) else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leafCert, caCert] as CFArray, SecPolicyCreateSSL(true, name as CFString), &trust) == errSecSuccess,
              let trust else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    static func keychainHas(_ authority: NameAuthority) -> Bool {
        let r = run("/usr/bin/security", ["find-certificate", "-Z", "-a", "-c", NameAuthority.commonName, loginKeychain])
        return r.status == 0 && r.output.contains(authority.sha1)
    }

    static var loginKeychain: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path
    }

    /// Adds the CA to the login keychain and trusts it for TLS for this user. macOS shows its
    /// own password dialog for the trust change.
    static func trust(_ authority: NameAuthority, _ directory: URL) throws {
        let pem = directory.appendingPathComponent("ca.pem").path
        let r = run("/usr/bin/security", ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", loginKeychain, pem])
        guard r.status == 0, trusts(authority) else {
            throw DMXError("names_not_trusted", "macOS did not trust the CA: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))",
                           hint: "run `dmx names setup` again and allow the change in the password dialog")
        }
    }

    static func untrust(_ authority: NameAuthority, _ directory: URL) throws {
        let pem = directory.appendingPathComponent("ca.pem").path
        _ = run("/usr/bin/security", ["remove-trusted-cert", pem])
        _ = run("/usr/bin/security", ["delete-certificate", "-Z", authority.sha1, loginKeychain])
        if trusts(authority) {
            throw DMXError("names_still_trusted", "macOS still trusts the dmx names CA (\(authority.sha1))",
                           hint: "remove \"\(NameAuthority.commonName)\" in Keychain Access, then run `dmx names remove` again")
        }
    }

    static func writeResolver(_ settings: Settings) throws {
        let text = resolverText(settings)
        try administrator("/bin/mkdir -p /etc/resolver && /usr/bin/printf %s \(shellQuote(text)) > \(shellQuote(resolverFile)) && /bin/chmod 644 \(shellQuote(resolverFile))")
        guard resolverState(settings) == "ok" else {
            throw DMXError("names_resolver_failed", "\(resolverFile) was not written", hint: "run `dmx names setup` again")
        }
    }

    /// Runs a shell command as root after macOS's administrator dialog.
    static func administrator(_ command: String) throws {
        let script = "do shell script \(appleScriptString(command)) with administrator privileges with prompt \(appleScriptString("dmx wants to set up local names under \(domain)."))"
        let r = run("/usr/bin/osascript", ["-e", script])
        guard r.status == 0 else {
            let cancelled = r.output.contains("-128")
            throw DMXError(cancelled ? "names_cancelled" : "names_admin_failed",
                           cancelled ? "the administrator dialog was cancelled" : "the administrator step failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))",
                           hint: "run `dmx names setup` again and enter an administrator's password")
        }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

extension DaemonClient {
    public func names() async throws -> NamesStatus {
        try await control.call("names", NoParams())
    }

    /// Makes the daemon read names.json again, and lists the containers for names.
    public func reloadNames() async throws -> NamesStatus {
        try await control.call("names_reload", NoParams())
    }
}
