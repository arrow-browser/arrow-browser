import AppKit
import Carbon.HIToolbox

/// Preferences ▸ Links ▸ Open Little Arc when I press ⌥⌘N in any app.
@MainActor
final class GlobalShortcut {
    static let littleArrow = GlobalShortcut()

    var action: (() -> Void)?
    /// Result of the last registration (noErr when ⌥⌘N belongs to Arrow).
    private(set) var status: OSStatus?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func setEnabled(_ enabled: Bool) {
        enabled ? register() : unregister()
    }

    private func register() {
        guard hotKey == nil else { return }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { GlobalShortcut.littleArrow.action?() }
                return noErr
            }, 1, &type, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4152_5257), id: 1) // "ARRW"
        status = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}
