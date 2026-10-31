import ArrowCEF
import ArrowKit
import Foundation
import Testing
import WinSDK
@testable import ArrowWindows

@MainActor
struct CommandCatalogTests {
    @Test func labelsShortcutsAsWindowsDoes() {
        #expect(CEFKeyEvent.key("T", [.control, .shift]).label == "Ctrl+Shift+T")
        #expect(CEFKeyEvent.key(VK_RIGHT, [.control, .alt]).label == "Ctrl+Alt+Right")
        #expect(CEFKeyEvent.key(VK_F5).label == "F5")
        // As Arc's menus write them.
        #expect(Shortcut.settings.label == "Ctrl+,")
        #expect(Shortcut.newSplitView.label == "Ctrl+Shift++")
        #expect(Shortcut.close.label == "Alt+F4")
        #expect(Shortcut.space(0).label == "Alt+1")
        #expect(Shortcut.tab(8).label == "Ctrl+9")
    }

    @Test func offersArcsCommandsWithTheirShortcuts() {
        let shortcuts = Dictionary(uniqueKeysWithValues: CommandCatalog.commands.map { ($0.id, $0.shortcut) })
        // As Arc's command bar writes them.
        #expect(shortcuts["copy-url"] == "Control+Shift+C")
        #expect(shortcuts["toggle-sidebar"] == "Control+S")
        #expect(shortcuts["reopen"] == "Control+Shift+T")
        #expect(shortcuts["close-tab"] == "Control+W")
        #expect(shortcuts["fullscreen"] == "F11")
        // Arc's commands on Windows, not the Mac's.
        let titles = Set(CommandCatalog.commands.map(\.title))
        #expect(titles.isSuperset(of: ["Copy Current URL", "Duplicate Current Tab", "Reload Current Tab",
                                       "Force Reload Current Tab", "Enter Fullscreen", "Rename Current Tab…"]))
        #expect(!titles.contains("Translate Page"))
        #expect(!titles.contains("New Window"))
        // Ctrl+F and Ctrl+N stay shortcuts.
        #expect(CommandCatalog.handles(Shortcut.find))
        #expect(CommandCatalog.handles(Shortcut.newWindow))
    }

    @Test func ranksAsArcOnWindows() {
        let completion = CommandBarRanking.completion(for: "transl")
        #expect(completion?.text == "translate.google.com")
        #expect(completion?.title == "Google Translate")
        let items = [
            CommandBarItem(id: "completion", kind: .open(url: "https://translate.google.com/"), title: "Google Translate",
                           subtitle: "translate.google.com", url: "https://translate.google.com/", symbol: "clock"),
            CommandBarItem(id: "search", kind: .search(query: "transl"), title: "transl", subtitle: "Search Google"),
        ] + (1...6).map { CommandBarItem(id: "suggestion-\($0)", kind: .search(query: "s\($0)"), title: "s\($0)") }
        let rows = CommandBarRanking.arrange(items, "transl")
        #expect(rows.count == CommandBarRanking.maximumRows)
        #expect(rows[0].subtitle == "https://translate.google.com/")
        #expect(rows[0].symbol == nil)
        #expect(rows[1].id == "search")
        // Without a site, a command named after the text comes first.
        let commandRows = CommandBarRanking.arrange([
            CommandBarItem(id: "search", kind: .search(query: "copy"), title: "copy"),
            CommandBarItem(id: "command-copy-url", kind: .command("copy-url"), title: "Copy Current URL"),
        ], "copy")
        #expect(commandRows.map(\.id) == ["command-copy-url", "search"])
        // Other well-known sites follow the search.
        #expect(CommandBarRanking.sites(matching: "new").map(\.name).prefix(2) == ["Google News", "Yahoo News"])
    }

    @Test func leavesOtherKeysToThePage() {
        #expect(CommandCatalog.handles(.key("T", .control)))
        #expect(CommandCatalog.handles(.key(VK_LEFT, .alt)))
        #expect(CommandCatalog.handles(.key(VK_F5)))
        #expect(CommandCatalog.handles(Shortcut.nextTab))
        #expect(CommandCatalog.handles(Shortcut.space(2)))
        // Typing, and the page's own shortcuts.
        #expect(!CommandCatalog.handles(.key("T")))
        #expect(!CommandCatalog.handles(.key("T", .shift)))
        #expect(!CommandCatalog.handles(.key("C", .control)))
        #expect(!CommandCatalog.handles(.key("A", .control)))
        #expect(!CommandCatalog.handles(.key("V", .control)))
    }

    @Test func importsChromiumBookmarks() throws {
        let file = """
        {"roots": {
          "bookmark_bar": {"children": [
            {"type": "url", "name": "Swift", "url": "https://swift.org/"},
            {"type": "url", "name": "Local", "url": "file:///C:/notes.txt"},
            {"type": "folder", "name": "Docs", "children": [
              {"type": "url", "name": "Arrow", "url": "https://github.com/arrow-browser/arrow-browser"}
            ]},
            {"type": "folder", "name": "Empty", "children": []}
          ]},
          "other": {"children": [{"type": "url", "name": "Example", "url": "http://example.com/"}]}
        }}
        """
        let nodes = BrowserWindow.chromiumBookmarks(Data(file.utf8))
        #expect(nodes.count == 3)
        #expect(nodes.allTabs.map(\.url) == ["https://swift.org/", "https://github.com/arrow-browser/arrow-browser",
                                             "http://example.com/"])
        #expect(nodes.allTabs.allSatisfy { $0.pinnedURL == $0.url })
        guard case let .folder(folder) = nodes[1] else {
            Issue.record("the folder is missing")
            return
        }
        #expect(folder.title == "Docs")
        #expect(BrowserWindow.chromiumBookmarks(Data("not json".utf8)).isEmpty)
    }
}
