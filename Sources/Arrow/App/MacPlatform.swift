import AppKit
import ArrowCore
import ArrowKit

/// ArrowCore's platform services on macOS.
final class MacPlatform: Platform {
    let credentials: any CredentialStore = KeychainCredentials()
    let cloudSecrets: any SecretStore = KeychainSecrets()

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var isDarkAppearance: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    var heldModifiers: KeyModifiers {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func play(_ sound: SoundEffect) {
        SoundEffects.play(sound)
    }

    func reveal(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func open(_ file: URL) {
        NSWorkspace.shared.open(file)
    }

    func fileDidChange(_ file: URL) {
        NSWorkspace.shared.noteFileSystemChanged(file.path)
    }

    nonisolated func unzip(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CRXPackage.Failure.malformed }
    }

    func apply(_ settings: ArrowSettings, previous: ArrowSettings) {
        if settings.littleArrowShortcut != previous.littleArrowShortcut {
            GlobalShortcut.littleArrow.setEnabled(settings.littleArrowShortcut)
        }
        if settings.customShortcuts != previous.customShortcuts {
            MainMenu.applyShortcuts(settings.customShortcuts)
        }
    }
}
