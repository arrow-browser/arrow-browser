import ArrowCEF
import ArrowCore
import ArrowKit
import Foundation
import UWP
import WindowsFoundation
import WinUI

/// Peek: a page opened over the current one (links from pinned tabs and
/// favorites to other sites, Shift+click), which closes, becomes a tab or
/// goes in a split view.
extension BrowserWindow {
    func openPeek(_ url: String) {
        guard let source = selectedTab else {
            openNewTab(url)
            return
        }
        closePeek()
        let tab = WebTab(model: Tab(url: url), profileID: source.profileID, store: store, isIncognito: store.isIncognito)
        tab.host = self
        tab.ensureEngine(context: store.requestContext(for: source.profileID))
        state.peek = PeekState(tab: tab)
    }

    func closePeek() {
        guard let peek = state.peek else { return }
        state.peek = nil
        peek.tab.closeEngine()
        focusBrowser()
    }

    /// Moves the peeked page into a tab of today.
    func expandPeek() {
        guard let peek = state.peek else { return }
        state.peek = nil
        adopt(peek.tab)
    }

    /// Makes a page outside the sidebar (Peek, Little Arrow) its first
    /// today tab, and selects it.
    func adopt(_ tab: WebTab) {
        let spaceID = state.selectedSpaceID
        store.update { browser in
            guard let index = browser.spaceIndex(spaceID) else { return }
            var model = Tab(id: tab.id, url: tab.url, title: tab.title)
            model.faviconURL = tab.faviconURL
            browser.spaces[index].today.insert(.tab(model), at: 0)
        }
        store.register(tab)
        tab.host = self
        select(tab.id)
    }

    /// The peeked page next to the current one.
    func splitPeek() {
        guard let peekID = state.peek?.tab.id, let current = state.selectedTabID else {
            expandPeek()
            return
        }
        expandPeek()
        store.update { _ = $0.addToSplit(peekID, with: current) }
        select(peekID)
    }

    /// The buttons beside the peeked page: close, open as a tab, split.
    func peekControls(onClose: @escaping () -> Void, onExpand: @escaping () -> Void,
                      onSplit: @escaping () -> Void) -> StackPanel {
        let controls = StackPanel()
        controls.spacing = 8
        let isDark = brushes.palette.isDark
        controls.requestedTheme = isDark ? .dark : .light
        for (glyph, name, action) in [(Glyph.close, "Close", onClose), (Glyph.newWindow, "Open as Tab", onExpand),
                                      (Glyph.splitView, "Open in Split View", onSplit)] {
            let button = Button()
            button.content = Glyph.view(glyph, size: 12)
            button.width = 32
            button.height = 32
            button.padding = Thickness()
            button.cornerRadius = CornerRadius(16)
            button.background = SolidColorBrush(Color(isDark ? RGBColor(hex: 0x2B2B2B) : RGBColor(hex: 0xFFFFFF)))
            try? AutomationProperties.setName(button, name)
            try? ToolTipService.setToolTip(button, name)
            button.click.addHandler { _, _ in action() }
            controls.children.append(button)
        }
        return controls
    }
}
