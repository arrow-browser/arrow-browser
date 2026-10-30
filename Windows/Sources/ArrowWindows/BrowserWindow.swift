import ArrowCEF
import ArrowCore
import ArrowKit
import Foundation
import UWP
import WinAppSDK
import WinSDK
import WindowsFoundation
import WinUI

/// A browser window: the sidebar (navigation, address field, the space's
/// tabs, the space switcher) next to the selected tab's browser. Browsers
/// are child windows of the WinUI window's, the shown one kept over the area
/// the layout leaves it.
@MainActor
final class BrowserWindow {
    let store: BrowserStore
    let state: WindowState
    /// Called once the window has closed.
    var onClose: (() -> Void)?
    /// Saves the selection for the next launch (not for smoke tests).
    var savesSelection = true

    private let window: Window
    private let handle: HWND
    private let backButton = BrowserWindow.iconButton(glyph: "\u{E72B}", name: "Back")
    private let forwardButton = BrowserWindow.iconButton(glyph: "\u{E72A}", name: "Forward")
    private let reloadButton = BrowserWindow.iconButton(glyph: "\u{E72C}", name: "Reload")
    private let addressField = TextBox()
    private let spaceTitle = TextBlock()
    private let tabList = StackPanel()
    private let newTabButton = Button()
    private let spaceBar = StackPanel()
    private let sidebarColumn = ColumnDefinition()
    /// Where the shown browser goes in the layout.
    private let browserArea = Border()
    private var shownBrowser: CEFBrowser?
    /// Enter in the address field opens a new tab ("New Tab"), instead of
    /// loading the selected one.
    private var opensNewTab = false
    private var isEditingAddress = false
    private var isClosing = false
    private var canClose = false

    init(store: BrowserStore) throws {
        self.store = store
        let snapshot = WindowState.restoredSnapshot()
        let space = snapshot.flatMap { store.state.space($0.selectedSpaceID) } ?? store.state.spaces[0]
        state = WindowState(selectedSpaceID: space.id)
        if let snapshot { state.lastSelection = snapshot.lastSelection }
        window = Window()
        handle = try window.handle()
        window.title = "Arrow"
        window.content = try layout()
        try window.appWindow.resize(SizeInt32(width: 1280, height: 800))
        try window.activate()
        handleEvents()
        if let tabID = state.lastSelection[space.id] ?? space.pinned.allTabs.first?.id ?? space.today.allTabs.first?.id {
            select(tabID)
        }
        observe { [weak self] in self?.updateSidebar() }
        observe { [weak self] in self?.updateSelectedTab() }
    }

    var selectedTab: WebTab? {
        state.selectedTabID.flatMap { store.webTab($0) }
    }

    /// Whether the shown browser is a child of this window (smoke test).
    var isBrowserHosted: Bool {
        guard let shownBrowser else { return false }
        return GetAncestor(shownBrowser.hostWindow.handle, UINT(GA_ROOT)) == handle
    }

    /// Closes every browser, then the window.
    func close() {
        try? window.close()
    }

    // MARK: - Selection

    func select(_ tabID: Foundation.UUID) {
        guard store.state.tab(tabID) != nil else { return }
        if let spaceID = store.state.spaceID(containing: tabID), spaceID != state.selectedSpaceID {
            state.selectedSpaceID = spaceID
        }
        state.selectedTabID = tabID
        state.noteSelection(tabID, in: state.selectedSpaceID)
        if savesSelection { state.saveSnapshot() }
        store.markActive(tabID)
        guard let tab = store.webTab(tabID) else { return }
        tab.host = self
        tab.lastVisibleAt = Date()
        tab.ensureEngine(context: store.requestContext(for: tab.profileID))
    }

    func selectSpace(_ spaceID: Foundation.UUID) {
        guard let space = store.state.space(spaceID), spaceID != state.selectedSpaceID else { return }
        state.selectedSpaceID = spaceID
        if savesSelection { state.saveSnapshot() }
        if let tabID = state.lastSelection[spaceID], space.allTabs.contains(where: { $0.id == tabID }) {
            select(tabID)
        } else if let first = space.today.allTabs.first ?? space.pinned.allTabs.first {
            select(first.id)
        } else {
            state.selectedTabID = nil
        }
    }

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

    func closeTab(_ tabID: Foundation.UUID) {
        let wasSelected = state.selectedTabID == tabID
        let neighbours = sidebarTabIDs
        let isTodayTab = store.state.location(of: tabID)?.section == .today
        store.close(tabID)
        state.recentTabIDs.removeAll { $0 == tabID }
        guard wasSelected else { return }
        if !isTodayTab {
            // Pinned tabs and favorites stay selected, reset to their address.
            select(tabID)
            return
        }
        let space = store.state.space(state.selectedSpaceID)
        let remaining = neighbours.filter { $0 != tabID && store.state.tab($0) != nil }
        if let recent = state.recentTabIDs.first(where: { id in space?.allTabs.contains { $0.id == id } == true }) {
            select(recent)
        } else if let index = neighbours.firstIndex(of: tabID), !remaining.isEmpty {
            select(remaining[min(index, remaining.count - 1)])
        } else {
            state.selectedTabID = nil
        }
    }

    /// Tabs of the sidebar in visual order: favorites, pinned, today.
    private var sidebarTabIDs: [Foundation.UUID] {
        guard let space = store.state.space(state.selectedSpaceID) else { return [] }
        return (store.state.favorites(for: space.profileID) + space.pinned.allTabs + space.today.allTabs).map(\.id)
    }

    // MARK: - Layout

    private func layout() throws -> UIElement {
        let navigation = StackPanel()
        navigation.orientation = .horizontal
        navigation.spacing = 4
        for button in [backButton, forwardButton, reloadButton] {
            navigation.children.append(button)
        }
        addressField.placeholderText = "Search or enter address"
        spaceTitle.fontSize = 16
        spaceTitle.margin = Thickness(left: 8, top: 4, right: 8, bottom: 0)
        tabList.spacing = 2
        newTabButton.content = "+  New Tab"
        Self.styleAsRow(newTabButton, selected: false)
        let tabScroller = ScrollViewer()
        tabScroller.content = tabList
        spaceBar.orientation = .horizontal
        spaceBar.spacing = 4
        spaceBar.horizontalAlignment = .center

        let sidebar = Grid()
        sidebar.padding = Thickness(left: 8, top: 8, right: 8, bottom: 8)
        sidebar.rowSpacing = 8
        let rows: [(FrameworkElement, GridLength)] = [
            (navigation, .auto), (addressField, .auto), (spaceTitle, .auto), (tabScroller, .star), (spaceBar, .auto),
        ]
        for (index, (element, height)) in rows.enumerated() {
            let definition = RowDefinition()
            definition.height = height
            sidebar.rowDefinitions.append(definition)
            try Grid.setRow(element, Int32(index))
            sidebar.children.append(element)
        }

        let root = Grid()
        sidebarColumn.width = .sidebar
        let contentColumn = ColumnDefinition()
        contentColumn.width = .star
        root.columnDefinitions.append(sidebarColumn)
        root.columnDefinitions.append(contentColumn)
        try Grid.setColumn(browserArea, 1)
        root.children.append(sidebar)
        root.children.append(browserArea)
        return root
    }

    private func updateSidebar() {
        guard let space = store.state.space(state.selectedSpaceID) else { return }
        spaceTitle.text = space.title
        tabList.children.clear()
        let favorites = store.state.favorites(for: space.profileID)
        for tab in favorites + space.pinned.allTabs {
            tabList.children.append(row(for: tab, closable: false))
        }
        if !favorites.isEmpty || !space.pinned.isEmpty {
            let separator = Border()
            separator.height = 1
            separator.margin = Thickness(left: 8, top: 6, right: 8, bottom: 6)
            separator.background = Self.separatorBrush
            tabList.children.append(separator)
        }
        tabList.children.append(newTabButton)
        for tab in space.today.allTabs {
            tabList.children.append(row(for: tab, closable: true))
        }

        spaceBar.children.clear()
        for other in store.state.spaces {
            let button = Button()
            switch other.icon {
            case let .emoji(emoji): button.content = emoji
            default: button.content = String(other.title.prefix(1)).uppercased()
            }
            button.background = other.id == space.id ? Self.selectedBrush : Self.clearBrush
            button.borderThickness = Thickness()
            try? AutomationProperties.setName(button, other.title)
            let id = other.id
            button.click.addHandler { [weak self] _, _ in self?.selectSpace(id) }
            spaceBar.children.append(button)
        }
    }

    private func row(for tab: Tab, closable: Bool) -> Button {
        let title = TextBlock()
        title.text = store.tabs[tab.id]?.displayTitle ?? store.title(of: tab)
        title.textTrimming = .characterEllipsis
        title.verticalAlignment = .center
        let content = Grid()
        let titleColumn = ColumnDefinition()
        titleColumn.width = .star
        content.columnDefinitions.append(titleColumn)
        content.children.append(title)

        let row = Button()
        row.content = content
        try? AutomationProperties.setName(row, title.text)
        Self.styleAsRow(row, selected: tab.id == state.selectedTabID)
        let id = tab.id
        row.click.addHandler { [weak self] _, _ in self?.select(id) }
        if closable {
            let closeButton = Self.iconButton(glyph: "\u{E711}", name: "Close Tab")
            closeButton.fontSize = 10
            closeButton.padding = Thickness(left: 6, top: 4, right: 6, bottom: 4)
            closeButton.background = Self.clearBrush
            closeButton.borderThickness = Thickness()
            let closeColumn = ColumnDefinition()
            closeColumn.width = .auto
            content.columnDefinitions.append(closeColumn)
            try? Grid.setColumn(closeButton, 1)
            content.children.append(closeButton)
            closeButton.click.addHandler { [weak self] _, _ in self?.closeTab(id) }
        }
        return row
    }

    private func updateSelectedTab() {
        let tab = selectedTab
        window.title = tab.map { "\($0.displayTitle) - Arrow" } ?? "Arrow"
        backButton.isEnabled = tab?.canGoBack ?? false
        forwardButton.isEnabled = tab?.canGoForward ?? false
        reloadButton.isEnabled = tab != nil
        let url = tab?.url ?? ""
        if !isEditingAddress { addressField.text = url }
        show(tab?.engine as? CEFBrowser)
    }

    /// Puts `browser` in the window, in place of the shown one.
    private func show(_ browser: CEFBrowser?) {
        guard browser !== shownBrowser else { return }
        shownBrowser?.hostWindow.detach()
        shownBrowser = browser
        guard let browser else { return }
        browser.hostWindow.attach(to: handle, frame: browserFrame)
        // Over WinUI's own child window, which draws the sidebar.
        SetWindowPos(browser.hostWindow.handle, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE))
    }

    /// `browserArea` in physical pixels.
    private var browserFrame: CGRect {
        guard let root = browserArea.xamlRoot,
              let origin = try? browserArea.transformToVisual(nil).transformPoint(Point(x: 0, y: 0)) else { return .zero }
        let scale = root.rasterizationScale
        return CGRect(x: Double(origin.x) * scale, y: Double(origin.y) * scale, width: browserArea.actualWidth * scale,
                      height: browserArea.actualHeight * scale).integral
    }

    // MARK: - Events

    private func handleEvents() {
        backButton.click.addHandler { [weak self] _, _ in self?.selectedTab?.goBack() }
        forwardButton.click.addHandler { [weak self] _, _ in self?.selectedTab?.goForward() }
        reloadButton.click.addHandler { [weak self] _, _ in self?.selectedTab?.reload() }
        newTabButton.click.addHandler { [weak self] _, _ in
            guard let self else { return }
            opensNewTab = true
            addressField.text = ""
            _ = try? addressField.focus(.programmatic)
        }
        addressField.gotFocus.addHandler { [weak self] _, _ in self?.isEditingAddress = true }
        addressField.lostFocus.addHandler { [weak self] _, _ in
            guard let self else { return }
            isEditingAddress = false
            opensNewTab = false
            addressField.text = selectedTab?.url ?? ""
        }
        addressField.keyDown.addHandler { [weak self] _, event in
            guard let self, let event else { return }
            switch event.key {
            case .enter:
                event.handled = true
                let address = URLInput.resolve(addressField.text, engine: store.settings.searchEngine)
                if opensNewTab || selectedTab == nil {
                    openNewTab(address)
                } else {
                    selectedTab?.load(address)
                }
                opensNewTab = false
                focusBrowser()
            case .escape:
                event.handled = true
                focusBrowser()
            default:
                break
            }
        }
        browserArea.sizeChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            shownBrowser?.hostWindow.setFrame(browserFrame)
        }
        window.closed.addHandler { [weak self] _, event in
            // The window closes once every browser has.
            guard let self, !canClose else { return }
            event?.handled = true
            guard !isClosing else { return }
            isClosing = true
            store.closeAllBrowsers { [weak self] in
                guard let self else { return }
                canClose = true
                try? window.close()
                onClose?()
            }
        }
    }

    /// Gives the keyboard to the shown browser.
    private func focusBrowser() {
        isEditingAddress = false
        addressField.text = selectedTab?.url ?? ""
        if let shownBrowser { SetFocus(shownBrowser.hostWindow.handle) }
        shownBrowser?.setFocus(true)
    }

    // MARK: - Style

    private static let clearBrush = SolidColorBrush(Color(a: 0, r: 0, g: 0, b: 0))
    private static let selectedBrush = SolidColorBrush(Color(a: 0x30, r: 0x80, g: 0x80, b: 0x80))
    private static let separatorBrush = SolidColorBrush(Color(a: 0x40, r: 0x80, g: 0x80, b: 0x80))

    private static func iconButton(glyph: String, name: String) -> Button {
        let button = Button()
        button.content = glyph
        button.fontFamily = FontFamily("Segoe Fluent Icons")
        try? AutomationProperties.setName(button, name)
        return button
    }

    private static func styleAsRow(_ button: Button, selected: Bool) {
        button.horizontalAlignment = .stretch
        button.horizontalContentAlignment = .stretch
        button.background = selected ? selectedBrush : clearBrush
        button.borderThickness = Thickness()
    }
}

// MARK: - TabHost

extension BrowserWindow: TabHost {
    func tab(_ tab: WebTab, openURL url: String, inBackground: Bool) {
        openNewTab(url, select: !inBackground)
    }

    func tab(_ tab: WebTab, createPopupFor url: String, features: PopupFeatures) -> (any BrowserEngine)? {
        // Popups open as tabs until they get windows of their own.
        guard let context = (tab.engine as? CEFBrowser)?.requestContext
            ?? store.requestContext(for: tab.profileID) as? CEFRequestContext,
            let popup = store.openTab(url: url, in: state.selectedSpaceID) else { return nil }
        let engine = CEFBrowser(requestContext: context)
        popup.adopt(engine)
        popup.host = self
        select(popup.id)
        return engine
    }

    func tab(_ tab: WebTab, shouldDivertNavigationTo url: String) -> Bool { false }

    // Split view, Little Arrow and Peek are not part of the Windows app yet:
    // their links open as tabs.
    func tab(_ tab: WebTab, openInSplitView url: String) { openNewTab(url) }
    func tab(_ tab: WebTab, openInLittleArrow url: String) { openNewTab(url) }
    func tab(_ tab: WebTab, openInPeek url: String) { openNewTab(url) }

    func tabDidRequestClose(_ tab: WebTab) {
        closeTab(tab.id)
    }

    func tabDidGainFocus(_ tab: WebTab) {}

    func tab(_ tab: WebTab, didChangeFullscreen fullscreen: Bool) {
        // The page fills the screen: hide the sidebar.
        sidebarColumn.width = fullscreen ? GridLength(value: 0, gridUnitType: .pixel) : .sidebar
        try? window.appWindow.setPresenter(fullscreen ? .fullScreen : .default)
    }

    func tabRequestsBoostEditor(_ tab: WebTab) {}

    func tabRequestsCapture(_ tab: WebTab) {}

    func isDisplaying(_ tab: WebTab) -> Bool {
        state.selectedTabID == tab.id
    }
}

private extension GridLength {
    static let auto = GridLength(value: 1, gridUnitType: .auto)
    static let star = GridLength(value: 1, gridUnitType: .star)
    static let sidebar = GridLength(value: 280, gridUnitType: .pixel)
}

extension Window {
    /// The window's Win32 handle, as Microsoft.UI.Interop.h's
    /// GetWindowFromWindowId gets it.
    func handle() throws(WindowsAppRuntime.Failure) -> HWND {
        typealias GetWindowFromWindowId = @convention(c) (UInt64, UnsafeMutablePointer<HWND?>) -> HRESULT
        guard let module = "Microsoft.Internal.FrameworkUdk.dll".withWideString({ LoadLibraryW($0) }),
              let address = GetProcAddress(module, "Windowing_GetWindowFromWindowId") else {
            throw WindowsAppRuntime.Failure(description: "Windowing_GetWindowFromWindowId is missing")
        }
        var handle: HWND?
        let result = unsafeBitCast(address, to: GetWindowFromWindowId.self)(appWindow.id.value, &handle)
        guard result >= 0, let handle else {
            throw WindowsAppRuntime.Failure(description: "no window for \(appWindow.id.value)")
        }
        return handle
    }
}
