import Foundation
import Security
import CryptoKit
import PocketXRCore

/// Pocket XR for Mac as a streaming host: its identity, as Sunshine makes one (a unique id and a self-signed RSA 2048
/// certificate, "CN=Sunshine Gamestream Host"), and the phones paired with it (their certificates, pinned). Kept in
/// ~/Library/Application Support/Pocket XR/host, the key in a file only this user can read (not the keychain, so no
/// keychain question is ever asked). Ported from Pocket XR for Windows' HostIdentity (GPLv3).
final class HostIdentity: @unchecked Sendable {
    let uniqueId: String
    let certDer: Data
    let privateKey: SecKey
    /// The certificate as PEM text, as the phone gets it while pairing (plaincert).
    let pem: Data
    /// The certificate's own signature (its last BIT STRING), which pairing hashes.
    let certSignature: Data
    /// For TLS: the certificate with its key.
    let identity: SecIdentity?

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pocket XR/host", isDirectory: true)
    }

    private init(id: String, der: Data, key: SecKey) {
        uniqueId = id
        certDer = der
        privateKey = key
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        pem = Data(("-----BEGIN CERTIFICATE-----\n" + b64 + "\n-----END CERTIFICATE-----\n").utf8)
        certSignature = Der.signature(of: der) ?? Data()
        identity = Self.makeIdentity(der: der, key: key)
    }

    static func load() -> HostIdentity? {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let idFile = folder.appendingPathComponent("host-id.txt")
        let certFile = folder.appendingPathComponent("host.cer")
        let keyFile = folder.appendingPathComponent("host.key")
        if let id = try? String(contentsOf: idFile, encoding: .utf8), let der = try? Data(contentsOf: certFile),
           let keyData = try? Data(contentsOf: keyFile),
           let key = SecKeyCreateWithData(keyData as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil) {
            return HostIdentity(id: id.trimmingCharacters(in: .whitespacesAndNewlines), der: der, key: key)
        }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &error),
              let pub = SecKeyCopyPublicKey(key),
              let pubData = SecKeyCopyExternalRepresentation(pub, nil) as Data?,
              let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            plog("host: could not make a key: \(String(describing: error?.takeRetainedValue()))")
            return nil
        }
        guard let der = Der.selfSigned(commonName: "Sunshine Gamestream Host", publicKeyPkcs1: pubData, years: 20, sign: { tbs in
            SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(tbs) as CFData, nil) as Data?
        }) else {
            plog("host: could not sign the certificate")
            return nil
        }
        let id = UUID().uuidString.uppercased()
        do {
            try keyData.write(to: keyFile, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
            try der.write(to: certFile, options: .atomic)
            try Data(id.utf8).write(to: idFile, options: .atomic)
        } catch {
            plog("host: could not keep the identity: \(error)")
        }
        plog("host: made this Mac's host id, certificate and key")
        return HostIdentity(id: id, der: der, key: key)
    }

    func sign(_ data: Data) -> Data {
        (SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, nil) as Data?) ?? Data()
    }

    /// A SecIdentity from the certificate and a key that is not in a keychain: Security's SecIdentityCreate (not in
    /// the public headers, there since macOS 10.x, looked up at run time); else nil, and HTTPS is not offered.
    private static func makeIdentity(der: Data, key: SecKey) -> SecIdentity? {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        typealias Create = @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?
        guard let h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let sym = dlsym(h, "SecIdentityCreate") else {
            plog("host: SecIdentityCreate is not there: no HTTPS")
            return nil
        }
        let create = unsafeBitCast(sym, to: Create.self)
        return create(kCFAllocatorDefault, cert, key)?.takeRetainedValue()
    }
}

/// The phones paired with this host: name, unique id, certificate (DER, base64). Pinned on every HTTPS request.
final class HostClients: @unchecked Sendable {
    struct Client: Codable {
        var name: String
        var uniqueId: String
        var cert: String
        var paired: Date
    }

    private let lock = NSLock()
    private var list: [Client] = []
    private var file: URL { HostIdentity.folder.appendingPathComponent("clients.json") }

    init() {
        if let data = try? Data(contentsOf: file), let l = try? JSONDecoder().decode([Client].self, from: data) { list = l }
    }

    func knows(_ der: Data) -> Bool {
        let b = der.base64EncodedString()
        lock.lock(); defer { lock.unlock() }
        return list.contains { $0.cert == b }
    }

    func add(name: String, uniqueId: String, der: Data) {
        let b = der.base64EncodedString()
        lock.lock(); defer { lock.unlock() }
        list.removeAll { $0.cert == b } // one record per certificate: a phone paired again replaces its old one
        list.append(Client(name: name, uniqueId: uniqueId, cert: b, paired: Date()))
        save()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return list.count }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        list.removeAll()
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: HostIdentity.folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(list) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}

/// Just enough DER (X.509) for the host: a self-signed certificate made, and a certificate's signature read.
enum Der {
    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func seq(_ parts: [UInt8]...) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    static func oid(_ bytes: [UInt8]) -> [UInt8] { tlv(0x06, bytes) }
    static let null: [UInt8] = [0x05, 0x00]
    static let sha256WithRsa: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
    static let rsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]

    static func utcTime(_ d: Date) -> [UInt8] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMddHHmmss"
        return tlv(0x17, Array((f.string(from: d) + "Z").utf8))
    }

    static func selfSigned(commonName: String, publicKeyPkcs1: Data, years: Int, sign: ([UInt8]) -> Data?) -> Data? {
        var serial = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7F
        serial[0] |= 0x01
        let name = seq(tlv(0x31, seq(oid([0x55, 0x04, 0x03]), tlv(0x0C, Array(commonName.utf8)))))
        let alg = seq(oid(sha256WithRsa), null)
        let now = Date().addingTimeInterval(-300)
        let validity = seq(utcTime(now), utcTime(now.addingTimeInterval(Double(years) * 365.25 * 86400)))
        let spki = seq(seq(oid(rsaEncryption), null), tlv(0x03, [0] + Array(publicKeyPkcs1)))
        let tbs = seq(tlv(0xA0, tlv(0x02, [2])), tlv(0x02, serial), alg, name, validity, name, spki)
        guard let signature = sign(tbs) else { return nil }
        return Data(seq(tbs, alg, tlv(0x03, [0] + Array(signature))))
    }

    /// The signature of a DER certificate: the content of its third top-level element (a BIT STRING), less the
    /// unused-bits byte.
    static func signature(of der: Data) -> Data? {
        let b = [UInt8](der)
        func read(_ at: Int) -> (tag: UInt8, start: Int, end: Int)? {
            guard at + 2 <= b.count else { return nil }
            let tag = b[at]
            var len = Int(b[at + 1])
            var p = at + 2
            if len & 0x80 != 0 {
                let n = len & 0x7F
                guard n <= 4, p + n <= b.count else { return nil }
                len = 0
                for i in 0..<n { len = len << 8 | Int(b[p + i]) }
                p += n
            }
            guard p + len <= b.count else { return nil }
            return (tag, p, p + len)
        }
        guard let top = read(0), top.tag == 0x30, let tbs = read(top.start), let alg = read(tbs.end),
              let sig = read(alg.end), sig.tag == 0x03, sig.end > sig.start + 1 else { return nil }
        return Data(b[(sig.start + 1)..<sig.end])
    }
}
