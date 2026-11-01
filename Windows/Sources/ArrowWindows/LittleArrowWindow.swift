import ArrowCEF
import ArrowCore
import ArrowKit
import Foundation
import UWP
import WinAppSDK
import WinSDK
import WindowsFoundation
import WinUI

/// Little Arrow (Arc's Little Arc): a small window with one page, for links
/// opened from other apps, which moves into a browser window with "Open in
/// Arrow" or goes away with its window.
@MainActor
final class LittleArrowWindow {
    private static var windows: [LittleArrowWindow] = []

    let store: BrowserStore
    let tab: WebTab
    private let window = Window()
    private let handle: HWND
    private let brushes: ThemeBrushes
    private let root = Grid()
    private let titleText = TextBlock()
    private let openButton = Button()
    private let browserArea = Border()
    private var shownBrowser: CEFBrowser?
    private var keepsTab = false

    static func open(_ url: String, from store: BrowserStore) {
        guard let window = try? LittleArrowWindow(url: url, store: store) else { return }
        windows.append(window)
    }

    private init(url: String, store: BrowserStore) throws {
        self.store = store
        let space = store.state.spaces[0]
        tab = WebTab(model: Tab(url: url), profileID: space.profileID, store: store, isIncognito: store.isIncognito)
        brushes = ThemeBrushes(theme: space.theme, isDark: space.theme.isDark(systemIsDark: store.platform.isDarkAppearance))
        handle = try window.handle()
        window.title = "Little Arrow"
        window.systemBackdrop = MicaBackdrop()
        window.appWindow.titleBar.extendsContentIntoTitleBar = true
        window.content = layout()
        try window.appWindow.resize(SizeInt32(width: 560, height: 760))
        window.setArrowIcon()
        try window.activate()
        handleEvents()
        tab.host = self
        tab.ensureEngine(context: store.requestContext(for: tab.profileID))
        observe { [weak self] in self?.update() }
    }

    private func layout() -> UIElement {
        brushes.styleButtons(in: root.resources)
        root.background = brushes.background
        root.requestedTheme = brushes.palette.isDark ? .dark : .light
        for height in [GridLength(value: 40, gridUnitType: .pixel), .star] {
            let row = RowDefinition()
            row.height = height
            root.rowDefinitions.append(row)
        }
        let bar = Grid()
        bar.padding = Thickness(left: 14, top: 0, right: 140, bottom: 0)
        for width in [GridLength.star, .auto] {
            let column = ColumnDefinition()
            column.width = width
            bar.columnDefinitions.append(column)
        }
        titleText.fontSize = 13
        titleText.fontWeight = FontWeight(weight: 600)
        titleText.foreground = brushes.title
        titleText.verticalAlignment = .center
        titleText.textTrimming = .characterEllipsis
        bar.children.append(titleText)
        openButton.content = "Open in Arrow"
        openButton.height = 28
        openButton.padding = Thickness(left: 10, top: 0, right: 10, bottom: 0)
        openButton.cornerRadius = CornerRadius(6)
        openButton.background = brushes.controlFill
        openButton.verticalAlignment = .center
        try? Grid.setColumn(openButton, 1)
        bar.children.append(openButton)
        root.children.append(bar)
        browserArea.margin = Thickness(left: 6, top: 0, right: 6, bottom: 6)
        browserArea.cornerRadius = CornerRadius(8)
        browserArea.background = brushes.content
        try? Grid.setRow(browserArea, 1)
        root.children.append(browserArea)
        return root
    }

    private func handleEvents() {
        openButton.click.addHandler { [weak self] _, _ in self?.openInArrow() }
        browserArea.sizeChanged.addHandler { [weak self] _, _ in self?.layoutBrowser() }
        window.closed.addHandler { [weak self] _, _ in
            guard let self else { return }
            shownBrowser?.hostWindow.detach()
            if !keepsTab { tab.closeEngine() }
            Self.windows.removeAll { $0 === self }
        }
    }

    private func update() {
        titleText.text = URLDisplay.short(tab.url)
        let browser = tab.engine as? CEFBrowser
        guard browser !== shownBrowser, let browser else { return }
        shownBrowser = browser
        browser.hostWindow.attach(to: handle, frame: .zero)
        SetWindowPos(browser.hostWindow.handle, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE))
        layoutBrowser()
    }

    private func layoutBrowser() {
        guard let host = shownBrowser?.hostWindow, let xamlRoot = browserArea.xamlRoot,
              let origin = try? browserArea.transformToVisual(nil).transformPoint(Point(x: 0, y: 0)) else { return }
        let scale = xamlRoot.rasterizationScale
        host.cornerRadius = Int32((8 * scale).rounded())
        host.setFrame(CGRect(x: Double(origin.x) * scale, y: Double(origin.y) * scale, width: browserArea.actualWidth * scale,
                             height: browserArea.actualHeight * scale).integral)
    }

    /// Moves the page into a today tab of a browser window.
    private func openInArrow() {
        keepsTab = true
        shownBrowser?.hostWindow.detach()
        shownBrowser = nil
        ArrowApp.adopt(tab)
        try? window.close()
    }
}

extension LittleArrowWindow: TabHost {
    func tab(_ tab: WebTab, openURL url: String, inBackground: Bool) {
        ArrowApp.openInFrontWindow(url)
    }

    func tab(_ tab: WebTab, createPopupFor url: String, features: PopupFeatures) -> (any BrowserEngine)? {
        ArrowApp.openInFrontWindow(url)
        return nil
    }

    func tab(_ tab: WebTab, shouldDivertNavigationTo url: String) -> Bool { false }
    func tab(_ tab: WebTab, openInSplitView url: String) { ArrowApp.openInFrontWindow(url) }
    func tab(_ tab: WebTab, openInLittleArrow url: String) { LittleArrowWindow.open(url, from: store) }
    func tab(_ tab: WebTab, openInPeek url: String) { ArrowApp.openInFrontWindow(url) }

    func tabDidRequestClose(_ tab: WebTab) {
        try? window.close()
    }

    func tabDidGainFocus(_ tab: WebTab) {}
    func tab(_ tab: WebTab, didChangeFullscreen fullscreen: Bool) {
        try? window.appWindow.setPresenter(fullscreen ? .fullScreen : .default)
    }

    func tabRequestsBoostEditor(_ tab: WebTab) {}
    func tabRequestsCapture(_ tab: WebTab) {}
    func isDisplaying(_ tab: WebTab) -> Bool { true }
}
