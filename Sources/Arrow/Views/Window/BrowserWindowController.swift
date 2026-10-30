import AppKit
import ArrowCore
import ArrowKit
import SwiftUI

/// A browser window: sidebar + content, its selection and every window-level
/// command (menus and keyboard shortcuts).
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let store: BrowserStore
    let state: WindowState
    private(set) var popupWindows: [PopupWindowController] = []
    var tabSwitcherMonitor: Any?

    var isIncognito: Bool { store.isIncognito }

    init(store: BrowserStore, spaceID: UUID? = nil, frame: NSRect? = nil, restoring snapshot: WindowState.Snapshot? = nil) {
        self.store = store
        let space = (spaceID ?? snapshot?.selectedSpaceID).flatMap { store.state.space($0) } ?? store.state.spaces[0]
        state = WindowState(selectedSpaceID: space.id)
        if let snapshot {
            state.lastSelection = snapshot.lastSelection
            state.isSidebarVisible = snapshot.isSidebarVisible
        }
        let window = ArrowWindow(contentRect: frame ?? NSRect(x: 0, y: 0, width: 1280, height: 820))
        super.init(window: window)
        window.delegate = self
        if frame == nil { window.center() }
        window.setFrameAutosaveName(store.isIncognito ? "" : "ArrowBrowserWindow")

        let root = BrowserRootView(controller: self)
            .environment(store)
            .environment(state)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        window.contentView = hosting
        window.trafficLightsHidden = !state.isSidebarVisible
        window.layoutTrafficLights()

        if let tabID = state.lastSelection[space.id] ?? space.pinned.allTabs.first?.id ?? space.today.allTabs.first?.id {
            select(tabID, focus: false)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var arrowWindow: ArrowWindow? { window as? ArrowWindow }

    // MARK: - Selection

    var selectedSpace: Space? { store.state.space(state.selectedSpaceID) }

    var selectedTab: WebTab? {
        state.selectedTabID.flatMap { store.webTab($0) }
    }

    /// Split view containing the selected tab, if any.
    var selectedSplit: SplitView? {
        guard let id = state.selectedTabID, let space = selectedSpace else { return nil }
        return space.pinned.findSplit(containing: id) ?? space.today.findSplit(containing: id)
    }

    /// Tabs shown in the content area (several for a split view).
    var displayedTabIDs: [UUID] {
        if let split = selectedSplit { return split.tabs.map(\.id) }
        return state.selectedTabID.map { [$0] } ?? []
    }

    func select(_ tabID: UUID, focus: Bool = true) {
        guard store.state.tab(tabID) != nil else { return }
        let previous = selectedTab
        if let spaceID = store.state.spaceID(containing: tabID), spaceID != state.selectedSpaceID {
            state.selectedSpaceID = spaceID
        }
        state.selectedTabID = tabID
        state.focusedPaneID = tabID
        state.commandBar = nil
        state.noteSelection(tabID, in: state.selectedSpaceID)
        if !isIncognito { state.saveSnapshot() }
        state.isFindBarVisible = false
        store.markActive(tabID)

        guard let tab = store.webTab(tabID) else { return }
        tab.host = self
        tab.lastVisibleAt = Date()
        if tab.internalPage == nil {
            tab.ensureEngine(context: store.requestContext(for: tab.profileID))
        }
        for id in displayedTabIDs where id != tabID {
            store.webTab(id)?.ensureEngine(context: store.requestContext(for: tab.profileID))
            store.webTab(id)?.host = self
        }
        if let previous, previous.id != tabID, !displayedTabIDs.contains(previous.id) {
            previous.lastVisibleAt = Date()
            if store.settings.automaticPictureInPicture { previous.enterPictureInPicture() }
        }
        tab.exitPictureInPicture()
        if focus { focusWebContent() }
        window?.title = tab.displayTitle
    }

    func focusWebContent() {
        guard let engine = selectedTab?.engine as? CEFBrowser else { return }
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            if let view = engine.hostView.subviews.first {
                window.makeFirstResponder(view)
            }
            engine.setFocus(true)
        }
    }

    func selectSpace(_ spaceID: UUID) {
        guard store.state.space(spaceID) != nil, spaceID != state.selectedSpaceID else { return }
        state.selectedSpaceID = spaceID
        state.commandBar = nil
        if !isIncognito { state.saveSnapshot() }
        let space = store.state.space(spaceID)
        if let tabID = state.lastSelection[spaceID], space?.allTabs.contains(where: { $0.id == tabID }) == true {
            select(tabID, focus: false)
        } else if let first = space?.today.allTabs.first ?? space?.pinned.allTabs.first {
            select(first.id, focus: false)
        } else {
            state.selectedTabID = nil
        }
    }

    func selectSpace(offset: Int) {
        let spaces = store.state.spaces
        guard let index = spaces.firstIndex(where: { $0.id == state.selectedSpaceID }), !spaces.isEmpty else { return }
        let next = (index + offset + spaces.count) % spaces.count
        selectSpace(spaces[next].id)
    }

    /// Tabs of the sidebar in visual order (favorites, pinned, today).
    var orderedSidebarTabIDs: [UUID] {
        guard let space = selectedSpace else { return [] }
        let favorites = store.state.favorites(for: space.profileID).map(\.id)
        func flatten(_ nodes: [SidebarNode]) -> [UUID] {
            nodes.flatMap { node -> [UUID] in
                switch node {
                case let .tab(tab): [tab.id]
                case let .folder(folder): folder.isExpanded ? flatten(folder.children) : []
                case let .split(split): split.tabs.first.map { [$0.id] } ?? []
                }
            }
        }
        return favorites + flatten(space.pinned) + flatten(space.today)
    }

    func selectTab(offset: Int) {
        let ids = orderedSidebarTabIDs
        guard !ids.isEmpty else { return }
        let current = state.selectedTabID.flatMap { id in
            ids.firstIndex(of: id) ?? selectedSplit.flatMap { split in ids.firstIndex { split.tabs.first?.id == $0 } }
        } ?? -1
        let next = (current + offset + ids.count) % ids.count
        select(ids[next])
    }

    // MARK: - Opening and closing tabs

    /// Opens `url` in a new today tab of the current space.
    @discardableResult
    func openNewTab(_ url: String, select shouldSelect: Bool = true) -> WebTab? {
        guard let tab = store.openTab(url: url, in: state.selectedSpaceID) else { return nil }
        tab.host = self
        if shouldSelect {
            select(tab.id)
        } else {
            tab.ensureEngine(context: store.requestContext(for: tab.profileID))
        }
        return tab
    }

    /// Loads the result of the command bar.
    func open(_ url: String, mode: CommandBarModel.Mode) {
        switch mode {
        case .newTab:
            openNewTab(url)
        case let .editCurrent(tabID):
            guard let tab = store.webTab(tabID) else {
                openNewTab(url)
                return
            }
            tab.load(url)
            select(tabID)
        case let .splitPane(besideTabID):
            guard let tab = store.openTab(url: url, in: state.selectedSpaceID) else { return }
            store.update { $0.addToSplit(tab.id, with: besideTabID) }
            select(tab.id)
        }
    }

    func closeTab(_ tabID: UUID) {
        let wasSelected = displayedTabIDs.contains(tabID)
        let neighbours = orderedSidebarTabIDs
        let isTodayTab = store.state.location(of: tabID)?.section == .today
        store.close(tabID)
        state.recentTabIDs.removeAll { $0 == tabID }
        guard wasSelected else { return }
        if !isTodayTab {
            // Pinned tabs and favorites stay selected, reset to their address.
            select(tabID, focus: false)
            return
        }
        let candidates = state.recentTabIDs.filter { id in
            store.state.space(state.selectedSpaceID)?.allTabs.contains { $0.id == id } == true
        }
        if let next = candidates.first {
            select(next)
        } else if let index = neighbours.firstIndex(of: tabID) {
            let remaining = neighbours.filter { store.state.tab($0) != nil && $0 != tabID }
            if remaining.isEmpty {
                state.selectedTabID = nil
            } else {
                select(remaining[min(index, remaining.count - 1)])
            }
        } else {
            state.selectedTabID = nil
        }
    }

    func reopenLastClosedTab() {
        var restored: (tab: Tab, spaceID: UUID)?
        store.update { restored = $0.reopenLastArchived() }
        guard let restored else {
            NSSound.beep()
            return
        }
        select(restored.tab.id)
    }

    // MARK: - Command bar

    func showCommandBar(mode: CommandBarModel.Mode, anchor: CommandBarModel.Anchor = .center, text: String = "") {
        let store = store
        let state = state
        let sources = CommandBarModel.Sources(
            openTabs: {
                store.state.spaces.flatMap { space in
                    space.allTabs.map { CommandBarTab(tab: $0, spaceTitle: store.state.spaces.count > 1 ? space.title : nil) }
                } + store.state.favorites.values.flatMap { $0.map { CommandBarTab(tab: $0, spaceTitle: nil) } }
            },
            history: { store.history },
            commands: CommandCatalog.commands,
            engine: { store.settings.searchEngine },
            settings: { store.settings },
            currentTabID: state.selectedTabID
        )
        // Take the keyboard back from Chromium so the command bar field can
        // become focused.
        if let window, let hosting = window.contentView {
            window.makeFirstResponder(hosting)
        }
        state.commandBar = CommandBarModel(mode: mode, anchor: anchor, initialText: text, sources: sources)
    }

    func dismissCommandBar() {
        state.commandBar = nil
        focusWebContent()
    }

    func perform(_ item: CommandBarItem, from model: CommandBarModel) {
        state.commandBar = nil
        let engine = store.settings.searchEngine
        switch item.kind {
        case let .navigate(url), let .open(url):
            open(url, mode: model.mode)
        case let .search(query):
            open(engine.searchURL(for: query), mode: model.mode)
        case let .siteSearch(site, query):
            if query.isEmpty {
                showCommandBar(mode: model.mode, anchor: model.anchor)
                state.commandBar?.activeSiteSearch = site
            } else {
                open(site.searchURL(for: query), mode: model.mode)
            }
        case let .switchToTab(tabID):
            select(tabID)
        case let .command(id):
            CommandCatalog.perform(id, in: self)
        }
    }

    // MARK: - Peek & popups

    func openPeek(_ url: String) {
        guard let source = selectedTab else {
            openNewTab(url)
            return
        }
        let model = Tab(url: url)
        let tab = WebTab(model: model, profileID: source.profileID, store: store, isIncognito: isIncognito)
        tab.host = self
        tab.ensureEngine(context: store.requestContext(for: source.profileID))
        state.peek = PeekState(tab: tab)
    }

    func closePeek() {
        state.peek?.tab.closeEngine()
        state.peek = nil
    }

    /// Moves the peeked page into a real tab.
    func expandPeek() {
        guard let peek = state.peek else { return }
        state.peek = nil
        store.update { state in
            guard let index = state.spaceIndex(self.state.selectedSpaceID) else { return }
            var model = Tab(id: peek.tab.id, url: peek.tab.url, title: peek.tab.title)
            model.faviconURL = peek.tab.faviconURL
            state.spaces[index].today.insert(.tab(model), at: 0)
        }
        store.register(peek.tab)
        select(peek.tab.id)
    }

    /// Peek's third button: the peeked page next to the current one.
    func splitPeek() {
        guard state.peek != nil, let current = state.selectedTabID, let peekID = state.peek?.tab.id else {
            expandPeek()
            return
        }
        expandPeek()
        store.update { _ = $0.addToSplit(peekID, with: current) }
        select(peekID)
    }

    func popupClosed(_ popup: PopupWindowController) {
        popupWindows.removeAll { $0 === popup }
    }

    // MARK: - Sharing

    /// Publishes links on Arrow Cloud and copies the public URL.
    func share(kind: String, title: String, tabs: [Tab]) {
        guard store.cloud.isSignedIn else {
            state.showToast("Sign in to Arrow Cloud in Settings to share", symbol: "icloud.slash")
            return
        }
        Task {
            do {
                let url = try await store.cloud.share(kind: kind, title: title, tabs: tabs)
                copyToPasteboard(url, toast: "Share link copied to clipboard")
            } catch {
                state.showToast(error.localizedDescription, symbol: "exclamationmark.triangle")
            }
        }
    }

    /// Opens an `arrowBrowser://share/<id>` link as a pinned folder.
    func importShare(_ id: String) {
        Task {
            do {
                let share = try await store.cloud.fetchShare(id)
                let links = share.payload?.items ?? []
                guard !links.isEmpty else { return }
                store.update { state in
                    let tabs = links.map { SidebarNode.tab(Tab(url: $0.url, title: $0.title, pinnedURL: $0.url)) }
                    guard let index = state.spaceIndex(self.state.selectedSpaceID) else { return }
                    state.spaces[index].pinned.append(.folder(Folder(title: share.title, children: tabs)))
                }
                state.showToast("Added “\(share.title)”", symbol: "folder.badge.plus")
            } catch {
                state.showToast(error.localizedDescription, symbol: "exclamationmark.triangle")
            }
        }
    }

    // MARK: - Utilities

    func copyToPasteboard(_ string: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        state.showToast(toast, symbol: "link")
    }

    func setSidebarVisible(_ visible: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            state.isSidebarVisible = visible
            state.isSidebarRevealed = false
        }
        arrowWindow?.trafficLightsHidden = !visible
        if !isIncognito { state.saveSnapshot() }
    }

    func revealSidebar(_ revealed: Bool) {
        guard !state.isSidebarVisible else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            state.isSidebarRevealed = revealed
        }
        arrowWindow?.trafficLightsHidden = !revealed
    }

    /// Copies a screenshot of the page: the whole document, or `area` (in
    /// view points) of the visible part.
    func capture(fullPage: Bool = false, area: CGRect? = nil) {
        guard let tab = selectedTab, let engine = tab.engine else { return }
        Task {
            var clip: CGRect?
            let metrics = await engine.devToolsMethod("Page.getLayoutMetrics")
            if fullPage, let size = metrics?["cssContentSize"] as? [String: Any],
               let width = size["width"] as? Double, let height = size["height"] as? Double {
                clip = CGRect(x: 0, y: 0, width: width, height: min(height, 16384))
            } else if let area {
                // View points → CSS pixels of the document (zoom and scroll).
                let viewport = metrics?["cssVisualViewport"] as? [String: Any]
                let scale = pow(1.2, tab.zoomLevel)
                let pageX = viewport?["pageX"] as? Double ?? 0
                let pageY = viewport?["pageY"] as? Double ?? 0
                clip = CGRect(x: pageX + area.minX / scale, y: pageY + area.minY / scale,
                              width: area.width / scale, height: area.height / scale)
            }
            guard let data = await engine.captureScreenshot(clip: clip), let image = NSImage(data: data) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            if !isIncognito { MediaLibrary.saveCapture(image, from: tab, in: store) }
            SoundEffects.play(.capture, store: store)
            state.showToast("Capture copied to clipboard", symbol: "camera.viewfinder")
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        closePeek()
        for popup in popupWindows { popup.close() }
        for id in displayedTabIDs { store.webTab(id)?.lastVisibleAt = Date() }
        (NSApp.delegate as? AppDelegate)?.windowControllerDidClose(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.lastActiveBrowserWindow = self
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        for id in displayedTabIDs { store.webTab(id)?.engine?.notifyMoveOrResizeStarted() }
    }

    func windowWillMove(_ notification: Notification) {
        for id in displayedTabIDs { store.webTab(id)?.engine?.notifyMoveOrResizeStarted() }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        arrowWindow?.layoutTrafficLights()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if state.isFullscreenContent {
            state.isFullscreenContent = false
            selectedTab?.engine?.exitFullscreen()
        }
    }
}

// MARK: - TabHost

extension BrowserWindowController: TabHost {
    func tab(_ tab: WebTab, openURL url: String, inBackground: Bool) {
        openNewTab(url, select: !inBackground)
    }

    func tab(_ tab: WebTab, createPopupFor url: String, features: PopupFeatures) -> (any BrowserEngine)? {
        let context = (tab.engine as? CEFBrowser)?.requestContext ?? store.cefContext(for: tab.profileID)
        if features.isPopup, let frame = features.frame {
            // Sized window.open() popups (sign-in flows…) get their own window.
            let popup = PopupWindowController(context: context, frame: frame, store: store, parent: self)
            popupWindows.append(popup)
            popup.showWindow(nil)
            return popup.engine
        }
        guard let model = store.openTab(url: url, in: state.selectedSpaceID) else { return nil }
        let engine = CEFBrowser(requestContext: context)
        model.adopt(engine)
        model.host = self
        select(model.id, focus: true)
        return engine
    }

    func tab(_ tab: WebTab, shouldDivertNavigationTo url: String) -> Bool {
        guard store.settings.peekEnabled, state.peek?.tab !== tab,
              store.state.isPinned(tab.id) || store.state.isFavorite(tab.id),
              url.hasPrefix("http"), !URLDisplay.isSameSite(url, tab.url) else { return false }
        openPeek(url)
        return true
    }

    func tab(_ tab: WebTab, openInSplitView url: String) {
        guard let new = store.openTab(url: url, in: state.selectedSpaceID) else { return }
        store.update { $0.addToSplit(new.id, with: tab.id) }
        select(new.id)
    }

    func tab(_ tab: WebTab, openInLittleArrow url: String) {
        (NSApp.delegate as? AppDelegate)?.openLittleArrow(url: url)
    }

    func tab(_ tab: WebTab, openInPeek url: String) {
        openPeek(url)
    }

    func tabDidRequestClose(_ tab: WebTab) {
        if state.peek?.tab === tab {
            closePeek()
        } else {
            closeTab(tab.id)
        }
    }

    func tabDidGainFocus(_ tab: WebTab) {
        if state.commandBar != nil { state.commandBar = nil }
        if state.focusedPaneID != tab.id, displayedTabIDs.contains(tab.id) {
            state.focusedPaneID = tab.id
            state.selectedTabID = tab.id
        }
    }

    func tab(_ tab: WebTab, didChangeFullscreen fullscreen: Bool) {
        state.isFullscreenContent = fullscreen
        guard let window else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if fullscreen != isFullScreen { window.toggleFullScreen(nil) }
    }

    func tabRequestsBoostEditor(_ tab: WebTab) {
        let existing = store.boosts(for: tab.url).first
        state.sheet = .boostEditor(boostID: existing?.id, url: tab.url)
    }

    func tabRequestsCapture(_ tab: WebTab) {
        capture()
    }

    func isDisplaying(_ tab: WebTab) -> Bool {
        displayedTabIDs.contains(tab.id) && window?.isVisible == true
    }
}
