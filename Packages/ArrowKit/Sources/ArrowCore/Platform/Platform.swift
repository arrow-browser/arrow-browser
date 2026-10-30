import ArrowKit
import Foundation

/// What the shared core asks of the app on each platform (see "Platform
/// services" in docs/PORTABILITY.md). The macOS app implements it with
/// AppKit and the Keychain (`MacPlatform`).
@MainActor
public protocol Platform: AnyObject, Sendable {
    /// Saved logins and payment cards (Autofill).
    var credentials: any CredentialStore { get }
    /// Arrow Cloud's account token and sync key.
    var cloudSecrets: any SecretStore { get }
    /// Version of the app, e.g. "1.0.0".
    var appVersion: String { get }
    /// The system appearance is dark.
    var isDarkAppearance: Bool { get }
    /// Keyboard modifiers held right now.
    var heldModifiers: KeyModifiers { get }

    func copyToClipboard(_ text: String)
    func play(_ sound: SoundEffect)
    /// Shows `file` in the file manager.
    func reveal(_ file: URL)
    /// Opens `file` with its default app.
    func open(_ file: URL)
    /// `file` was created or renamed, for file managers that cache listings.
    func fileDidChange(_ file: URL)
    /// Extracts a ZIP archive into `directory` (Chrome extensions). Called
    /// off the main thread.
    nonisolated func unzip(_ archive: URL, into directory: URL) throws
    /// Applies the settings the app handles itself (global shortcut, menu
    /// shortcuts) after they changed.
    func apply(_ settings: ArrowSettings, previous: ArrowSettings)
}

/// A login saved by Arrow (Preferences ▸ Profiles ▸ Passwords).
public struct SavedLogin: Identifiable, Hashable, Sendable {
    public var id: String { host + "\n" + username }
    public let host: String
    public let username: String
    public let modified: Date?

    public init(host: String, username: String, modified: Date?) {
        self.host = host
        self.username = username
        self.modified = modified
    }
}

/// Saved logins and payment cards, kept by the system's credential store.
@MainActor
public protocol CredentialStore: AnyObject {
    /// Logins saved for `host`, or every login when nil.
    func logins(for host: String?) -> [SavedLogin]
    func password(host: String, username: String) -> String?
    func savePassword(_ password: String, host: String, username: String)
    func deletePassword(host: String, username: String)
    func cards() -> [PaymentCard]
    func save(_ card: PaymentCard)
    func delete(_ card: PaymentCard)
}

/// Strings kept by the system's credential store, by account name.
@MainActor
public protocol SecretStore: AnyObject {
    func secret(for account: String) -> String?
    /// Stores `value`, or deletes the secret when nil.
    func setSecret(_ value: String?, for account: String)
}

/// Keyboard modifiers (links clicked with ⌥⌘ open in Little Arrow, with ⇧ in
/// Peek).
public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

/// Preferences ▸ Advanced ▸ Play Arrow sound effects: a chime for events
/// (copy, pin, archive) and a shutter for captures.
public enum SoundEffect: String, Sendable {
    case event
    case capture
}
