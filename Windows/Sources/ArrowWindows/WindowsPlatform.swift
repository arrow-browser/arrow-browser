import ArrowCore
import ArrowKit
import Foundation
import WinSDK

/// ArrowCore's platform services on Windows.
final class WindowsPlatform: Platform {
    // Saving them in the Credential Manager comes next (docs/PORTABILITY.md):
    // until then they last for the session and are never written to disk.
    let credentials: any CredentialStore = SessionCredentials()
    let cloudSecrets: any SecretStore = SessionSecrets()

    var appVersion: String { ArrowApp.version }

    var isDarkAppearance: Bool {
        var value: DWORD = 1
        var size = DWORD(MemoryLayout<DWORD>.size)
        let status = #"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"#.withWideString { key in
            "AppsUseLightTheme".withWideString { name in
                RegGetValueW(currentUserKey, key, name, DWORD(RRF_RT_REG_DWORD), nil, &value, &size)
            }
        }
        return status == ERROR_SUCCESS && value == 0
    }

    /// Windows' counterparts of the Mac's modifiers: Ctrl for ⌘, Alt for ⌥.
    var heldModifiers: KeyModifiers {
        func isHeld(_ key: Int32) -> Bool { GetKeyState(key) < 0 }
        var modifiers: KeyModifiers = []
        if isHeld(VK_SHIFT) { modifiers.insert(.shift) }
        if isHeld(VK_CONTROL) { modifiers.insert(.command) }
        if isHeld(VK_MENU) { modifiers.insert(.option) }
        if isHeld(VK_LWIN) || isHeld(VK_RWIN) { modifiers.insert(.control) }
        return modifiers
    }

    func copyToClipboard(_ text: String) {
        guard OpenClipboard(nil) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        let characters = Array(text.utf16) + [0]
        let size = characters.count * MemoryLayout<UInt16>.size
        guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(size)) else { return }
        guard let pointer = GlobalLock(memory) else {
            GlobalFree(memory)
            return
        }
        characters.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: size) }
        GlobalUnlock(memory)
        // The clipboard owns the memory once it accepts it.
        if SetClipboardData(UINT(CF_UNICODETEXT), memory) == nil { GlobalFree(memory) }
    }

    func play(_ sound: SoundEffect) {
        // Arrow's sound effects are not part of the Windows app yet.
    }

    func reveal(_ file: URL) {
        file.nativePath.withWideString { path in
            guard let item = ILCreateFromPathW(path) else { return }
            defer { ILFree(item) }
            SHOpenFolderAndSelectItems(item, 0, nil, 0)
        }
    }

    func open(_ file: URL) {
        "open".withWideString { verb in
            file.nativePath.withWideString { path in
                _ = ShellExecuteW(nil, verb, path, nil, nil, SW_SHOWNORMAL)
            }
        }
    }

    func fileDidChange(_ file: URL) {
        // Explorer watches the folders it shows.
    }

    nonisolated func unzip(_ archive: URL, into directory: URL) throws {
        // Windows' tar (bsdtar) extracts ZIP archives, and refuses absolute
        // paths and `..`.
        let process = Process()
        let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#
        process.executableURL = URL(fileURLWithPath: system).appendingPathComponent("System32/tar.exe")
        process.arguments = ["-xf", archive.nativePath, "-C", directory.nativePath]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CRXPackage.Failure.malformed }
    }

    func apply(_ settings: ArrowSettings, previous: ArrowSettings) {
        // No global shortcut or menu shortcuts on Windows yet.
    }
}

/// Logins and cards kept in memory for the session.
final class SessionCredentials: CredentialStore {
    private var passwords: [String: (login: SavedLogin, password: String)] = [:]
    private var savedCards: [PaymentCard] = []

    func logins(for host: String?) -> [SavedLogin] {
        passwords.values.map(\.login).filter { host == nil || $0.host == host }
    }

    func password(host: String, username: String) -> String? {
        passwords[host + "\n" + username]?.password
    }

    func savePassword(_ password: String, host: String, username: String) {
        passwords[host + "\n" + username] = (SavedLogin(host: host, username: username, modified: Date()), password)
    }

    func deletePassword(host: String, username: String) {
        passwords[host + "\n" + username] = nil
    }

    func cards() -> [PaymentCard] { savedCards }

    func save(_ card: PaymentCard) {
        savedCards.removeAll { $0.id == card.id }
        savedCards.append(card)
    }

    func delete(_ card: PaymentCard) {
        savedCards.removeAll { $0.id == card.id }
    }
}

/// Arrow Cloud's secrets kept in memory for the session.
final class SessionSecrets: SecretStore {
    private var secrets: [String: String] = [:]

    func secret(for account: String) -> String? { secrets[account] }

    func setSecret(_ value: String?, for account: String) { secrets[account] = value }
}

/// HKEY_CURRENT_USER, a macro Swift does not import.
private var currentUserKey: HKEY? { HKEY(bitPattern: Int(Int32(bitPattern: 0x8000_0001))) }

extension String {
    /// Calls `body` with the string as a NUL-terminated UTF-16 string.
    func withWideString<Result>(_ body: (UnsafePointer<WCHAR>) throws -> Result) rethrows -> Result {
        try withCString(encodedAs: UTF16.self, body)
    }
}

extension URL {
    /// The file's path in Windows' form (`C:\…`).
    var nativePath: String {
        withUnsafeFileSystemRepresentation { String(cString: $0!) }
    }
}
