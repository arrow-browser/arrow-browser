import ArrowCore
import ArrowKit
import Foundation
import WinSDK

/// Generic credentials of the user in the Credential Manager, which Windows
/// encrypts with DPAPI, named "<prefix>/<kind>/<key>".
struct CredentialManager {
    /// Arrow's credentials ("Arrow/…").
    static let arrow = CredentialManager(prefix: "Arrow")

    let prefix: String

    struct Item {
        let key: String
        let userName: String
        let modified: Date
    }

    func blob(_ kind: String, _ key: String) -> Data? {
        var credential: PCREDENTIALW?
        guard targetName(kind, key).withWideString({ CredReadW($0, DWORD(CRED_TYPE_GENERIC), 0, &credential) }),
              let credential else { return nil }
        defer { CredFree(credential) }
        guard let bytes = credential.pointee.CredentialBlob else { return Data() }
        return Data(bytes: bytes, count: Int(credential.pointee.CredentialBlobSize))
    }

    /// Creates or replaces a credential, kept on this computer (not roamed).
    /// Blobs are at most 2,560 bytes.
    @discardableResult
    func write(_ kind: String, _ key: String, userName: String, blob: Data) -> Bool {
        var bytes = [UInt8](blob)
        return targetName(kind, key).withWideString { target in
            userName.withWideString { user in
                bytes.withUnsafeMutableBufferPointer { buffer in
                    var credential = CREDENTIALW()
                    credential.`Type` = DWORD(CRED_TYPE_GENERIC)
                    credential.TargetName = UnsafeMutablePointer(mutating: target)
                    credential.UserName = UnsafeMutablePointer(mutating: user)
                    credential.CredentialBlobSize = DWORD(buffer.count)
                    credential.CredentialBlob = buffer.baseAddress
                    credential.Persist = DWORD(CRED_PERSIST_LOCAL_MACHINE)
                    return CredWriteW(&credential, 0)
                }
            }
        }
    }

    func delete(_ kind: String, _ key: String) {
        _ = targetName(kind, key).withWideString { CredDeleteW($0, DWORD(CRED_TYPE_GENERIC), 0) }
    }

    /// Arrow's credentials of `kind`, without their blobs.
    func items(_ kind: String) -> [Item] {
        let prefix = targetName(kind, "")
        var count: DWORD = 0
        var credentials: UnsafeMutablePointer<PCREDENTIALW?>?
        guard (prefix + "*").withWideString({ CredEnumerateW($0, 0, &count, &credentials) }),
              let credentials else { return [] }
        defer { CredFree(credentials) }
        return (0..<Int(count)).compactMap { index in
            guard let credential = credentials[index]?.pointee, let name = credential.TargetName else { return nil }
            let target = String(decodingCString: name, as: UTF16.self)
            guard target.hasPrefix(prefix) else { return nil }
            let written = UInt64(credential.LastWritten.dwHighDateTime) << 32 | UInt64(credential.LastWritten.dwLowDateTime)
            return Item(key: String(target.dropFirst(prefix.count)),
                        userName: credential.UserName.map { String(decodingCString: $0, as: UTF16.self) } ?? "",
                        // FILETIME: 100 ns intervals since 1601.
                        modified: Date(timeIntervalSince1970: Double(written) / 10_000_000 - 11_644_473_600))
        }
    }

    private func targetName(_ kind: String, _ key: String) -> String {
        "\(prefix)/\(kind)/\(key)"
    }
}

/// Saved logins ("…/login/<host>/<username>") and payment cards
/// ("…/card/<id>", as JSON) in the Credential Manager.
final class WindowsCredentials: CredentialStore {
    private let vault: CredentialManager

    init(vault: CredentialManager = .arrow) {
        self.vault = vault
    }

    func logins(for host: String?) -> [SavedLogin] {
        vault.items("login").compactMap { item -> SavedLogin? in
            guard let slash = item.key.firstIndex(of: "/") else { return nil }
            let itemHost = String(item.key[..<slash])
            guard host == nil || itemHost == host else { return nil }
            return SavedLogin(host: itemHost, username: item.userName, modified: item.modified)
        }
        .sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    func password(host: String, username: String) -> String? {
        vault.blob("login", "\(host)/\(username)").map { String(decoding: $0, as: UTF8.self) }
    }

    func savePassword(_ password: String, host: String, username: String) {
        vault.write("login", "\(host)/\(username)", userName: username, blob: Data(password.utf8))
    }

    func deletePassword(host: String, username: String) {
        vault.delete("login", "\(host)/\(username)")
    }

    func cards() -> [PaymentCard] {
        vault.items("card").compactMap { item in
            vault.blob("card", item.key).flatMap { try? JSONDecoder().decode(PaymentCard.self, from: $0) }
        }
        .sorted { $0.label < $1.label }
    }

    func save(_ card: PaymentCard) {
        guard let data = try? JSONEncoder().encode(card) else { return }
        vault.write("card", card.id.uuidString, userName: card.label, blob: data)
    }

    func delete(_ card: PaymentCard) {
        vault.delete("card", card.id.uuidString)
    }
}

/// Arrow Cloud's account token and sync key ("…/cloud/<account>").
final class WindowsSecrets: SecretStore {
    private let vault: CredentialManager

    init(vault: CredentialManager = .arrow) {
        self.vault = vault
    }

    func secret(for account: String) -> String? {
        vault.blob("cloud", account).map { String(decoding: $0, as: UTF8.self) }
    }

    func setSecret(_ value: String?, for account: String) {
        if let value {
            vault.write("cloud", account, userName: account, blob: Data(value.utf8))
        } else {
            vault.delete("cloud", account)
        }
    }
}
