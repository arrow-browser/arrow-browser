import ArrowCEF
import ArrowCore
import ArrowKit
import Foundation
import UWP
import WinAppSDK
import WinSDK
import WindowsFoundation
import WinUI

/// A browser window, laid out as Arc's: the toolbar in the title bar
/// (sidebar toggle, navigation, the address in the middle), the sidebar,
/// and the selected tab's browser in a rounded panel, over the space's
/// gradient, with the command bar over them. Browsers are child windows of
/// the WinUI window's, the shown one kept over the area the layout leaves
/// it.
@MainActor
final class BrowserWindow {
    let store: BrowserStore
    let state: WindowState
    let brushes: ThemeBrushes
    /// Called once the window has closed.
    var onClose: (() -> Void)?
    /// Saves the selection for the next launch (not for smoke tests).
    var savesSelection = true

    private let window: Window
    private let handle: HWND
    private let root = Grid()
    private let toolbar = Grid()
    private let titleRow = RowDefinition()
    private let toolbarLeadingColumn = ColumnDefinition()
    /// Room for the caption buttons (minimize, maximize, close).
    private let captionColumn = ColumnDefinition()
    private let sidebarButton = BrowserWindow.iconButton(Glyph.sidebar, name: "Toggle Sidebar")
    private let navigation = StackPanel()
    private let backButton = BrowserWindow.iconButton(Glyph.back, name: "Back")
    private let forwardButton = BrowserWindow.iconButton(Glyph.forward, name: "Forward")
    private let reloadButton = BrowserWindow.iconButton(Glyph.reload, name: "Reload")
    private let copyLinkButton = BrowserWindow.iconButton(Glyph.link, name: "Copy URL", size: 14)
    /// The address in short form (the host), which edits the address.
    private let addressButton = Button()
    private let addressText = TextBlock()
    private var sidebar: Sidebar!
    private var commandBar: CommandBar?
    private let sidebarColumn = ColumnDefinition()
    /// Where the shown browser goes in the layout.
    private let browserArea = Border()
    private var shownBrowser: CEFBrowser?
    /// Where the toolbar takes clicks in the title bar, in pixels.
    private var nonClientInput: InputNonClientPointerSource?
    private var passthroughRects: [RectInt32] = []
    private var isFullscreen = false
    private var isClosing = false
    private var canClose = false

    init(store: BrowserStore) throws {
        self.store = store
        let snapshot = WindowState.restoredSnapshot()
        let space = snapshot.flatMap { store.state.space($0.selectedSpaceID) } ?? store.state.spaces[0]
        state = WindowState(selectedSpaceID: space.id)
        if let snapshot {
            state.lastSelection = snapshot.lastSelection
            state.isSidebarVisible = snapshot.isSidebarVisible
        }
        brushes = ThemeBrushes(palette: Self.palette(of: space, platform: store.platform))
        window = Window()
        handle = try window.handle()
        window.title = "Arrow"
        let titleBar = window.appWindow.titleBar!
        titleBar.extendsContentIntoTitleBar = true
        nonClientInput = try InputNonClientPointerSource.getForWindowId(window.appWindow.id)
        sidebar = try Sidebar(window: self)
        window.content = try layout()
        applyCaptionColors()
        try window.appWindow.resize(SizeInt32(width: 1280, height: 800))
        try window.activate()
        handleEvents()
        if let tabID = state.lastSelection[space.id] ?? space.pinned.allTabs.first?.id ?? space.today.allTabs.first?.id {
            select(tabID)
        }
        observe { [weak self] in self?.updateTheme() }
        observe { [weak self] in self?.sidebar.update() }
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

    func selectSpace(offset: Int) {
        let spaces = store.state.spaces
        guard let index = spaces.firstIndex(where: { $0.id == state.selectedSpaceID }) else { return }
        selectSpace(spaces[(index + offset + spaces.count) % spaces.count].id)
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

    func closeSelectedTab() {
        guard let tabID = state.selectedTabID else { return }
        closeTab(tabID)
    }

    func reopenLastClosedTab() {
        var restored: (tab: Tab, spaceID: Foundation.UUID)?
        store.update { restored = $0.reopenLastArchived() }
        guard let restored else { return }
        select(restored.tab.id)
    }

    /// Opens the command bar for a new tab (New Tab).
    func startNewTab() {
        showCommandBar(mode: .newTab)
    }

    func copyURL() {
        guard let url = selectedTab?.url, !url.isEmpty else { return }
        store.platform.copyToClipboard(url)
        store.playSound(.event)
    }

    func togglePinTab() {
        guard let tabID = state.selectedTabID else { return }
        store.update { $0.togglePin(tabID) }
        store.playSound(.event)
    }

    /// Archives the space's today tabs (Arc's "Clear").
    func clearToday() {
        var cleared: [Tab] = []
        store.update { cleared = $0.clearToday(in: state.selectedSpaceID) }
        if !cleared.isEmpty { store.playSound(.event) }
        for tab in cleared {
            store.discardRuntime(tab.id)
        }
        if let selected = state.selectedTabID, store.state.tab(selected) == nil {
            state.selectedTabID = nil
        }
    }

    func toggleSidebar() {
        state.isSidebarVisible.toggle()
        if savesSelection { state.saveSnapshot() }
        updateSidebarVisibility()
    }

    // MARK: - Layout

    private func layout() throws -> UIElement {
        brushes.styleButtons(in: root.resources)
        root.background = brushes.background
        root.requestedTheme = brushes.palette.isDark ? .dark : .light
        titleRow.height = .titleBar
        let contentRow = RowDefinition()
        contentRow.height = .star
        root.rowDefinitions.append(titleRow)
        root.rowDefinitions.append(contentRow)
        let contentColumn = ColumnDefinition()
        contentColumn.width = .star
        root.columnDefinitions.append(sidebarColumn)
        root.columnDefinitions.append(contentColumn)

        try layoutToolbar()
        try Grid.setColumnSpan(toolbar, 2)
        root.children.append(toolbar)
        try Grid.setRow(sidebar.element, 1)
        root.children.append(sidebar.element)
        browserArea.background = brushes.content
        try Grid.setRow(browserArea, 1)
        try Grid.setColumn(browserArea, 1)
        root.children.append(browserArea)
        updateSidebarVisibility()
        return root
    }

    /// The toolbar, in the title bar: the sidebar toggle over the sidebar,
    /// navigation over the content, the address in the middle of the window.
    private func layoutToolbar() throws {
        for (column, width) in [(toolbarLeadingColumn, GridLength.auto), (ColumnDefinition(), .auto),
                                (ColumnDefinition(), .star), (captionColumn, .auto)] {
            column.width = width
            toolbar.columnDefinitions.append(column)
        }
        sidebarButton.margin = Thickness(left: 10, top: 0, right: 0, bottom: 0)
        sidebarButton.horizontalAlignment = .left
        toolbar.children.append(sidebarButton)

        navigation.orientation = .horizontal
        navigation.spacing = 8
        navigation.verticalAlignment = .center
        for button in [backButton, forwardButton, reloadButton] {
            navigation.children.append(button)
        }
        try Grid.setColumn(navigation, 1)
        toolbar.children.append(navigation)

        addressText.fontSize = 13
        addressText.textTrimming = .characterEllipsis
        addressButton.content = addressText
        addressButton.height = 28
        addressButton.maxWidth = 400
        addressButton.padding = Thickness(left: 8, top: 0, right: 8, bottom: 0)
        addressButton.cornerRadius = CornerRadius(6)
        try AutomationProperties.setName(addressButton, "Address")
        let address = StackPanel()
        address.orientation = .horizontal
        address.spacing = 2
        address.horizontalAlignment = .center
        address.verticalAlignment = .center
        for element: UIElement in [copyLinkButton, addressButton] {
            address.children.append(element)
        }
        try Grid.setColumnSpan(address, 4)
        toolbar.children.append(address)
    }

    /// Shows or hides the sidebar (Toggle Sidebar, fullscreen pages).
    private func updateSidebarVisibility() {
        let isShown = state.isSidebarVisible && !isFullscreen
        sidebarColumn.width = isShown ? .sidebar : .zero
        sidebar.element.visibility = isShown ? .visible : .collapsed
        toolbarLeadingColumn.width = state.isSidebarVisible ? .sidebar : .auto
        navigation.margin = Thickness(left: state.isSidebarVisible ? 1 : 8, top: 0, right: 0, bottom: 0)
        titleRow.height = isFullscreen ? .zero : .titleBar
        toolbar.visibility = isFullscreen ? .collapsed : .visible
        browserArea.margin = isFullscreen ? Thickness()
            : Thickness(left: isShown ? 0 : 8, top: 0, right: 8, bottom: 8)
        browserArea.cornerRadius = CornerRadius(isFullscreen ? 0 : Self.contentCornerRadius)
    }

    private func updateTheme() {
        let palette = Self.palette(of: store.state.space(state.selectedSpaceID), platform: store.platform)
        guard palette != brushes.palette else { return }
        brushes.apply(palette)
        root.requestedTheme = palette.isDark ? .dark : .light
        applyCaptionColors()
    }

    private static func palette(of space: Space?, platform: any Platform) -> ThemePalette {
        let theme = space?.theme ?? .lavender
        return theme.palette(isDark: theme.isDark(systemIsDark: platform.isDarkAppearance))
    }

    /// The caption buttons over the gradient, in the palette's colors.
    private func applyCaptionColors() {
        guard let titleBar = window.appWindow.titleBar else { return }
        let palette = brushes.palette
        let clear = Color(a: 0, r: 0, g: 0, b: 0)
        titleBar.buttonBackgroundColor = clear
        titleBar.buttonInactiveBackgroundColor = clear
        titleBar.buttonForegroundColor = Color(palette.icon)
        titleBar.buttonInactiveForegroundColor = Color(palette.subtitle)
        titleBar.buttonHoverForegroundColor = Color(palette.title)
        titleBar.buttonHoverBackgroundColor = brushes.captionHover
        titleBar.buttonPressedForegroundColor = Color(palette.title)
        titleBar.buttonPressedBackgroundColor = brushes.captionHover
    }

    /// Makes the toolbar's controls take clicks in the title bar, which
    /// otherwise moves the window, and leaves room for the caption buttons.
    private func updateTitleBar() {
        // The closed window has no title bar left.
        guard !canClose, let scale = toolbar.xamlRoot?.rasterizationScale, scale > 0 else { return }
        let inset = Double(window.appWindow.titleBar.rightInset) / scale
        if captionColumn.width.value != inset {
            captionColumn.width = GridLength(value: inset, gridUnitType: .pixel)
        }
        let controls: [FrameworkElement] = [sidebarButton, backButton, forwardButton, reloadButton, copyLinkButton,
                                            addressButton]
        let rects = isFullscreen ? [] : controls.compactMap { control -> RectInt32? in
            guard control.visibility == .visible, control.actualWidth > 0,
                  let origin = try? control.transformToVisual(nil).transformPoint(Point(x: 0, y: 0)) else { return nil }
            return RectInt32(x: Int32((Double(origin.x) * scale).rounded(.down)),
                             y: Int32((Double(origin.y) * scale).rounded(.down)),
                             width: Int32((control.actualWidth * scale).rounded(.up)),
                             height: Int32((control.actualHeight * scale).rounded(.up)))
        }
        guard rects != passthroughRects else { return }
        passthroughRects = rects
        try? nonClientInput?.setRegionRects(.passthrough, rects)
    }

    private func updateSelectedTab() {
        let tab = selectedTab
        window.title = tab.map { "\($0.displayTitle) - Arrow" } ?? "Arrow"
        backButton.isEnabled = tab?.canGoBack ?? false
        forwardButton.isEnabled = tab?.canGoForward ?? false
        reloadButton.isEnabled = tab != nil
        let url = tab?.url ?? ""
        let address = URLDisplay.short(url)
        addressText.text = address.isEmpty ? "Search or Enter URL..." : address
        addressText.foreground = address.isEmpty ? brushes.subtitle : brushes.title
        addressButton.background = address.isEmpty ? brushes.controlFill : brushes.clear
        copyLinkButton.isEnabled = !url.isEmpty
        show(tab?.engine as? CEFBrowser)
    }

    /// Puts `browser` in the window, in place of the shown one.
    private func show(_ browser: CEFBrowser?) {
        guard browser !== shownBrowser else { return }
        // The page with the keyboard hands it to the next one (a shortcut
        // switched tabs, or closed the page): parked or closed, it would
        // leave the window without it.
        let focus = GetFocus()
        let hadKeyboard = focus == nil ? GetActiveWindow() == handle
            : shownBrowser.map { IsChild($0.hostWindow.handle, focus) } ?? false
        if hadKeyboard { SetFocus(handle) }
        shownBrowser?.hostWindow.detach()
        shownBrowser = browser
        // The panel's own fill would fringe the browser's clipped corners.
        browserArea.background = browser == nil ? brushes.content : brushes.clear
        guard let browser else {
            // Without a page, the address takes the keyboard, for the
            // window's shortcuts (no focus rectangle: not from Tab).
            if hadKeyboard { _ = try? addressButton.focus(.pointer) }
            return
        }
        browser.keyDownHandler = { [weak self] key in
            guard CommandCatalog.handles(key) else { return false }
            // Not from within the browser's key event: the command can close
            // the browser, or take the keyboard from it.
            DispatchQueue.main.async {
                guard let self else { return }
                _ = CommandCatalog.handle(key, in: self)
            }
            return true
        }
        browser.hostWindow.attach(to: handle, frame: browserFrame)
        layoutBrowser()
        // Over WinUI's own child window, which draws the rest of the window.
        SetWindowPos(browser.hostWindow.handle, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE))
        if hadKeyboard { focusBrowser() }
    }

    /// Fits the shown browser to `browserArea`, with its rounded corners.
    private func layoutBrowser() {
        guard let host = shownBrowser?.hostWindow else { return }
        let scale = browserArea.xamlRoot?.rasterizationScale ?? 1
        host.cornerRadius = isFullscreen ? 0 : Int32((Self.contentCornerRadius * scale).rounded())
        host.setFrame(browserFrame)
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
        sidebarButton.click.addHandler { [weak self] _, _ in self?.toggleSidebar() }
        backButton.click.addHandler { [weak self] _, _ in self?.selectedTab?.goBack() }
        forwardButton.click.addHandler { [weak self] _, _ in self?.selectedTab?.goForward() }
        reloadButton.click.addHandler { [weak self] _, _ in self?.selectedTab?.reload() }
        copyLinkButton.click.addHandler { [weak self] _, _ in self?.copyURL() }
        addressButton.click.addHandler { [weak self] _, _ in self?.openCommandBar() }
        // Keys the window's controls leave: the page's browser reports its
        // own.
        root.keyDown.addHandler { [weak self] _, event in
            guard let self, let event else { return }
            event.handled = CommandCatalog.handle(.held(event.key.rawValue), in: self)
        }
        root.loaded.addHandler { [weak self] _, _ in
            guard let self else { return }
            commandBar?.open(over: root)
        }
        root.sizeChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            commandBar?.place(in: root)
        }
        browserArea.sizeChanged.addHandler { [weak self] _, _ in self?.layoutBrowser() }
        toolbar.layoutUpdated.addHandler { [weak self] _, _ in self?.updateTitleBar() }
        window.closed.addHandler { [weak self] _, event in
            // The window closes once every browser has.
            guard let self, !canClose else { return }
            event?.handled = true
            guard !isClosing else { return }
            isClosing = true
            store.closeAllBrowsers {
                // Not from within this handler, which cancels the close:
                // the completion runs at once when no browser is open.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    canClose = true
                    try? window.close()
                    onClose?()
                }
            }
        }
    }

    // MARK: - Command bar

    /// Opens the command bar, in place of an open one.
    func showCommandBar(mode: CommandBarModel.Mode, placement: CommandBar.Placement = .center, text: String = "") {
        commandBar?.close()
        let store = store
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
        let model = CommandBarModel(mode: mode, anchor: .center, initialText: text, sources: sources)
        let bar = CommandBar(model: model, placement: placement, window: self)
        bar.onClose = { [weak self, weak bar] in
            guard let self, commandBar === bar else { return }
            commandBar = nil
        }
        commandBar = bar
        // At launch, once the window's content is loaded.
        if root.xamlRoot != nil { bar.open(over: root) }
    }

    /// Edits the selected tab's address in the command bar (Ctrl+L, a click
    /// on the address), or opens a new tab without one.
    func openCommandBar() {
        guard let tab = selectedTab else {
            showCommandBar(mode: .newTab, placement: .address)
            return
        }
        showCommandBar(mode: .editCurrent(tabID: tab.id), placement: .address,
                       text: tab.internalPage == nil ? tab.url : "")
    }

    func dismissCommandBar() {
        commandBar?.close()
        focusBrowser()
    }

    /// Runs the command bar's `item`.
    func perform(_ item: CommandBarItem, from bar: CommandBar) {
        if case let .siteSearch(site, query) = item.kind, query.isEmpty {
            // "Search YouTube": the bar stays, to search the site.
            bar.searchSite(site)
            return
        }
        bar.close()
        let mode = bar.model.mode
        switch item.kind {
        case let .navigate(url), let .open(url):
            open(url, mode: mode)
        case let .search(query):
            open(store.settings.searchEngine.searchURL(for: query), mode: mode)
        case let .siteSearch(site, query):
            open(site.searchURL(for: query), mode: mode)
        case let .switchToTab(tabID):
            select(tabID)
        case let .command(id):
            CommandCatalog.perform(id, in: self)
        }
        focusBrowser()
    }

    /// Loads `url`, typed in the command bar.
    func open(_ url: String, from bar: CommandBar) {
        bar.close()
        open(url, mode: bar.model.mode)
        focusBrowser()
    }

    private func open(_ url: String, mode: CommandBarModel.Mode) {
        switch mode {
        case let .editCurrent(tabID):
            guard let tab = store.webTab(tabID) else {
                openNewTab(url)
                return
            }
            tab.load(url)
            select(tabID)
        case .newTab, .splitPane:
            // Split views are not part of the Windows app yet.
            openNewTab(url)
        }
    }

    /// Gives the keyboard to the shown browser.
    private func focusBrowser() {
        if let shownBrowser { SetFocus(shownBrowser.hostWindow.handle) }
        shownBrowser?.setFocus(true)
    }

    // MARK: - Style

    private static let contentCornerRadius = 8.0

    private static func iconButton(_ glyph: String, name: String, size: Double = 15) -> Button {
        let button = Button()
        button.content = glyph
        button.fontFamily = Glyph.font
        button.fontSize = size
        button.width = 28
        button.height = 28
        button.padding = Thickness()
        button.cornerRadius = CornerRadius(6)
        button.verticalAlignment = .center
        try? AutomationProperties.setName(button, name)
        try? ToolTipService.setToolTip(button, name)
        return button
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

    func tabDidGainFocus(_ tab: WebTab) {
        // A click in the page closes the command bar.
        commandBar?.close()
    }

    func tab(_ tab: WebTab, didChangeFullscreen fullscreen: Bool) {
        // The page fills the screen: hide the toolbar and the sidebar.
        isFullscreen = fullscreen
        updateSidebarVisibility()
        try? window.appWindow.setPresenter(fullscreen ? .fullScreen : .default)
    }

    func tabRequestsBoostEditor(_ tab: WebTab) {}

    func tabRequestsCapture(_ tab: WebTab) {}

    func isDisplaying(_ tab: WebTab) -> Bool {
        state.selectedTabID == tab.id
    }
}

extension GridLength {
    static let auto = GridLength(value: 1, gridUnitType: .auto)
    static let star = GridLength(value: 1, gridUnitType: .star)
    static let zero = GridLength(value: 0, gridUnitType: .pixel)
    /// Arc's on Windows.
    static let sidebar = GridLength(value: 200, gridUnitType: .pixel)
    static let titleBar = GridLength(value: 32, gridUnitType: .pixel)
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
