import ArrowCEF
import ArrowCore
import ArrowKit
import WinSDK

/// The window's commands: those the command bar offers ("Copy URL"…) and
/// the keyboard shortcuts, Arc's on Windows (Ctrl for the Mac's ⌘, Alt for
/// ⌥). The page's browser reports keys before the page gets them, and the
/// window those its controls leave.
@MainActor
enum CommandCatalog {
    private struct Entry {
        /// Nil for a shortcut the command bar does not offer (Back…).
        let command: CommandBarCommand?
        let keys: [CEFKeyEvent]
        let action: @MainActor (BrowserWindow) -> Void
    }

    private static let entries: [Entry] = [
        shortcut([.key("T", .control)]) { $0.showCommandBar(mode: .newTab) },
        shortcut([.key("L", .control)]) { $0.openCommandBar() },
        shortcut([.key("W", .control)]) { $0.closeSelectedTab() },
        shortcut([.key("R", .control), .key(VK_F5)]) { $0.selectedTab?.reload() },
        shortcut([.key(VK_LEFT, .alt)]) { $0.selectedTab?.goBack() },
        shortcut([.key(VK_RIGHT, .alt)]) { $0.selectedTab?.goForward() },
        entry("copy-url", "Copy URL", ["link", "share"], "link", [.key("C", [.control, .shift])]) { $0.copyURL() },
        entry("pin", "Pin/Unpin Tab", ["favorite"], "pin", [.key("D", .control)]) { $0.togglePinTab() },
        entry("toggle-sidebar", "Toggle Sidebar", ["hide", "show"], "sidebar.left", [.key("S", .control)]) {
            $0.toggleSidebar()
        },
        entry("next-space", "Next Space", [], "arrow.right.square", [.key(VK_RIGHT, [.control, .alt])]) {
            $0.selectSpace(offset: 1)
        },
        entry("previous-space", "Previous Space", [], "arrow.left.square", [.key(VK_LEFT, [.control, .alt])]) {
            $0.selectSpace(offset: -1)
        },
        entry("clear-unpinned", "Clear Unpinned Tabs", ["close", "archive", "today"], "xmark.circle",
              [.key("K", [.control, .shift])]) { $0.clearToday() },
        entry("reopen", "Restore Last Closed Tab", ["undo", "reopen"], "arrow.uturn.backward",
              [.key("T", [.control, .shift])]) { $0.reopenLastClosedTab() },
    ]

    private static func entry(_ id: String, _ title: String, _ keywords: [String], _ symbol: String,
                              _ keys: [CEFKeyEvent], _ action: @escaping @MainActor (BrowserWindow) -> Void) -> Entry {
        let command = CommandBarCommand(id: id, title: title, keywords: keywords, symbol: symbol,
                                        shortcut: keys.first?.label)
        return Entry(command: command, keys: keys, action: action)
    }

    private static func shortcut(_ keys: [CEFKeyEvent],
                                 _ action: @escaping @MainActor (BrowserWindow) -> Void) -> Entry {
        Entry(command: nil, keys: keys, action: action)
    }

    static var commands: [CommandBarCommand] { entries.compactMap(\.command) }

    static func perform(_ id: String, in window: BrowserWindow) {
        entries.first { $0.command?.id == id }?.action(window)
    }

    static func handles(_ key: CEFKeyEvent) -> Bool {
        entries.contains { $0.keys.contains(key) }
    }

    /// Runs the command of `key`: whether it has one.
    static func handle(_ key: CEFKeyEvent, in window: BrowserWindow) -> Bool {
        guard let entry = entries.first(where: { $0.keys.contains(key) }) else { return false }
        entry.action(window)
        return true
    }
}

extension CEFKeyEvent {
    static func key(_ code: Int32, _ modifiers: Modifiers = []) -> CEFKeyEvent {
        CEFKeyEvent(keyCode: code, modifiers: modifiers)
    }

    /// A letter's key: its virtual-key code is the capital's.
    static func key(_ letter: Character, _ modifiers: Modifiers = []) -> CEFKeyEvent {
        CEFKeyEvent(keyCode: Int32(letter.asciiValue ?? 0), modifiers: modifiers)
    }

    /// `code` with the modifiers held now, for a key the window reports.
    static func held(_ code: Int32) -> CEFKeyEvent {
        func isHeld(_ key: Int32) -> Bool { GetKeyState(key) < 0 }
        var modifiers: Modifiers = []
        if isHeld(VK_SHIFT) { modifiers.insert(.shift) }
        // AltGr, held as Ctrl+Alt, types characters (@, €…).
        if !isHeld(VK_RMENU) {
            if isHeld(VK_CONTROL) { modifiers.insert(.control) }
            if isHeld(VK_MENU) { modifiers.insert(.alt) }
        }
        return CEFKeyEvent(keyCode: code, modifiers: modifiers)
    }

    /// "Ctrl+Shift+T", as Windows writes shortcuts.
    var label: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.alt) { parts.append("Alt") }
        switch keyCode {
        case VK_LEFT: parts.append("Left")
        case VK_RIGHT: parts.append("Right")
        case VK_F1...VK_F24: parts.append("F\(keyCode - VK_F1 + 1)")
        default: parts.append(String(UnicodeScalar(UInt8(clamping: keyCode))))
        }
        return parts.joined(separator: "+")
    }
}
