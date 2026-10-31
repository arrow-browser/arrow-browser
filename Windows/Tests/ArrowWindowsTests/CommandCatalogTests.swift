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

    @Test func offersCommandsWithTheirShortcuts() {
        let shortcuts = Dictionary(uniqueKeysWithValues: CommandCatalog.commands.map { ($0.id, $0.shortcut) })
        #expect(shortcuts["copy-url"] == "Ctrl+Shift+C")
        #expect(shortcuts["toggle-sidebar"] == "Ctrl+S")
        #expect(shortcuts["reopen"] == "Ctrl+Shift+T")
        #expect(shortcuts["find"] == "Ctrl+F")
        #expect(shortcuts["new-window"] == "Ctrl+N")
        #expect(shortcuts["incognito"] == "Ctrl+Shift+N")
        #expect(shortcuts["new-space"] != nil)
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
