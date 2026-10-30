import ArrowCore
import ArrowKit
import Foundation
import Testing
@testable import ArrowWindows

/// Round trips through the user's Credential Manager, under a prefix of their
/// own: Arrow's credentials are never read or changed.
@MainActor
struct CredentialManagerTests {
    private let vault = CredentialManager(prefix: "ArrowTests-\(UUID().uuidString)")

    @Test func savesReadsAndDeletesLogins() {
        let store = WindowsCredentials(vault: vault)
        store.savePassword("first", host: "example.com", username: "ann/smith")
        store.savePassword("other", host: "example.org", username: "bob")
        defer {
            store.deletePassword(host: "example.com", username: "ann/smith")
            store.deletePassword(host: "example.org", username: "bob")
        }

        #expect(store.password(host: "example.com", username: "ann/smith") == "first")
        #expect(store.logins(for: "example.com").map(\.username) == ["ann/smith"])
        #expect(store.logins(for: nil).map(\.host) == ["example.com", "example.org"])
        #expect(store.logins(for: nil).allSatisfy { $0.modified.map { abs($0.timeIntervalSinceNow) < 600 } == true })

        store.savePassword("second", host: "example.com", username: "ann/smith")
        #expect(store.password(host: "example.com", username: "ann/smith") == "second")
        #expect(store.logins(for: "example.com").count == 1)

        store.deletePassword(host: "example.com", username: "ann/smith")
        #expect(store.password(host: "example.com", username: "ann/smith") == nil)
        #expect(store.logins(for: nil).map(\.host) == ["example.org"])
    }

    @Test func savesAndDeletesCards() {
        let store = WindowsCredentials(vault: vault)
        let card = PaymentCard(holder: "Ann Smith", number: "4111111111111111", expiryMonth: 4, expiryYear: 2031)
        store.save(card)
        defer { store.delete(card) }

        #expect(store.cards() == [card])
        store.delete(card)
        #expect(store.cards().isEmpty)
    }

    @Test func setsAndClearsSecrets() {
        let secrets = WindowsSecrets(vault: vault)
        secrets.setSecret("token-value", for: "token")
        defer { secrets.setSecret(nil, for: "token") }

        #expect(secrets.secret(for: "token") == "token-value")
        #expect(secrets.secret(for: "syncKey") == nil)
        secrets.setSecret(nil, for: "token")
        #expect(secrets.secret(for: "token") == nil)
    }
}
