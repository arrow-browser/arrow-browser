import ArrowCEF
import ArrowCore
import ArrowKit
import WinSDK

/// Arc's keyboard shortcuts on Windows (Ctrl for the Mac's ⌘, Alt for ⌥),
/// shared by the window's commands and the menus, which show them.
@MainActor
enum Shortcut {
    static let newTab = CEFKeyEvent.key("T", .control)
    static let commandBar = CEFKeyEvent.key("L", .control)
    static let closeTab = CEFKeyEvent.key("W", .control)
    static let reload = CEFKeyEvent.key("R", .control)
    static let back = CEFKeyEvent.key(VK_LEFT, .alt)
    static let forward = CEFKeyEvent.key(VK_RIGHT, .alt)
    static let copyURL = CEFKeyEvent.key("C", [.control, .shift])
    static let pinTab = CEFKeyEvent.key("D", .control)
    static let toggleSidebar = CEFKeyEvent.key("S", .control)
    static let nextSpace = CEFKeyEvent.key(VK_RIGHT, [.control, .alt])
    static let previousSpace = CEFKeyEvent.key(VK_LEFT, [.control, .alt])
    static let clearToday = CEFKeyEvent.key("K", [.control, .shift])
    static let reopenTab = CEFKeyEvent.key("T", [.control, .shift])
    static let newWindow = CEFKeyEvent.key("N", .control)
    static let newIncognitoWindow = CEFKeyEvent.key("N", [.control, .shift])
    static let settings = CEFKeyEvent.key(VK_OEM_COMMA, .control)
    static let print = CEFKeyEvent.key("P", .control)
    /// Shown only: Windows closes the window itself.
    static let close = CEFKeyEvent.key(VK_F4, .alt)
    static let viewSource = CEFKeyEvent.key("U", .control)
    static let developerTools = CEFKeyEvent.key("I", [.control, .shift])
    static let newSplitView = CEFKeyEvent.key(VK_OEM_PLUS, [.control, .shift])
    static let find = CEFKeyEvent.key("F", .control)
    static let nextTab = CEFKeyEvent.key(VK_TAB, .control)
    static let previousTab = CEFKeyEvent.key(VK_TAB, [.control, .shift])
    static let zoomIn = CEFKeyEvent.key(VK_OEM_PLUS, .control)
    static let zoomOut = CEFKeyEvent.key(VK_OEM_MINUS, .control)
    static let actualSize = CEFKeyEvent.key("0", .control)

    /// Alt+1…9: the spaces, in the sidebar's order.
    static func space(_ index: Int) -> CEFKeyEvent {
        CEFKeyEvent.key(Int32(0x31 + index), .alt)
    }

    /// Ctrl+1…9: the sidebar's tabs, Ctrl+9 its last.
    static func tab(_ index: Int) -> CEFKeyEvent {
        CEFKeyEvent.key(Int32(0x31 + index), .control)
    }
}

/// The window's commands: those the command bar offers ("Copy URL"…) and
/// the keyboard shortcuts. The page's browser reports keys before the page
/// gets them, and the window those its controls leave.
@MainActor
enum CommandCatalog {
    private struct Entry {
        /// Nil for a shortcut the command bar does not offer (Back…).
        let command: CommandBarCommand?
        let keys: [CEFKeyEvent]
        let action: @MainActor (BrowserWindow) -> Void
    }

    private static let entries: [Entry] = [
        shortcut([Shortcut.newTab]) { $0.showCommandBar(mode: .newTab) },
        shortcut([Shortcut.commandBar]) { $0.openCommandBar() },
        shortcut([Shortcut.closeTab]) { $0.closeSelectedTab() },
        shortcut([Shortcut.reload, .key(VK_F5)]) { $0.selectedTab?.reload() },
        shortcut([Shortcut.back]) { $0.selectedTab?.goBack() },
        shortcut([Shortcut.forward]) { $0.selectedTab?.goForward() },
        shortcut([Shortcut.nextTab]) { $0.selectTab(offset: 1) },
        shortcut([Shortcut.previousTab]) { $0.selectTab(offset: -1) },
        shortcut([Shortcut.zoomIn]) { $0.selectedTab?.zoomIn() },
        shortcut([Shortcut.zoomOut]) { $0.selectedTab?.zoomOut() },
        shortcut([Shortcut.actualSize]) { $0.selectedTab?.resetZoom() },
        entry("copy-url", "Copy URL", ["link", "share"], "link", [Shortcut.copyURL]) { $0.copyURL() },
        entry("pin", "Pin/Unpin Tab", ["favorite"], "pin", [Shortcut.pinTab]) { $0.togglePinTab() },
        entry("split", "Add Split View", ["side by side", "pane"], "rectangle.split.2x1", [Shortcut.newSplitView]) {
            $0.addSplitView()
        },
        entry("toggle-sidebar", "Toggle Sidebar", ["hide", "show"], "sidebar.left", [Shortcut.toggleSidebar]) {
            $0.toggleSidebar()
        },
        entry("new-space", "New Space", ["create", "theme"], "plus.square.on.square", []) { $0.newSpace() },
        entry("edit-theme", "Edit Theme Color", ["color", "space"], "paintpalette", []) {
            $0.editTheme(of: $0.state.selectedSpaceID)
        },
        entry("next-space", "Next Space", [], "arrow.right.square", [Shortcut.nextSpace]) { $0.selectSpace(offset: 1) },
        entry("previous-space", "Previous Space", [], "arrow.left.square", [Shortcut.previousSpace]) {
            $0.selectSpace(offset: -1)
        },
        entry("new-folder", "New Folder", ["group"], "folder.badge.plus", []) { $0.newFolder() },
        entry("translate", "Translate Page", ["language"], "character.bubble", []) { $0.translatePage() },
        entry("clear-unpinned", "Clear Today Tabs", ["close", "archive", "unpinned"], "xmark.circle",
              [Shortcut.clearToday]) { $0.clearToday() },
        entry("reopen", "Reopen Last Closed Tab", ["undo", "restore"], "arrow.uturn.backward", [Shortcut.reopenTab]) {
            $0.reopenLastClosedTab()
        },
        entry("archive", "View Archive", ["history", "closed"], "archivebox", []) { $0.showArchive() },
        entry("find", "Find in Page", ["search"], "magnifyingglass", [Shortcut.find]) { $0.showFindBar() },
        entry("devtools", "Developer Tools", ["inspect", "console", "debug"], "hammer",
              [Shortcut.developerTools, .key(VK_F12)]) { $0.showDeveloperTools() },
        entry("view-source", "View Source", ["html"], "doc.plaintext", [Shortcut.viewSource]) { $0.viewSource() },
        entry("print", "Print", [], "printer", [Shortcut.print]) { $0.printPage() },
        entry("new-window", "New Window", [], "macwindow", [Shortcut.newWindow]) { _ in ArrowApp.openWindow() },
        entry("incognito", "New Incognito Window", ["private"], "theatermasks", [Shortcut.newIncognitoWindow]) { _ in
            ArrowApp.openWindow(incognito: true)
        },
        entry("settings", "Settings", ["preferences"], "gearshape", [Shortcut.settings]) { _ in SettingsWindow.show() },
    ] + (0..<9).map { index in
        shortcut([Shortcut.space(index)]) { $0.selectSpace(at: index) }
    } + (0..<9).map { index in
        shortcut([Shortcut.tab(index)]) { $0.selectTab(at: index) }
    }

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

    /// A letter's or a digit's key: its virtual-key code is the character's
    /// (the capital's for letters).
    static func key(_ character: Character, _ modifiers: Modifiers = []) -> CEFKeyEvent {
        CEFKeyEvent(keyCode: Int32(character.asciiValue ?? 0), modifiers: modifiers)
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
        case VK_TAB: parts.append("Tab")
        case VK_OEM_COMMA: parts.append(",")
        case VK_OEM_PLUS: parts.append("+")
        case VK_OEM_MINUS: parts.append("-")
        case VK_F1...VK_F24: parts.append("F\(keyCode - VK_F1 + 1)")
        default: parts.append(String(UnicodeScalar(UInt8(clamping: keyCode))))
        }
        return parts.joined(separator: "+")
    }
}
