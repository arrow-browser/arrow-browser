import AppKit
import ArrowKit

/// Actions searchable from the command bar ("Copy URL", "New Space"…).
@MainActor
enum CommandCatalog {
    private struct Entry {
        let command: CommandBarCommand
        let action: Selector
    }

    private static let entries: [Entry] = [
        entry("copy-url", "Copy URL", ["link", "share"], "link", "⇧⌘C", #selector(BrowserWindowController.copyURL(_:))),
        entry("copy-markdown", "Copy URL as Markdown", ["link"], "text.badge.plus", "⌥⇧⌘C",
              #selector(BrowserWindowController.copyURLAsMarkdown(_:))),
        entry("pin", "Pin/Unpin Tab", ["favorite"], "pin", "⌘D", #selector(BrowserWindowController.togglePinTab(_:))),
        entry("split", "Add Split View", ["side by side", "pane"], "rectangle.split.2x1", "⌃⇧=",
              #selector(BrowserWindowController.addSplitView(_:))),
        entry("toggle-sidebar", "Toggle Sidebar", ["hide", "show"], "sidebar.left", "⌘S",
              #selector(BrowserWindowController.toggleArrowSidebar(_:))),
        entry("new-space", "New Space", ["create", "theme"], "plus.square.on.square", nil,
              #selector(BrowserWindowController.newSpace(_:))),
        entry("edit-theme", "Edit Theme", ["color", "space"], "paintpalette", nil,
              #selector(BrowserWindowController.editSpaceTheme(_:))),
        entry("next-space", "Next Space", [], "arrow.right.square", "⌥⌘→", #selector(BrowserWindowController.nextSpace(_:))),
        entry("previous-space", "Previous Space", [], "arrow.left.square", "⌥⌘←",
              #selector(BrowserWindowController.previousSpace(_:))),
        entry("new-folder", "New Folder", ["group"], "folder.badge.plus", nil, #selector(BrowserWindowController.newFolder(_:))),
        entry("new-note", "New Note", ["write", "text"], "note.text", "⌃⇧N", #selector(BrowserWindowController.newNote(_:))),
        entry("new-easel", "New Easel", ["canvas", "draw"], "scribble", "⌃⇧E", #selector(BrowserWindowController.newEasel(_:))),
        entry("new-document", "New Document", ["doc", "write", "google docs", "notion", "word"], "doc.badge.plus", nil,
              #selector(BrowserWindowController.newDocument(_:))),
        entry("new-boost", "New Boost", ["customize", "css", "style"], "paintbrush.pointed", nil,
              #selector(BrowserWindowController.newBoost(_:))),
        entry("capture", "Capture", ["screenshot"], "camera.viewfinder", "⇧⌘2", #selector(BrowserWindowController.capturePage(_:))),
        entry("translate", "Translate Page", ["language"], "character.bubble", nil,
              #selector(BrowserWindowController.translatePage(_:))),
        entry("zap", "Zap Elements", ["hide", "boost", "remove"], "bolt.fill", nil,
              #selector(BrowserWindowController.zapElements(_:))),
        entry("capture-full", "Capture Full Page", ["screenshot"], "camera.viewfinder", nil,
              #selector(BrowserWindowController.captureFullPage(_:))),
        entry("clear-unpinned", "Clear Unpinned Tabs", ["close", "archive", "today"], "xmark.circle", "⇧⌘K",
              #selector(BrowserWindowController.clearUnpinnedTabs(_:))),
        entry("reopen", "Restore Last Closed Tab", ["undo", "reopen"], "arrow.uturn.backward", "⇧⌘T",
              #selector(BrowserWindowController.restoreLastClosedTab(_:))),
        entry("library", "View Library", ["archive", "history"], "books.vertical", "⇧⌘L",
              #selector(BrowserWindowController.viewLibrary(_:))),
        entry("history", "View History", [], "clock", "⌘Y", #selector(BrowserWindowController.viewHistory(_:))),
        entry("downloads", "View Downloads", ["files"], "arrow.down.circle", "⇧⌘J",
              #selector(BrowserWindowController.viewDownloads(_:))),
        entry("devtools", "Developer Tools", ["inspect", "console", "debug"], "hammer", "⌥⌘I",
              #selector(BrowserWindowController.showDeveloperTools(_:))),
        entry("developer-mode", "Toggle Developer Mode", ["url"], "chevron.left.forwardslash.chevron.right", "⌃⇧D",
              #selector(BrowserWindowController.toggleDeveloperMode(_:))),
        entry("view-source", "View Source", ["html"], "doc.plaintext", "⌥⌘U", #selector(BrowserWindowController.viewPageSource(_:))),
        entry("clear-cache", "Clear Cache and Refresh", [], "arrow.clockwise", nil,
              #selector(BrowserWindowController.clearCacheAndReload(_:))),
        entry("clear-cookies", "Clear Cookies and Refresh", [], "arrow.clockwise", nil,
              #selector(BrowserWindowController.clearCookiesAndReload(_:))),
        entry("print", "Print", [], "printer", "⌘P", #selector(BrowserWindowController.printPage(_:))),
        entry("share", "Share", [], "square.and.arrow.up", nil, #selector(BrowserWindowController.sharePage(_:))),
        entry("save-page", "Save Page As PDF", ["download"], "arrow.down.doc", "⇧⌘S",
              #selector(BrowserWindowController.savePageAs(_:))),
        entry("find", "Find in Page", ["search"], "magnifyingglass", "⌘F", #selector(BrowserWindowController.findInPage(_:))),
        entry("little-arrow", "New Little Arrow Window", ["mini"], "macwindow", "⌥⌘N",
              #selector(AppDelegate.newLittleArrowWindow(_:))),
        entry("incognito", "New Incognito Window", ["private"], "theatermasks", "⇧⌘N",
              #selector(AppDelegate.newIncognitoWindow(_:))),
        entry("settings", "Settings", ["preferences"], "gearshape", "⌘,", #selector(AppDelegate.showSettings(_:))),
    ]

    private static func entry(_ id: String, _ title: String, _ keywords: [String], _ symbol: String, _ shortcut: String?,
                              _ action: Selector) -> Entry {
        Entry(command: CommandBarCommand(id: id, title: title, keywords: keywords, symbol: symbol, shortcut: shortcut),
              action: action)
    }

    static var commands: [CommandBarCommand] { entries.map(\.command) }

    static func perform(_ id: String, in controller: BrowserWindowController) {
        guard let entry = entries.first(where: { $0.command.id == id }) else { return }
        if controller.responds(to: entry.action) {
            controller.perform(entry.action, with: nil)
        } else {
            NSApp.sendAction(entry.action, to: nil, from: nil)
        }
    }
}
