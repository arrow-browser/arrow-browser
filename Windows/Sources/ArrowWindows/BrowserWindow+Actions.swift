import ArrowCEF
import ArrowCore
import ArrowKit
import Foundation
import WinSDK

/// What the window's menus and shortcuts do, as the macOS app's actions.
extension BrowserWindow {
    static let projectURL = "https://github.com/arrow-browser/arrow-browser"

    var selectedSpace: Space? {
        store.state.space(state.selectedSpaceID)
    }

    // MARK: - Tabs

    /// Tabs of the sidebar in visual order: favorites, pinned, today.
    var sidebarTabIDs: [Foundation.UUID] {
        guard let space = selectedSpace else { return [] }
        return (store.state.favorites(for: space.profileID) + space.pinned.allTabs + space.today.allTabs).map(\.id)
    }

    /// Selects the next (1) or previous (-1) tab of the sidebar.
    func selectTab(offset: Int) {
        let tabs = sidebarTabIDs
        guard !tabs.isEmpty else { return }
        let index = state.selectedTabID.flatMap { tabs.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// Selects the sidebar's tab at `index` (Ctrl+1…8), or its last (Ctrl+9).
    func selectTab(at index: Int) {
        let tabs = sidebarTabIDs
        guard !tabs.isEmpty else { return }
        select(index >= 8 ? tabs[tabs.count - 1] : tabs[min(index, tabs.count - 1)])
    }

    func selectSpace(at index: Int) {
        let spaces = store.state.spaces
        guard spaces.indices.contains(index) else { return }
        selectSpace(spaces[index].id)
    }

    func duplicateTab(_ tabID: Foundation.UUID) {
        guard let tab = store.state.tab(tabID) else { return }
        openNewTab(store.webTab(tabID)?.url ?? tab.url)
    }

    func copyLink(of tabID: Foundation.UUID) {
        guard let url = store.webTab(tabID)?.url ?? store.state.tab(tabID)?.url, !url.isEmpty else { return }
        store.platform.copyToClipboard(url)
        store.playSound(.event)
    }

    func toggleMute(_ tabID: Foundation.UUID) {
        guard let tab = store.webTab(tabID) else { return }
        tab.isMuted.toggle()
        store.update { $0.updateTab(tabID) { $0.isMuted = tab.isMuted } }
    }

    /// Archives the today tabs of the space other than `tabID`.
    func archiveOtherTabs(than tabID: Foundation.UUID) {
        guard let space = selectedSpace else { return }
        archive(space.today.allTabs.map(\.id).filter { $0 != tabID })
    }

    /// Archives the today tabs under `tabID` in the sidebar.
    func archiveTabsBelow(_ tabID: Foundation.UUID) {
        guard let space = selectedSpace else { return }
        let today = space.today.allTabs.map(\.id)
        guard let index = today.firstIndex(of: tabID) else { return }
        archive(Array(today[(index + 1)...]))
    }

    private func archive(_ tabIDs: [Foundation.UUID]) {
        for tabID in tabIDs {
            closeTab(tabID)
        }
    }

    /// Pinned tabs navigated away from their address go back to it.
    func resetAllTabsInSpace() {
        guard let space = selectedSpace else { return }
        for tab in space.pinned.allTabs where tab.hasNavigatedAwayFromPinnedURL {
            store.close(tab.id)
        }
    }

    func revealSelectedTab() {
        guard let tabID = state.selectedTabID else { return }
        if !state.isSidebarVisible { toggleSidebar() }
        store.update { $0.expandFolders(containing: tabID) }
        state.revealRequest += 1
    }

    func newFolder() {
        var folder: ArrowKit.Folder?
        store.update { folder = $0.createFolder(in: state.selectedSpaceID) }
        state.renamingNodeID = folder?.id
    }

    /// Open, from the command bar: the folder shown open, its first page
    /// selected.
    func openFolder(_ folderID: Foundation.UUID) {
        if !state.isSidebarVisible { toggleSidebar() }
        var first: Foundation.UUID?
        store.update { browser in
            for index in browser.spaces.indices {
                browser.spaces[index].pinned.updateFolder(folderID) { folder in
                    folder.isExpanded = true
                    first = folder.children.allTabs.first?.id
                }
            }
        }
        if let first { select(first) }
    }

    /// Expand All Folders of the space.
    func expandAllFolders() {
        let spaceID = state.selectedSpaceID
        store.update { browser in
            guard let index = browser.spaces.firstIndex(where: { $0.id == spaceID }) else { return }
            browser.spaces[index].pinned = Self.expanding(browser.spaces[index].pinned)
        }
    }

    private static func expanding(_ nodes: [SidebarNode]) -> [SidebarNode] {
        nodes.map { node in
            guard case var .folder(folder) = node else { return node }
            folder.isExpanded = true
            folder.children = expanding(folder.children)
            return .folder(folder)
        }
    }

    func rename(_ nodeID: Foundation.UUID) {
        if !state.isSidebarVisible { toggleSidebar() }
        state.renamingNodeID = nodeID
    }

    // MARK: - Split View

    /// The split view `tabID` is in.
    func split(containing tabID: Foundation.UUID) -> SplitView? {
        guard let space = store.state.space(state.selectedSpaceID) else { return nil }
        return space.pinned.findSplit(containing: tabID) ?? space.today.findSplit(containing: tabID)
    }

    /// Asks for the page of a new pane beside the selected tab, on its right
    /// by default (Ctrl+Shift++).
    func addSplitView(axis: SplitAxis = .horizontal, before: Bool = false) {
        guard let tabID = state.selectedTabID else {
            showCommandBar(mode: .newTab)
            return
        }
        if let split = split(containing: tabID), split.tabs.count >= SplitView.maximumTabs {
            MessageBeep(UINT(MB_OK))
            return
        }
        splitPlacement = (axis, before)
        showCommandBar(mode: .splitPane(besideTabID: tabID))
    }

    /// Opens `tabID` in a split view beside the selected tab.
    func openInSplitView(_ tabID: Foundation.UUID) {
        guard let selected = state.selectedTabID, selected != tabID else { return }
        store.update { $0.addToSplit(tabID, with: selected) }
        select(tabID)
    }

    func separateSplitView(_ splitID: Foundation.UUID) {
        store.update { $0.dissolveSplit(splitID) }
    }

    // MARK: - Page

    func printPage() {
        selectedTab?.engine?.print()
    }

    func viewSource() {
        guard let tab = selectedTab, tab.engine != nil else { return }
        openNewTab("view-source:\(tab.url)")
    }

    func showDeveloperTools(panel: String? = nil) {
        selectedTab?.engine?.showDevTools(panel: panel)
    }

    func inspectElements() {
        guard let engine = selectedTab?.engine else { return }
        showDeveloperTools(panel: "elements")
        Task { _ = await engine.devToolsMethod("Overlay.setInspectMode", params: ["mode": "searchForNode", "highlightConfig": [:]]) }
    }

    func translatePage() {
        guard let tab = selectedTab else { return }
        translate(tab, to: Self.userLanguage)
    }

    // MARK: - App

    /// Registers Arrow with Windows, then opens its Default apps page, where
    /// the user makes it the default browser.
    func openDefaultBrowserSettings() {
        DefaultBrowser.register()
        openExternal(DefaultBrowser.settingsPage)
    }

    func visitHelpCenter() {
        openNewTab(Self.projectURL + "#readme")
    }

    func showPrivacyPolicy() {
        openNewTab(Self.projectURL + "/blob/main/docs/PRIVACY.md")
    }

    func contactTheTeam() {
        openNewTab(Self.projectURL + "/issues/new")
    }

    func checkForUpdates() {
        openNewTab(Self.projectURL + "/releases")
    }

    func addExtension() {
        openNewTab("https://chromewebstore.google.com")
    }

    func copyBuildInfo() {
        store.platform.copyToClipboard("Arrow \(ArrowApp.version) (Windows), Chromium \(CEFVersion.chromium), CEF \(CEFVersion.cef)")
        store.playSound(.event)
    }

    /// Opens `address` with the app Windows associates with it.
    func openExternal(_ address: String) {
        _ = address.withWideString { address in
            "open".withWideString { verb in ShellExecuteW(nil, verb, address, nil, nil, SW_SHOWNORMAL) }
        }
    }
}
