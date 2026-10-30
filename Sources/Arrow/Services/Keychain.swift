import ArrowCore
import ArrowKit
import Foundation
import Security

/// Generic passwords of the "Arrow Cloud" Keychain service.
enum Keychain {
    private static let service = "Arrow Cloud"

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

/// Saved logins, as internet passwords in the login Keychain (Preferences ▸
/// Profiles ▸ Passwords). Only items created by Arrow are listed.
@MainActor
enum PasswordStore {
    typealias Login = SavedLogin

    private static let itemDescription = "Arrow saved login"

    static func logins(for host: String? = nil) -> [Login] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrDescription as String: itemDescription,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        if let host { query[kSecAttrServer as String] = host }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let server = item[kSecAttrServer as String] as? String else { return nil }
            return Login(host: server, username: item[kSecAttrAccount as String] as? String ?? "",
                         modified: item[kSecAttrModificationDate as String] as? Date)
        }
        .sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    static func password(host: String, username: String) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(host: host, username: username).merging([
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { $1 } as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(host: String, username: String, password: String) {
        let data = Data(password.utf8)
        let base = query(host: host, username: username)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            SecItemAdd(base.merging([
                kSecValueData as String: data,
                kSecAttrLabel as String: host,
                kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            ]) { $1 } as CFDictionary, nil)
        }
    }

    static func delete(host: String, username: String) {
        SecItemDelete(query(host: host, username: username) as CFDictionary)
    }

    private static func query(host: String, username: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: username,
            kSecAttrDescription as String: itemDescription,
        ]
    }
}

/// Saved payment cards, as generic passwords in the login Keychain
/// (Preferences ▸ Profiles ▸ Credit Cards).
@MainActor
enum CardStore {
    private static let service = "Arrow Payment Cards"

    static func cards() -> [PaymentCard] {
        // The file-based keychain returns data for one item at a time only.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item -> PaymentCard? in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            var data: CFTypeRef?
            let one: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
            ]
            guard SecItemCopyMatching(one as CFDictionary, &data) == errSecSuccess, let data = data as? Data else { return nil }
            return try? JSONDecoder().decode(PaymentCard.self, from: data)
        }
        .sorted { $0.label < $1.label }
    }

    static func save(_ card: PaymentCard) {
        guard let data = try? JSONEncoder().encode(card) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: card.id.uuidString,
        ]
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            SecItemAdd(base.merging([kSecValueData as String: data, kSecAttrLabel as String: card.label]) { $1 } as CFDictionary, nil)
        }
    }

    static func delete(_ card: PaymentCard) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: card.id.uuidString,
        ] as CFDictionary)
    }
}

/// The Keychain items above behind ArrowCore's credential stores.
final class KeychainCredentials: CredentialStore {
    func logins(for host: String?) -> [SavedLogin] { PasswordStore.logins(for: host) }
    func password(host: String, username: String) -> String? { PasswordStore.password(host: host, username: username) }
    func savePassword(_ password: String, host: String, username: String) {
        PasswordStore.save(host: host, username: username, password: password)
    }

    func deletePassword(host: String, username: String) { PasswordStore.delete(host: host, username: username) }
    func cards() -> [PaymentCard] { CardStore.cards() }
    func save(_ card: PaymentCard) { CardStore.save(card) }
    func delete(_ card: PaymentCard) { CardStore.delete(card) }
}

final class KeychainSecrets: SecretStore {
    func secret(for account: String) -> String? { Keychain.get(account: account) }
    func setSecret(_ value: String?, for account: String) { Keychain.set(value, account: account) }
}
