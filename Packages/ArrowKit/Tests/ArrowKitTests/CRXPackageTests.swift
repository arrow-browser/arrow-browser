import CryptoKit
import Foundation
import Security
import Testing
@testable import ArrowKit

/// Builds signed CRX3 packages to check `CRXPackage` verification.
private struct CRXBuilder {
    let privateKey: SecKey
    let spki: [UInt8]

    init() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error!.takeRetainedValue()
        }
        privateKey = key
        spki = Self.subjectPublicKeyInfo(pkcs1: [UInt8](pkcs1))
    }

    var id: String { CRXPackage.extensionID(forKey: spki) }

    func build(archive: Data, signedID: String? = nil, tamper: Bool = false) throws -> Data {
        let crxID = Array(SHA256.hash(data: spki).prefix(16))
        let signedData = Self.field(1, signedID.map { Self.idBytes($0) } ?? crxID)
        var message = Data("CRX3 SignedData\u{0}".utf8)
        var length = UInt32(signedData.count).littleEndian
        message.append(Data(bytes: &length, count: 4))
        message.append(contentsOf: signedData)
        message.append(archive)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error) as Data? else {
            throw error!.takeRetainedValue()
        }
        let proof = Self.field(1, spki) + Self.field(2, [UInt8](signature))
        let header = Self.field(2, proof) + Self.field(10000, signedData)
        var crx = Data("Cr24".utf8)
        var version = UInt32(3).littleEndian
        var headerLength = UInt32(header.count).littleEndian
        crx.append(Data(bytes: &version, count: 4))
        crx.append(Data(bytes: &headerLength, count: 4))
        crx.append(contentsOf: header)
        var payload = archive
        if tamper { payload[payload.startIndex] ^= 0xFF }
        crx.append(payload)
        return crx
    }

    private static func idBytes(_ id: String) -> [UInt8] {
        let letters = Array(id.utf8).map { $0 - UInt8(ascii: "a") }
        return stride(from: 0, to: letters.count, by: 2).map { letters[$0] << 4 | letters[$0 + 1] }
    }

    private static func varint(_ value: Int) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value > 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value > 0
        return bytes
    }

    private static func field(_ number: Int, _ bytes: [UInt8]) -> [UInt8] {
        varint(number << 3 | 2) + varint(bytes.count) + bytes
    }

    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        if length < 0x100 { return [0x81, UInt8(length)] }
        return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
    }

    /// Wraps a PKCS#1 RSA public key in a SubjectPublicKeyInfo.
    private static func subjectPublicKeyInfo(pkcs1: [UInt8]) -> [UInt8] {
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString: [UInt8] = [0x03] + derLength(pkcs1.count + 1) + [0x00] + pkcs1
        let body = algorithm + bitString
        return [0x30] + derLength(body.count) + body
    }
}

struct CRXPackageTests {
    private let archive = Data("PK\u{3}\u{4} fake zip payload".utf8)

    @Test func acceptsValidPackage() throws {
        let builder = try CRXBuilder()
        let package = try CRXPackage(data: builder.build(archive: archive), expectedID: builder.id)
        #expect(package.id == builder.id)
        #expect(package.archive == archive)
        #expect(package.publicKey == Data(builder.spki))
    }

    @Test func rejectsTamperedArchive() throws {
        let builder = try CRXBuilder()
        #expect(throws: CRXPackage.Failure.self) {
            try CRXPackage(data: builder.build(archive: archive, tamper: true), expectedID: builder.id)
        }
    }

    @Test func rejectsAnotherExtensionID() throws {
        let builder = try CRXBuilder()
        let other = String(repeating: "a", count: 32)
        #expect(throws: CRXPackage.Failure.self) {
            try CRXPackage(data: builder.build(archive: archive), expectedID: other)
        }
        // A header claiming another ID is rejected as well.
        #expect(throws: CRXPackage.Failure.self) {
            try CRXPackage(data: builder.build(archive: archive, signedID: other), expectedID: builder.id)
        }
    }

    @Test func rejectsNonCRXData() {
        #expect(throws: CRXPackage.Failure.self) {
            try CRXPackage(data: Data("not a crx".utf8), expectedID: String(repeating: "b", count: 32))
        }
    }

    @Test func derivesChromeExtensionIDs() {
        #expect(CRXPackage.extensionID(fromHash: [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
                                                  0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF])
                    == "abcdefghijklmnopabcdefghijklmnop")
    }
}
