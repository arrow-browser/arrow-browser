import ArrowCore
import ArrowKit
import Foundation
import UWP
import WindowsFoundation
import WinUI

/// Text over the page, in windowed popups (over the page's browser) that
/// take no input: the address of the link under the pointer at the bottom
/// left, as Arc shows it, and short notices ("Copied URL") at the bottom.
@MainActor
final class PageOverlays {
    private unowned let window: BrowserWindow
    private let status = Popup()
    private let statusText = TextBlock()
    private let statusPanel = Border()
    private let toast = Popup()
    private let toastText = TextBlock()
    private let toastPanel = Border()

    init(window: BrowserWindow) {
        self.window = window
        for (popup, panel, text) in [(status, statusPanel, statusText), (toast, toastPanel, toastText)] {
            text.fontSize = 12
            text.textTrimming = .characterEllipsis
            text.verticalAlignment = .center
            panel.child = text
            panel.cornerRadius = CornerRadius(6)
            panel.padding = Thickness(left: 8, top: 4, right: 8, bottom: 4)
            panel.isHitTestVisible = false
            popup.child = panel
            popup.shouldConstrainToRootBounds = false
            popup.isHitTestVisible = false
        }
        statusPanel.maxWidth = 480
        toastPanel.padding = Thickness(left: 14, top: 8, right: 14, bottom: 8)
        toastPanel.cornerRadius = CornerRadius(16)
        toastText.fontSize = 13
        observe { [weak self] in self?.update() }
    }

    /// Follows the selected tab's status and the window's notice.
    private func update() {
        let palette = window.brushes.palette
        let message = window.selectedTab?.statusMessage
        let notice = window.state.toast?.message
        let isDark = palette.isDark
        for (panel, text) in [(statusPanel, statusText), (toastPanel, toastText)] {
            panel.background = SolidColorBrush(Color(isDark ? RGBColor(hex: 0x2B2B2B) : RGBColor(hex: 0xFFFFFF)))
            panel.borderBrush = SolidColorBrush(Color((isDark ? RGBColor.white : .black).withAlpha(0.1)))
            panel.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
            text.foreground = SolidColorBrush(Color(isDark ? RGBColor.white.withAlpha(0.85) : RGBColor.black.withAlpha(0.75)))
        }
        show(status, text: statusText, message.flatMap { $0.isEmpty ? nil : $0 }, at: .bottomLeft)
        show(toast, text: toastText, notice, at: .bottomCenter)
    }

    private enum Position { case bottomLeft, bottomCenter }

    private func show(_ popup: Popup, text: TextBlock, _ message: String?, at position: Position) {
        guard let message, let root = window.content.xamlRoot else {
            popup.isOpen = false
            return
        }
        text.text = message
        popup.xamlRoot = root
        let frame = window.pageFrame
        guard let panel = popup.child as? FrameworkElement else { return }
        try? panel.measure(Size(width: Float(frame.width), height: 100))
        let size = panel.desiredSize
        switch position {
        case .bottomLeft:
            popup.horizontalOffset = Double(frame.x) + 6
            popup.verticalOffset = Double(frame.y + frame.height - size.height) - 6
        case .bottomCenter:
            popup.horizontalOffset = Double(frame.x) + (Double(frame.width) - Double(size.width)) / 2
            popup.verticalOffset = Double(frame.y + frame.height - size.height) - 24
        }
        popup.isOpen = true
    }

    /// Follows the page's new size.
    func layout() {
        update()
    }
}

/// Arc's Site Control Center (the sliders right of the address): sharing
/// the page, its extensions, Picture-in-Picture, its security and more.
extension BrowserWindow {
    func showSiteControls(under anchor: FrameworkElement) {
        guard let tab = selectedTab else { return }
        let flyout = Flyout()
        flyout.shouldConstrainToRootBounds = false
        flyout.placement = .bottom
        let content = StackPanel()
        content.width = 236
        content.spacing = 10

        let share = Button()
        let shareLabel = StackPanel()
        shareLabel.orientation = .horizontal
        shareLabel.spacing = 8
        shareLabel.children.append(Glyph.view(Glyph.share, size: 13))
        let shareText = TextBlock()
        shareText.text = "Share URL"
        shareLabel.children.append(shareText)
        share.content = shareLabel
        share.horizontalAlignment = .stretch
        share.click.addHandler { [weak self] _, _ in
            try? flyout.hide()
            self?.copyURL()
        }
        content.children.append(share)
        content.children.append(separator())

        let extensionsTitle = TextBlock()
        extensionsTitle.text = "Extensions"
        extensionsTitle.fontSize = 12
        extensionsTitle.opacity = 0.6
        content.children.append(extensionsTitle)
        let extensions = StackPanel()
        extensions.orientation = .horizontal
        extensions.spacing = 4
        for installed in ExtensionManager.shared.extensions where installed.isEnabled {
            let button = Button()
            let initial = TextBlock()
            initial.text = String(installed.name.prefix(1))
            button.content = initial
            button.width = 32
            button.height = 32
            button.padding = Thickness()
            try? ToolTipService.setToolTip(button, installed.name)
            button.click.addHandler { [weak self] _, _ in
                try? flyout.hide()
                guard let popup = ExtensionManager.shared.popupURL(for: installed) else { return }
                self?.openNewTab(popup)
            }
            extensions.children.append(button)
        }
        let add = Button()
        add.content = Glyph.view(Glyph.add, size: 13)
        add.width = 32
        add.height = 32
        add.padding = Thickness()
        add.background = brushes.clear
        add.borderThickness = Thickness()
        try? ToolTipService.setToolTip(add, "Add Extension")
        add.click.addHandler { [weak self] _, _ in
            try? flyout.hide()
            self?.addExtension()
        }
        extensions.children.append(add)
        content.children.append(extensions)
        content.children.append(separator())

        let pip = Grid()
        for width in [GridLength.star, .auto] {
            let column = ColumnDefinition()
            column.width = width
            pip.columnDefinitions.append(column)
        }
        let pipText = TextBlock()
        pipText.text = "Automatic Picture-In-Picture"
        pipText.verticalAlignment = .center
        pip.children.append(pipText)
        let pipToggle = ToggleSwitch()
        pipToggle.isOn = store.settings.automaticPictureInPicture
        pipToggle.onContent = ""
        pipToggle.offContent = ""
        pipToggle.minWidth = 0
        pipToggle.horizontalAlignment = .right
        pipToggle.toggled.addHandler { [weak self] _, _ in self?.store.settings.automaticPictureInPicture = pipToggle.isOn }
        try? Grid.setColumn(pipToggle, 1)
        pip.children.append(pipToggle)
        content.children.append(pip)
        content.children.append(separator())

        let footer = Grid()
        for width in [GridLength.star, .auto] {
            let column = ColumnDefinition()
            column.width = width
            footer.columnDefinitions.append(column)
        }
        let isSecure = tab.url.hasPrefix("https://") || tab.internalPage != nil
        let security = StackPanel()
        security.orientation = .horizontal
        security.spacing = 6
        security.children.append(Glyph.view(Glyph.lock, size: 11))
        let securityText = TextBlock()
        securityText.text = isSecure ? "Secure" : "Not Secure"
        securityText.fontSize = 12
        security.children.append(securityText)
        let securityPill = Border()
        securityPill.child = security
        securityPill.padding = Thickness(left: 10, top: 6, right: 10, bottom: 6)
        securityPill.cornerRadius = CornerRadius(6)
        securityPill.background = SolidColorBrush(Color((brushes.palette.isDark ? RGBColor.white : .black).withAlpha(0.06)))
        securityPill.horizontalAlignment = .left
        footer.children.append(securityPill)
        let more = Button()
        more.content = Glyph.view(Glyph.more, size: 13)
        more.width = 32
        more.height = 32
        more.padding = Thickness()
        more.background = brushes.clear
        more.borderThickness = Thickness()
        try? ToolTipService.setToolTip(more, "More")
        more.click.addHandler { [weak self] _, _ in
            guard let self else { return }
            Menu.show(siteMenu(for: tab), under: more)
        }
        try? Grid.setColumn(more, 1)
        footer.children.append(more)
        content.children.append(footer)

        flyout.content = content
        try? flyout.showAt(anchor)
    }

    private func siteMenu(for tab: WebTab) -> MenuFlyout {
        Menu.flyout([
            Menu.item("Zoom In", shortcut: Shortcut.zoomIn) { tab.zoomIn() },
            Menu.item("Zoom Out", shortcut: Shortcut.zoomOut) { tab.zoomOut() },
            Menu.item("Actual Size", shortcut: Shortcut.actualSize, isEnabled: tab.zoomLevel != 0) { tab.resetZoom() },
            Menu.separator(),
            Menu.item("Clear Cache and Refresh") { tab.reload(ignoringCache: true) },
            Menu.item("Clear Cookies and Refresh") { [weak self] in
                guard let self else { return }
                store.requestContext(for: tab.profileID).deleteCookies(url: tab.url)
                tab.reload(ignoringCache: true)
            },
            Menu.separator(),
            Menu.item("Translate Page") { [weak self] in self?.translatePage() },
            Menu.item("View Source", shortcut: Shortcut.viewSource) { [weak self] in self?.viewSource() },
        ])
    }

    private func separator() -> Border {
        let line = Border()
        line.height = 1
        line.background = SolidColorBrush(Color((brushes.palette.isDark ? RGBColor.white : .black).withAlpha(0.08)))
        return line
    }
}
