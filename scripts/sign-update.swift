// Signs Arrow update archives for the appcast (Sparkle-compatible EdDSA).
//   swift scripts/sign-update.swift generate-keys
//   swift scripts/sign-update.swift sign Arrow-1.2.0.zip
// Like Sparkle's generate_keys, the private key is kept in the login Keychain
// ("Arrow Update Signing Key"); ARROW_UPDATE_PRIVATE_KEY overrides it (CI).
// Put the public key in Resources/Arrow-Info.plist (SUPublicEDKey) and the
// signature and length in the server's releases/releases.json.
import CryptoKit
import Foundation
import Security

let service = "Arrow Update Signing Key"
let account = "ed25519"

func storedKey() -> Curve25519.Signing.PrivateKey? {
    var item: CFTypeRef?
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
    ]
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data, let raw = Data(base64Encoded: data) else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "generate-keys":
    if let key = storedKey() {
        print("A key already exists in the Keychain. Public key (SUPublicEDKey):")
        print(key.publicKey.rawRepresentation.base64EncodedString())
        exit(0)
    }
    let key = Curve25519.Signing.PrivateKey()
    let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrLabel as String: service,
        kSecValueData as String: Data(key.rawRepresentation.base64EncodedString().utf8),
    ]
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("Could not save the key in the Keychain (\(status)).") }
    print("Private key saved in the login Keychain as \"\(service)\". Back it up: without it, installed copies")
    print("of Arrow cannot be updated. Public key (SUPublicEDKey):")
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = arguments.dropFirst().first else { fail("usage: sign-update.swift sign <archive>") }
    let key: Curve25519.Signing.PrivateKey
    if let secret = ProcessInfo.processInfo.environment["ARROW_UPDATE_PRIVATE_KEY"] {
        guard let raw = Data(base64Encoded: secret),
              let parsed = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
            fail("ARROW_UPDATE_PRIVATE_KEY is not a base64 Ed25519 private key.")
        }
        key = parsed
    } else if let stored = storedKey() {
        key = stored
    } else {
        fail("No signing key: run generate-keys or set ARROW_UPDATE_PRIVATE_KEY.")
    }
    let archive = try Data(contentsOf: URL(fileURLWithPath: path))
    let signature = try key.signature(for: archive)
    print("edSignature: \(signature.base64EncodedString())")
    print("length: \(archive.count)")
default:
    print("usage: sign-update.swift generate-keys | sign <archive>")
    exit(64)
}
