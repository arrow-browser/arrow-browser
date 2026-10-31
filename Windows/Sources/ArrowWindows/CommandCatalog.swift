import ArrowCEF
import ArrowCore
import ArrowKit
import Foundation
import WinSDK

/// Arc's keyboard shortcuts on Windows (Ctrl for the Mac's ⌘, Alt for ⌥),
/// shared by the window's commands and the menus, which show them.
@MainActor
enum Shortcut {
    static let newTab = CEFKeyEvent.key("T", .control)
    static let commandBar = CEFKeyEvent.key("L", .control)
    static let closeTab = CEFKeyEvent.key("W", .control)
    static let reload = CEFKeyEvent.key("R", .control)
    static let forceReload = CEFKeyEvent.key("R", [.control, .shift])
    static let fullscreen = CEFKeyEvent.key(VK_F11)
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
        shortcut([Shortcut.back]) { $0.selectedTab?.goBack() },
        shortcut([Shortcut.forward]) { $0.selectedTab?.goForward() },
        shortcut([Shortcut.newWindow]) { _ in ArrowApp.openWindow() },
        shortcut([Shortcut.newIncognitoWindow]) { _ in ArrowApp.openWindow(incognito: true) },
        shortcut([Shortcut.find]) { $0.showFindBar() },
        // Arc's commands on Windows: its menus' and its tab's actions.
        entry("close", "Close", ["window"], "xmark", [Shortcut.close]) { $0.close() },
        entry("close-tab", "Close Current Tab", [], "xmark", [Shortcut.closeTab]) { $0.closeSelectedTab() },
        entry("reopen", "Reopen Last Closed Tab", ["undo", "restore"], "arrow.uturn.backward", [Shortcut.reopenTab]) {
            $0.reopenLastClosedTab()
        },
        entry("reload", "Reload Current Tab", ["refresh current tab"], "arrow.clockwise", [Shortcut.reload, .key(VK_F5)]) {
            $0.selectedTab?.reload()
        },
        entry("force-reload", "Force Reload Current Tab", ["force refresh current tab", "clear cache"],
              "arrow.clockwise", [Shortcut.forceReload, .key(VK_F5, .control)]) { $0.selectedTab?.engine?.reloadIgnoringCache() },
        entry("clear-archive", "Clear Archive", [], "archivebox", []) { window in
            window.store.update { $0.archive = [] }
        },
        entry("clear-unpinned", "Clear Today Tabs", ["unpinned"], "xmark.circle", [Shortcut.clearToday]) {
            $0.clearToday()
        },
        entry("console", "JavaScript Console", ["developer"], "hammer", []) { $0.showDeveloperTools(panel: "console") },
        entry("build-info", "Copy Build Info", ["version"], "gearshape", []) { $0.copyBuildInfo() },
        entry("duplicate", "Duplicate Current Tab", ["copy tab"], "plus.square.on.square", []) { window in
            guard let tabID = window.state.selectedTabID else { return }
            window.duplicateTab(tabID)
        },
        entry("copy-url", "Copy Current URL", ["link", "share"], "gearshape", [Shortcut.copyURL]) { $0.copyURL() },
        entry("default-browser", "Set Arrow as Default Browser", [], "heart", []) { $0.openDefaultBrowserSettings() },
        entry("devtools", "Developer", ["tools", "debug"], "hammer", [Shortcut.developerTools, .key(VK_F12)]) {
            $0.showDeveloperTools()
        },
        entry("add-extension", "Add Extension", ["chrome web store"], "puzzlepiece", []) { $0.addExtension() },
        entry("manage-extensions", "Manage Extensions", [], "puzzlepiece", []) { _ in
            SettingsWindow.show(section: .extensions)
        },
        entry("fullscreen", "Enter Fullscreen", [], "arrow.up.left.and.arrow.down.right", [Shortcut.fullscreen]) {
            $0.toggleFullscreen()
        },
        entry("import", "Import from Another Browser", ["bookmarks"], "square.and.arrow.down", []) {
            $0.importFromBrowser()
        },
        entry("inspect", "Inspect Elements", [], "hammer", []) { $0.inspectElements() },
        entry("network", "Network Inspector", [], "hammer", []) { $0.showDeveloperTools(panel: "network") },
        entry("next-tab", "Next Tab", [], "arrow.right", [Shortcut.nextTab]) { $0.selectTab(offset: 1) },
        entry("next-space", "Next Space", [], "arrow.right.square", [Shortcut.nextSpace]) { $0.selectSpace(offset: 1) },
        entry("pin", "Pin Tab", ["unpin"], "pin", [Shortcut.pinTab]) { $0.togglePinTab() },
        entry("favorite", "Favorite Tab", ["pin"], "star", []) { window in
            guard let tabID = window.state.selectedTabID else { return }
            window.store.update { _ = $0.move(tabID, to: .favorites()) }
        },
        entry("previous-tab", "Previous Tab", [], "arrow.left", [Shortcut.previousTab]) { $0.selectTab(offset: -1) },
        entry("previous-space", "Previous Space", [], "arrow.left.square", [Shortcut.previousSpace]) {
            $0.selectSpace(offset: -1)
        },
        entry("print", "Print", [], "printer", [Shortcut.print]) { $0.printPage() },
        entry("rename-space", "Rename Space", [], "pencil", []) { $0.rename($0.state.selectedSpaceID) },
        entry("rename-tab", "Rename Current Tab…", [], "pencil", []) { window in
            guard let tabID = window.state.selectedTabID else { return }
            window.rename(tabID)
        },
        entry("reset-zoom", "Reset Zoom", [], "plus.magnifyingglass", [Shortcut.actualSize]) {
            $0.selectedTab?.resetZoom()
        },
        entry("zoom-in", "Zoom In", [], "plus.magnifyingglass", [Shortcut.zoomIn]) { $0.selectedTab?.zoomIn() },
        entry("zoom-out", "Zoom Out", [], "minus.magnifyingglass", [Shortcut.zoomOut]) { $0.selectedTab?.zoomOut() },
        entry("reset-tabs", "Reset All Tabs in This Space", [], "arrow.counterclockwise", []) {
            $0.resetAllTabsInSpace()
        },
        entry("expand-folders", "Expand All Folders", ["reveal"], "folder", []) { $0.expandAllFolders() },
        entry("reveal", "Reveal Tab in Sidebar", ["sidebar"], "sidebar.left", []) { $0.revealSelectedTab() },
        entry("settings", "Settings", ["preferences"], "gearshape", [Shortcut.settings]) { _ in SettingsWindow.show() },
        entry("toggle-sidebar", "Toggle Sidebar", ["hide", "show"], "sidebar.left", [Shortcut.toggleSidebar]) {
            $0.toggleSidebar()
        },
        entry("split", "New Split View", ["side by side", "pane"], "rectangle.split.2x1", [Shortcut.newSplitView]) {
            $0.addSplitView()
        },
        entry("updates", "Check for Updates…", ["update"], "arrow.down.circle", []) { $0.checkForUpdates() },
        entry("view-source", "View Source", ["html"], "doc.plaintext", [Shortcut.viewSource]) { $0.viewSource() },
        entry("archive", "View Archive", ["closed"], "archivebox", []) { $0.showArchive() },
        entry("history", "View History", ["visited"], "clock", []) { $0.showHistory() },
    ] + (0..<9).map { index in
        shortcut([Shortcut.space(index)]) { $0.selectSpace(at: index) }
    } + (0..<9).map { index in
        shortcut([Shortcut.tab(index)]) { $0.selectTab(at: index) }
    }

    private static func entry(_ id: String, _ title: String, _ keywords: [String], _ symbol: String,
                              _ keys: [CEFKeyEvent], _ action: @escaping @MainActor (BrowserWindow) -> Void) -> Entry {
        // Arc's command bar writes them out: "Control+Shift+C".
        let label = keys.first.map { $0.label.replacingOccurrences(of: "Ctrl+", with: "Control+") }
        let command = CommandBarCommand(id: id, title: title, keywords: keywords, symbol: symbol, shortcut: label)
        return Entry(command: command, keys: keys, action: action)
    }

    private static func shortcut(_ keys: [CEFKeyEvent],
                                 _ action: @escaping @MainActor (BrowserWindow) -> Void) -> Entry {
        Entry(command: nil, keys: keys, action: action)
    }

    static var commands: [CommandBarCommand] { entries.compactMap(\.command) }

    /// Arc's command to go to each space, by its name.
    static func spaceCommands(_ spaces: [Space]) -> [CommandBarCommand] {
        spaces.map { CommandBarCommand(id: "space-\($0.id.uuidString)", title: $0.title, symbol: "square.stack") }
    }

    static func perform(_ id: String, in window: BrowserWindow) {
        if id.hasPrefix("space-"), let spaceID = Foundation.UUID(uuidString: String(id.dropFirst("space-".count))) {
            window.selectSpace(spaceID)
            return
        }
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
