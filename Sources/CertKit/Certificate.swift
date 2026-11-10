import CryptoKit
import Foundation
import Security

public enum CertError: Error, Equatable, CustomStringConvertible, Sendable {
    case notBambuddy(String)
    case notACertificate
    case fingerprintMismatch
    case expired
    case slicerRunning(String)
    case noPermission(String)
    case signingFailed(String)
    case nothingToUndo

    public var description: String {
        switch self {
        case .notBambuddy(let address): "No Bambuddy certificate at \(address)."
        case .notACertificate: "Bambuddy's reply isn't a single certificate."
        case .fingerprintMismatch: "The certificate doesn't match the fingerprint Bambuddy sent with it."
        case .expired: "Bambuddy's certificate has expired."
        case .slicerRunning(let name): "Quit \(name) first."
        case .noPermission(let name): "macOS didn't allow changing \(name). Allow Bambuddy Cert Installer in System Settings › Privacy & Security › App Management, then try again."
        case .signingFailed(let output): "Re-signing failed, so the change was undone: \(output)"
        case .nothingToUndo: "There's no backup to restore."
        }
    }
}

/// Bambuddy's virtual printer CA, as the slicers need it.
public struct CACertificate: Equatable, Sendable {
    public let der: Data
    /// SHA-256 of the DER, as "AA:BB:…", the way Bambuddy shows it.
    public let fingerprint: String
    public let commonName: String?
    public let expires: Date?

    public init(der: Data) throws {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else { throw CertError.notACertificate }
        self.der = der
        fingerprint = Self.fingerprint(of: der)
        var name: CFString?
        SecCertificateCopyCommonName(cert, &name)
        commonName = name as String?
        expires = SecCertificateCopyNotValidAfterDate(cert) as Date?
    }

    public var pem: String { PEM.encode(der) }

    static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// "abcdef…", "AB:CD:EF:…" and "F7 D0 6B …" all compare equal.
    static func normalize(_ fingerprint: String) -> String {
        fingerprint.uppercased().filter(\.isHexDigit)
    }
}

enum PEM {
    /// Every certificate in a PEM file, as DER.
    static func certificates(in text: String) -> [Data] {
        var found: [Data] = []
        var rest = Substring(text)
        while let start = rest.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = rest.range(of: "-----END CERTIFICATE-----", range: start.upperBound..<rest.endIndex) {
            if let der = Data(base64Encoded: String(rest[start.upperBound..<end.lowerBound]), options: .ignoreUnknownCharacters) {
                found.append(der)
            }
            rest = rest[end.upperBound...]
        }
        return found
    }

    static func encode(_ der: Data) -> String {
        let base64 = der.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 64).map { offset -> String in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            return String(base64[start..<(base64.index(start, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex)])
        }
        return "-----BEGIN CERTIFICATE-----\n" + lines.joined(separator: "\n") + "\n-----END CERTIFICATE-----\n"
    }
}
