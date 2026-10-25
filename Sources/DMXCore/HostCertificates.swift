import Foundation
import Security

/// Certificate authorities the Mac trusts beyond Apple's own: those an administrator or the user
/// added to the keychain and marked trusted (a company's TLS-inspecting proxy, an internal
/// registry's private CA), plus `ca-certificates.pem` in `DMX_HOME` for ones handed out as a file.
/// dockerd and BuildKit in the guest trust them on top of the guest's bundle, as Docker Desktop
/// does with the keychain's.
public enum HostCertificates {
    public static let fileName = "ca-certificates.pem"

    /// PEM text of every such certificate, and how many came from each source.
    public static func pem(home: URL) -> (pem: String, keychain: Int, file: Int) {
        var blocks: [String] = []
        var seen = Set<Data>()
        for certificate in keychainRoots() {
            let der = SecCertificateCopyData(certificate) as Data
            if seen.insert(der).inserted { blocks.append(pem(der)) }
        }
        let keychain = blocks.count
        let file = home.appendingPathComponent(fileName)
        var fromFile = 0
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            for block in pemBlocks(text) {
                blocks.append(block)
                fromFile += 1
            }
        }
        return (blocks.joined(), keychain, fromFile)
    }

    /// Certificates with trust settings in the admin or user domain (Apple's system roots have
    /// theirs in the system domain), except those the settings deny.
    static func keychainRoots() -> [SecCertificate] {
        var out: [SecCertificate] = []
        for domain in [SecTrustSettingsDomain.admin, .user] {
            var list: CFArray?
            guard SecTrustSettingsCopyCertificates(domain, &list) == errSecSuccess,
                  let certificates = list as? [SecCertificate] else { continue }
            for certificate in certificates where trusted(certificate, domain) {
                out.append(certificate)
            }
        }
        return out
    }

    /// An empty settings array means "always trust"; otherwise a deny or unspecified result in
    /// every entry leaves it out.
    private static func trusted(_ certificate: SecCertificate, _ domain: SecTrustSettingsDomain) -> Bool {
        var settings: CFArray?
        guard SecTrustSettingsCopyTrustSettings(certificate, domain, &settings) == errSecSuccess else { return false }
        let entries = settings as? [[String: Any]] ?? []
        if entries.isEmpty { return true }
        return entries.contains { entry in
            let result = (entry[kSecTrustSettingsResult as String] as? NSNumber)?.uint32Value
                ?? SecTrustSettingsResult.trustRoot.rawValue
            return result == SecTrustSettingsResult.trustRoot.rawValue || result == SecTrustSettingsResult.trustAsRoot.rawValue
        }
    }

    static func pem(_ der: Data) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
    }

    /// The certificate blocks of a PEM file, each ending in a newline; anything else is dropped.
    static func pemBlocks(_ text: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring]?
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "-----BEGIN CERTIFICATE-----" {
                current = [Substring(trimmed)]
            } else if trimmed == "-----END CERTIFICATE-----", var block = current {
                block.append(Substring(trimmed))
                blocks.append(block.joined(separator: "\n") + "\n")
                current = nil
            } else if current != nil {
                current?.append(Substring(trimmed))
            }
        }
        return blocks
    }
}
