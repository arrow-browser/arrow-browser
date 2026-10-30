import Crypto
import CryptoExtras
import Foundation

/// A Chrome Web Store package (CRX3): signature verification and payload.
///
/// Format (components/crx_file): "Cr24", version 3, header length, a
/// `CrxFileHeader` protobuf, then the ZIP archive. The archive is signed with
/// RSA PKCS#1 v1.5 SHA-256 over
/// `"CRX3 SignedData\0" || u32le(len(signed_header_data)) || signed_header_data || archive`.
public struct CRXPackage: Sendable {
    public enum Failure: LocalizedError, Sendable {
        case notCRX3
        case malformed
        case idMismatch
        case invalidSignature

        public var errorDescription: String? {
            switch self {
            case .notCRX3: "The download is not a CRX3 package."
            case .malformed: "The extension package is malformed."
            case .idMismatch: "The package does not match the requested extension."
            case .invalidSignature: "The extension signature is invalid."
            }
        }
    }

    /// Extension ID (32 letters a–p).
    public let id: String
    /// DER SubjectPublicKeyInfo of the publisher key, as `manifest.json` "key".
    public let publicKey: Data
    public let archive: Data

    public init(data: Data, expectedID: String) throws {
        let bytes = [UInt8](data)
        guard bytes.count > 12, Array(bytes[0..<4]) == Array("Cr24".utf8), Self.u32(bytes, 4) == 3 else { throw Failure.notCRX3 }
        let headerLength = Int(Self.u32(bytes, 8))
        guard 12 + headerLength <= bytes.count else { throw Failure.malformed }
        let header = Array(bytes[12..<(12 + headerLength)])
        let archive = Data(bytes[(12 + headerLength)...])

        var rsaProofs: [(key: [UInt8], signature: [UInt8])] = []
        var signedHeaderData: [UInt8]?
        for (field, value) in try Self.fields(header) {
            switch field {
            case 2:
                let proof = Dictionary(try Self.fields(value), uniquingKeysWith: { first, _ in first })
                if let key = proof[1], let signature = proof[2] { rsaProofs.append((key, signature)) }
            case 10000:
                signedHeaderData = value
            default:
                continue
            }
        }
        guard let signedHeaderData,
              let crxID = Dictionary(try Self.fields(signedHeaderData), uniquingKeysWith: { first, _ in first })[1],
              Self.extensionID(fromHash: crxID) == expectedID else { throw Failure.idMismatch }

        // The proof whose key hashes to the extension ID is the publisher's.
        guard let proof = rsaProofs.first(where: { Self.extensionID(forKey: $0.key) == expectedID }) else { throw Failure.idMismatch }

        var message = Data("CRX3 SignedData\u{0}".utf8)
        var length = UInt32(signedHeaderData.count).littleEndian
        message.append(Data(bytes: &length, count: 4))
        message.append(contentsOf: signedHeaderData)
        message.append(archive)
        // Older extensions have 1024-bit publisher keys ("MIGf…" manifest
        // keys), which Chrome still accepts: the unsafe initializer allows
        // them (1024 bits minimum) where the default one requires 2048.
        guard let rsaKey = try? _RSA.Signing.PublicKey(unsafeDERRepresentation: proof.key),
              rsaKey.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: proof.signature),
                                      for: SHA256.hash(data: message), padding: .insecurePKCS1v1_5) else { throw Failure.invalidSignature }

        id = expectedID
        publicKey = Data(proof.key)
        self.archive = archive
    }

    // MARK: Extension IDs

    /// Chrome's ID alphabet: hex digits 0–f mapped to letters a–p.
    public static func extensionID(fromHash hash: [UInt8]) -> String {
        hash.prefix(16).map { byte in
            String([Character(UnicodeScalar(UInt8(ascii: "a") + (byte >> 4))),
                    Character(UnicodeScalar(UInt8(ascii: "a") + (byte & 0x0F)))])
        }.joined()
    }

    public static func extensionID(forKey key: [UInt8]) -> String {
        extensionID(fromHash: Array(SHA256.hash(data: key)))
    }

    // MARK: Protobuf (length-delimited fields only)

    private static func varint(_ bytes: [UInt8], _ index: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { break }
        }
        throw Failure.malformed
    }

    /// Length-delimited fields of a protobuf message (other wire types skipped).
    private static func fields(_ bytes: [UInt8]) throws -> [(Int, [UInt8])] {
        var index = 0
        var result: [(Int, [UInt8])] = []
        while index < bytes.count {
            let key = try varint(bytes, &index)
            let field = Int(key >> 3)
            switch key & 0x7 {
            case 0: _ = try varint(bytes, &index)
            case 1: index += 8
            case 5: index += 4
            case 2:
                let length = Int(try varint(bytes, &index))
                guard length >= 0, index + length <= bytes.count else { throw Failure.malformed }
                result.append((field, Array(bytes[index..<(index + length)])))
                index += length
            default: throw Failure.malformed
            }
        }
        return result
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
