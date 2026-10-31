import ArrowCEF
import Testing
import WinSDK
@testable import ArrowWindows

@MainActor
struct CommandCatalogTests {
    @Test func labelsShortcutsAsWindowsDoes() {
        #expect(CEFKeyEvent.key("T", [.control, .shift]).label == "Ctrl+Shift+T")
        #expect(CEFKeyEvent.key(VK_RIGHT, [.control, .alt]).label == "Ctrl+Alt+Right")
        #expect(CEFKeyEvent.key(VK_F5).label == "F5")
    }

    @Test func offersCommandsWithTheirShortcuts() {
        let shortcuts = Dictionary(uniqueKeysWithValues: CommandCatalog.commands.map { ($0.id, $0.shortcut) })
        #expect(shortcuts["copy-url"] == "Ctrl+Shift+C")
        #expect(shortcuts["toggle-sidebar"] == "Ctrl+S")
        #expect(shortcuts["reopen"] == "Ctrl+Shift+T")
    }

    @Test func leavesOtherKeysToThePage() {
        #expect(CommandCatalog.handles(.key("T", .control)))
        #expect(CommandCatalog.handles(.key(VK_LEFT, .alt)))
        #expect(CommandCatalog.handles(.key(VK_F5)))
        // Typing, and the page's own shortcuts.
        #expect(!CommandCatalog.handles(.key("T")))
        #expect(!CommandCatalog.handles(.key("T", .shift)))
        #expect(!CommandCatalog.handles(.key("C", .control)))
        #expect(!CommandCatalog.handles(.key("A", .control)))
    }
}
