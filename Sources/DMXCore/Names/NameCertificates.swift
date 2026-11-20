import CryptoKit
import Foundation
import Security

/// The certificate authority behind `https://<name>.dmx.local`: an ECDSA P-256 root whose name
/// constraints permit only `dmx.local` and the names under it, so trusting it lets nothing else
/// be vouched for, even if its key leaked. Its key stays in `~/.dmx/names` (mode 0600), not in a
/// keychain, so a rebuilt (re-signed) dmx can still use it without a keychain prompt. The daemon
/// issues a leaf for each name on its first TLS connection, in memory, with a key of its own.
public struct NameAuthority: Sendable {
    public let certificate: Data
    let key: SecKeySendable

    public static let commonName = "dmx local names CA"
    /// Leaves last 397 days: what browsers accept from public CAs, so nothing objects later.
    static let leafLifetime: TimeInterval = 397 * 86400

    /// NameConstraints: permitted dNSName dmx.local; excluded iPAddress 0.0.0.0/0 and ::/0.
    static var nameConstraints: Data {
        DER.sequence([
            DER.tagged(0xa0, DER.sequence([DER.tagged(0x82, Data(LocalNames.domain.utf8))])),
            DER.tagged(0xa1, DER.sequence([DER.tagged(0x87, Data(count: 8))]) + DER.sequence([DER.tagged(0x87, Data(count: 32))])),
        ])
    }

    /// Loads the authority from `directory`, or makes one there.
    public static func loadOrCreate(_ directory: URL) throws -> NameAuthority {
        try loadOrCreate(directory, constraints: nameConstraints)
    }

    /// `constraints` other than nameConstraints only for tests (an older CA).
    static func loadOrCreate(_ directory: URL, constraints: Data) throws -> NameAuthority {
        if let existing = try load(directory) { return existing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let key = try P256Key.generate()
        let now = Date()
        let spki = key.publicKeyBits
        let tbs = DER.tbsCertificate(
            serial: DER.randomSerial(), issuer: DER.name(commonName), subject: DER.name(commonName),
            notBefore: now.addingTimeInterval(-3600), notAfter: now.addingTimeInterval(20 * 365 * 86400),
            publicKey: spki,
            extensions: [
                DER.ext(DER.oid.basicConstraints, critical: true, DER.sequence([DER.boolean(true), DER.integer(0)])),
                DER.ext(DER.oid.keyUsage, critical: true, DER.bitString(Data([0x06]), unusedBits: 1)),  // keyCertSign, cRLSign
                DER.ext(DER.oid.subjectKeyIdentifier, critical: false, DER.octetString(DER.keyIdentifier(spki))),
                // permittedSubtrees: dNSName "dmx.local", which covers every name under it. A
                // constraint binds only names of its own kind, so excludedSubtrees takes every
                // IPv4 and IPv6 address too: a leaf for https://<address> is refused as well.
                DER.ext(DER.oid.nameConstraints, critical: true, constraints),
            ])
        let certificate = try DER.signed(tbs, with: key.key)
        let keyFile = directory.appendingPathComponent("ca.key")
        guard FileManager.default.createFile(atPath: keyFile.path, contents: key.privateBits,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw DMXError("names_error", "cannot write \(keyFile.path)", hint: "check the permissions of \(directory.path)")
        }
        try Data(pem(certificate).utf8).write(to: directory.appendingPathComponent("ca.pem"), options: .atomic)
        return NameAuthority(certificate: certificate, key: SecKeySendable(key.key))
    }

    public static func load(_ directory: URL) throws -> NameAuthority? {
        let keyFile = directory.appendingPathComponent("ca.key"), certFile = directory.appendingPathComponent("ca.pem")
        guard let keyBits = try? Data(contentsOf: keyFile), let text = try? String(contentsOf: certFile, encoding: .utf8) else { return nil }
        guard let der = HostCertificates.pemBlocks(text).first.flatMap(derOfPEM), let key = try? P256Key(privateBits: keyBits) else {
            throw DMXError("names_bad_authority", "\(directory.path) holds a CA dmx cannot read",
                           hint: "run `dmx names remove`, then `dmx names setup` to make a new one")
        }
        // A CA made before its constraints excluded IP addresses could vouch for https://<address>.
        guard der.range(of: nameConstraints) != nil else {
            throw DMXError("names_bad_authority", "the CA in \(directory.path) is from an earlier dmx and does not exclude IP addresses",
                           hint: "run `dmx names remove`, then `dmx names setup` to make a new one")
        }
        return NameAuthority(certificate: der, key: SecKeySendable(key.key))
    }

    /// SHA-1 of the certificate, as `security` names certificates.
    public var sha1: String { Insecure.SHA1.hash(data: certificate).map { String(format: "%02X", $0) }.joined() }

    var publicKeyBits: Data {
        // The subjectPublicKeyInfo's key bits, from the CA's own key.
        SecKeyCopyPublicKey(key.key).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? } ?? Data()
    }

    /// A leaf for `name` signed by this authority, with `leafKey` as its key.
    func issue(_ name: String, leafKey: P256Key, now: Date = Date(), addresses: [Data] = []) throws -> Data {
        let spki = leafKey.publicKeyBits
        let tbs = DER.tbsCertificate(
            serial: DER.randomSerial(), issuer: DER.name(Self.commonName), subject: DER.name(name),
            notBefore: now.addingTimeInterval(-3600), notAfter: now.addingTimeInterval(Self.leafLifetime),
            publicKey: spki,
            extensions: [
                DER.ext(DER.oid.basicConstraints, critical: true, DER.sequence([])),
                DER.ext(DER.oid.keyUsage, critical: true, DER.bitString(Data([0x80]), unusedBits: 7)),  // digitalSignature
                DER.ext(DER.oid.extendedKeyUsage, critical: false, DER.sequence([DER.objectIdentifier(DER.oid.serverAuth)])),
                DER.ext(DER.oid.subjectKeyIdentifier, critical: false, DER.octetString(DER.keyIdentifier(spki))),
                DER.ext(DER.oid.authorityKeyIdentifier, critical: false,
                        DER.sequence([DER.tagged(0x80, DER.keyIdentifier(publicKeyBits))])),
                // `addresses` (iPAddress SANs) only for tests: the CA must not be trusted for them.
                DER.ext(DER.oid.subjectAltName, critical: false,
                        DER.sequence([DER.tagged(0x82, Data(name.utf8))] + addresses.map { DER.tagged(0x87, $0) })),
            ])
        return try DER.signed(tbs, with: key.key)
    }

    /// A TLS identity for `name`: a new leaf and `leafKey`.
    func identity(_ name: String, leafKey: P256Key) throws -> SecIdentity {
        let der = try issue(name, leafKey: leafKey)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let identity = SecIdentityCreate(nil, certificate, leafKey.key) else {
            throw DMXError("names_error", "cannot make a TLS identity for \(name)", hint: "run `dmx doctor`")
        }
        return identity
    }

    public static func pem(_ der: Data) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
    }

    static func derOfPEM(_ block: String) -> Data? {
        let body = block.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body)
    }
}

/// SecKey is thread safe but not marked Sendable.
struct SecKeySendable: @unchecked Sendable {
    let key: SecKey
    init(_ key: SecKey) { self.key = key }
}

/// An ECDSA P-256 key held in memory only (not in a keychain).
struct P256Key: @unchecked Sendable {
    let key: SecKey

    static func generate() throws -> P256Key {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw DMXError("names_error", "cannot make a P-256 key: \(error?.takeRetainedValue().localizedDescription ?? "?")", hint: "run `dmx doctor`, then `dmx names setup` again")
        }
        return P256Key(key: key)
    }

    init(key: SecKey) { self.key = key }

    /// From `privateBits` (04 || X || Y || D, as SecKeyCopyExternalRepresentation gives it).
    init(privateBits: Data) throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                                           kSecAttrKeyClass: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits: 256]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(privateBits as CFData, attributes as CFDictionary, &error) else {
            throw DMXError("names_error", "not a P-256 private key", hint: "run `dmx names remove`, then `dmx names setup` to make a new CA")
        }
        self.key = key
    }

    var privateBits: Data { (SecKeyCopyExternalRepresentation(key, nil) as Data?) ?? Data() }
    /// The public point, 04 || X || Y.
    var publicKeyBits: Data { SecKeyCopyPublicKey(key).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? } ?? Data() }
}

/// Just enough DER to write X.509 certificates.
enum DER {
    enum oid {
        static let ecPublicKey = "1.2.840.10045.2.1", prime256v1 = "1.2.840.10045.3.1.7"
        static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2", commonName = "2.5.4.3", organization = "2.5.4.10"
        static let basicConstraints = "2.5.29.19", keyUsage = "2.5.29.15", extendedKeyUsage = "2.5.29.37"
        static let subjectKeyIdentifier = "2.5.29.14", authorityKeyIdentifier = "2.5.29.35"
        static let subjectAltName = "2.5.29.17", nameConstraints = "2.5.29.30", serverAuth = "1.3.6.1.5.5.7.3.1"
    }

    static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let n = content.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var bytes: [UInt8] = []
            var v = n
            while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        return out + content
    }

    static func sequence(_ items: [Data]) -> Data { tagged(0x30, items.reduce(Data(), +)) }
    static func set(_ items: [Data]) -> Data { tagged(0x31, items.reduce(Data(), +)) }
    static func boolean(_ v: Bool) -> Data { tagged(0x01, Data([v ? 0xff : 0x00])) }
    static func octetString(_ d: Data) -> Data { tagged(0x04, d) }
    static func bitString(_ d: Data, unusedBits: UInt8 = 0) -> Data { tagged(0x03, Data([unusedBits]) + d) }
    static func utf8String(_ s: String) -> Data { tagged(0x0c, Data(s.utf8)) }

    static func integer(_ v: Int) -> Data {
        var bytes: [UInt8] = []
        var x = v
        repeat { bytes.insert(UInt8(x & 0xff), at: 0); x >>= 8 } while x > 0
        return unsignedInteger(Data(bytes))
    }

    /// A non-negative INTEGER from big-endian bytes.
    static func unsignedInteger(_ bytes: Data) -> Data {
        var b = Array(bytes.drop(while: { $0 == 0 }))
        if b.isEmpty || b[0] & 0x80 != 0 { b.insert(0, at: 0) }
        return tagged(0x02, Data(b))
    }

    static func objectIdentifier(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").map { UInt64($0)! }
        var out = Data([UInt8(parts[0] * 40 + parts[1])])
        for part in parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(part & 0x7f)]
            var v = part >> 7
            while v > 0 { chunk.insert(UInt8(v & 0x7f) | 0x80, at: 0); v >>= 7 }
            out.append(contentsOf: chunk)
        }
        return tagged(0x06, out)
    }

    static func time(_ date: Date) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2000
        // UTCTime through 2049, GeneralizedTime after (RFC 5280 4.1.2.5).
        if year < 2050 {
            f.dateFormat = "yyMMddHHmmss'Z'"
            return tagged(0x17, Data(f.string(from: date).utf8))
        }
        f.dateFormat = "yyyyMMddHHmmss'Z'"
        return tagged(0x18, Data(f.string(from: date).utf8))
    }

    static func name(_ commonName: String) -> Data {
        sequence([
            set([sequence([objectIdentifier(oid.organization), utf8String("dmx")])]),
            set([sequence([objectIdentifier(oid.commonName), utf8String(commonName)])]),
        ])
    }

    static func ext(_ id: String, critical: Bool, _ value: Data) -> Data {
        sequence([objectIdentifier(id)] + (critical ? [boolean(true)] : []) + [octetString(value)])
    }

    static func randomSerial() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        bytes[0] &= 0x7f
        return unsignedInteger(Data(bytes))
    }

    /// RFC 5280's method 1: SHA-1 of the public key bits.
    static func keyIdentifier(_ publicKeyBits: Data) -> Data { Data(Insecure.SHA1.hash(data: publicKeyBits)) }

    static var ecdsaSHA256: Data { sequence([objectIdentifier(oid.ecdsaWithSHA256)]) }

    static func tbsCertificate(serial: Data, issuer: Data, subject: Data, notBefore: Date, notAfter: Date,
                               publicKey: Data, extensions: [Data]) -> Data {
        sequence([
            tagged(0xa0, integer(2)),  // v3
            serial,
            ecdsaSHA256,
            issuer,
            sequence([time(notBefore), time(notAfter)]),
            subject,
            sequence([sequence([objectIdentifier(oid.ecPublicKey), objectIdentifier(oid.prime256v1)]), bitString(publicKey)]),
            tagged(0xa3, sequence(extensions)),
        ])
    }

    static func signed(_ tbs: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else {
            throw DMXError("names_error", "cannot sign a certificate: \(error?.takeRetainedValue().localizedDescription ?? "?")", hint: "run `dmx names remove`, then `dmx names setup` to make a new CA")
        }
        return sequence([tbs, ecdsaSHA256, bitString(signature)])
    }
}
