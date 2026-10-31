import ArrowCEF
import ArrowCore
import ArrowKit
import Foundation
import WinSDK
import WinUI

/// The menus of the toolbar: Arc's app menu under the logo, its Split View
/// Options and its sidebar's Add menu.
extension BrowserWindow {
    func mainMenu() -> MenuFlyout {
        let cloud = store.cloud
        return Menu.flyout([
            Menu.item("Set Arrow as Default Browser", glyph: Glyph.heart) { [weak self] in self?.openDefaultBrowserSettings() },
            Menu.item("Check for Updates", glyph: Glyph.update) { [weak self] in self?.checkForUpdates() },
            Menu.item("Import from Another Browser", glyph: Glyph.importItems) { [weak self] in self?.importFromBrowser() },
            Menu.separator(),
            Menu.item("New Tab", glyph: Glyph.add, shortcut: Shortcut.newTab) { [weak self] in self?.startNewTab() },
            Menu.item("New Window", glyph: Glyph.newWindow, shortcut: Shortcut.newWindow) { ArrowApp.openWindow() },
            Menu.item("New Incognito Window", glyph: Glyph.incognito, shortcut: Shortcut.newIncognitoWindow) {
                ArrowApp.openWindow(incognito: true)
            },
            Menu.separator(),
            Menu.submenu("Spaces", glyph: Glyph.spaces, spacesMenu()),
            Menu.submenu("Tabs", glyph: Glyph.globe, tabsMenu()),
            Menu.separator(),
            Menu.submenu("Extensions", glyph: Glyph.extensions, [
                Menu.item("Add Extension") { [weak self] in self?.addExtension() },
                Menu.item("Manage Extensions") { SettingsWindow.show(section: .extensions) },
            ]),
            Menu.submenu("Developer", glyph: Glyph.developer, [
                Menu.item("View Source", shortcut: Shortcut.viewSource, isEnabled: selectedTab != nil) { [weak self] in
                    self?.viewSource()
                },
                Menu.item("Developer", shortcut: Shortcut.developerTools, isEnabled: selectedTab != nil) { [weak self] in
                    self?.showDeveloperTools()
                },
                Menu.item("Inspect Elements", isEnabled: selectedTab != nil) { [weak self] in self?.inspectElements() },
                Menu.item("JavaScript Console", isEnabled: selectedTab != nil) { [weak self] in
                    self?.showDeveloperTools(panel: "console")
                },
                Menu.item("Network Inspector", isEnabled: selectedTab != nil) { [weak self] in
                    self?.showDeveloperTools(panel: "network")
                },
            ]),
            Menu.separator(),
            Menu.submenu("Help", glyph: Glyph.help, [
                Menu.item("Contact the Team") { [weak self] in self?.contactTheTeam() },
                Menu.item("Visit Help Center") { [weak self] in self?.visitHelpCenter() },
                Menu.separator(),
                Menu.item("Privacy Policy") { [weak self] in self?.showPrivacyPolicy() },
                Menu.item("About Arrow") { [weak self] in self?.showAbout() },
                Menu.separator(),
                Menu.item("Open Task Manager") { [weak self] in self?.showTaskManager() },
                Menu.item("Copy Build Info") { [weak self] in self?.copyBuildInfo() },
            ]),
            Menu.item("Settings", glyph: Glyph.settings, shortcut: Shortcut.settings) { SettingsWindow.show() },
            Menu.item("Print", glyph: Glyph.print, shortcut: Shortcut.print, isEnabled: selectedTab != nil) { [weak self] in
                self?.printPage()
            },
            Menu.separator(),
            Menu.item("Close", glyph: Glyph.close, shortcut: Shortcut.close) { [weak self] in self?.close() },
            cloud.isSignedIn
                ? Menu.item("Sign Out", glyph: Glyph.person) { Task { await cloud.signOut() } }
                : Menu.item("Sign In", glyph: Glyph.person) { SettingsWindow.show() },
        ])
    }

    private func spacesMenu() -> [Menu.Entry] {
        let spaces = store.state.spaces
        return [
            Menu.item("New Space") { [weak self] in self?.newSpace() },
            Menu.item("Rename Space") { [weak self] in
                guard let self else { return }
                rename(state.selectedSpaceID)
            },
            Menu.separator(),
            Menu.item("Next Space", isEnabled: spaces.count > 1) { [weak self] in self?.selectSpace(offset: 1) },
            Menu.item("Previous Space", isEnabled: spaces.count > 1) { [weak self] in self?.selectSpace(offset: -1) },
            Menu.separator(),
        ] + spaces.enumerated().map { index, space in
            Menu.item(space.title, shortcut: index < 9 ? Shortcut.space(index) : nil) { [weak self] in
                self?.selectSpace(space.id)
            }
        }
    }

    private func tabsMenu() -> [Menu.Entry] {
        let tabID = state.selectedTabID
        let isPinned = tabID.map { store.state.isPinned($0) } ?? false
        return [
            Menu.item("Open Command Bar", shortcut: Shortcut.commandBar) { [weak self] in self?.openCommandBar() },
            Menu.item("New Tab", shortcut: Shortcut.newTab) { [weak self] in self?.startNewTab() },
            Menu.item(isPinned ? "Unpin Tab" : "Pin Tab", shortcut: Shortcut.pinTab, isEnabled: tabID != nil) { [weak self] in
                self?.togglePinTab()
            },
            Menu.item("New Folder") { [weak self] in self?.newFolder() },
            Menu.item("New Split View", shortcut: Shortcut.newSplitView) { [weak self] in self?.addSplitView() },
            Menu.separator(),
            Menu.item("Next Tab", shortcut: Shortcut.nextTab) { [weak self] in self?.selectTab(offset: 1) },
            Menu.item("Previous Tab", shortcut: Shortcut.previousTab) { [weak self] in self?.selectTab(offset: -1) },
            Menu.item("Reveal Tab in Sidebar", isEnabled: tabID != nil) { [weak self] in self?.revealSelectedTab() },
            Menu.separator(),
            Menu.item("Reopen Last Closed Tab", shortcut: Shortcut.reopenTab, isEnabled: !store.state.archive.isEmpty) { [weak self] in
                self?.reopenLastClosedTab()
            },
            Menu.item("Clear Today Tabs", isEnabled: selectedSpace?.today.isEmpty == false) { [weak self] in
                self?.clearToday()
            },
            Menu.item("Reset All Tabs in This Space") { [weak self] in self?.resetAllTabsInSpace() },
            Menu.submenu("Archive", archiveMenu()),
        ]
    }

    /// The last archived tabs, which reopen, and the whole archive.
    private func archiveMenu() -> [Menu.Entry] {
        let recent = store.state.archive.prefix(10)
        return recent.map { entry in
            Menu.item(store.title(of: entry.tab)) { [weak self] in self?.restoreArchived(entry.id) }
        } + [
            recent.isEmpty ? nil : Menu.separator(),
            Menu.item("View Archive") { [weak self] in self?.showArchive() },
        ]
    }

    /// Split View Options, in the toolbar: a split of the selected tab and a
    /// new one, on its right, left, top or bottom.
    func splitViewMenu() -> MenuFlyout {
        let canSplit = selectedTab != nil
        return Menu.flyout([
            Menu.title("Split View Controls Menu"),
            Menu.item("Add Right Split", glyph: Glyph.splitRight, isEnabled: canSplit) { [weak self] in
                self?.addSplitView(axis: .horizontal, before: false)
            },
            Menu.item("Add Left Split", glyph: Glyph.splitLeft, isEnabled: canSplit) { [weak self] in
                self?.addSplitView(axis: .horizontal, before: true)
            },
            Menu.item("Add Top Split", glyph: Glyph.splitTop, isEnabled: canSplit) { [weak self] in
                self?.addSplitView(axis: .vertical, before: true)
            },
            Menu.item("Add Bottom Split", glyph: Glyph.splitBottom, isEnabled: canSplit) { [weak self] in
                self?.addSplitView(axis: .vertical, before: false)
            },
        ])
    }

    /// The sidebar's Add menu ("+").
    func addMenu() -> MenuFlyout {
        Menu.flyout([
            Menu.item("New Space", glyph: Glyph.newSpace) { [weak self] in self?.newSpace() },
            Menu.item("New Folder", glyph: Glyph.newFolder) { [weak self] in self?.newFolder() },
            Menu.separator(),
            Menu.item("New Tab", glyph: Glyph.addCircle, shortcut: Shortcut.newTab) { [weak self] in self?.startNewTab() },
        ])
    }
}
