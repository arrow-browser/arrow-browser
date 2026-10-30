import ArrowCore
import ArrowKit
import Foundation
import UWP
import WindowsFoundation
import WinUI

/// The sidebar, laid out as Arc's: the favorites grid, the space's name,
/// its pinned tabs and folders, the divider with "Clear", New Tab and
/// today's tabs, and the space switcher at the bottom.
@MainActor
final class Sidebar {
    let element = Grid()
    private unowned let window: BrowserWindow
    private let favorites = Grid()
    private let list = StackPanel()
    private let spaceBar = StackPanel()

    init(window: BrowserWindow) throws {
        self.window = window
        element.padding = Thickness(left: 8, top: 1, right: 8, bottom: 0)
        favorites.columnSpacing = 8
        favorites.rowSpacing = 8
        list.spacing = 2
        let scroller = ScrollViewer()
        scroller.content = list
        spaceBar.orientation = .horizontal
        spaceBar.spacing = 2
        spaceBar.horizontalAlignment = .center
        spaceBar.margin = Thickness(left: 0, top: 6, right: 0, bottom: 11)
        let rows: [(FrameworkElement, GridLength)] = [(favorites, .auto), (scroller, .star), (spaceBar, .auto)]
        for (index, (child, height)) in rows.enumerated() {
            let definition = RowDefinition()
            definition.height = height
            element.rowDefinitions.append(definition)
            try Grid.setRow(child, Int32(index))
            element.children.append(child)
        }
    }

    private var store: BrowserStore { window.store }
    private var brushes: ThemeBrushes { window.brushes }

    func update() {
        guard let space = store.state.space(window.state.selectedSpaceID) else { return }
        updateFavorites(store.state.favorites(for: space.profileID))
        list.children.clear()
        list.children.append(header(for: space))
        for node in space.pinned {
            appendRows(for: node, depth: 0, closable: false)
        }
        list.children.append(divider(for: space))
        list.children.append(newTabRow())
        for node in space.today {
            appendRows(for: node, depth: 0, closable: true)
        }
        updateSpaceBar(selected: space.id)
    }

    // MARK: - Favorites

    private func updateFavorites(_ tabs: [Tab]) {
        favorites.children.clear()
        favorites.columnDefinitions.clear()
        favorites.rowDefinitions.clear()
        favorites.margin = Thickness(left: 0, top: 0, right: 0, bottom: tabs.isEmpty ? 0 : 8)
        guard !tabs.isEmpty else { return }
        let columns = tabs.count <= 4 ? tabs.count : (tabs.count <= 6 ? 3 : 4)
        for _ in 0..<columns {
            let column = ColumnDefinition()
            column.width = .star
            favorites.columnDefinitions.append(column)
        }
        for _ in 0..<(tabs.count + columns - 1) / columns {
            let row = RowDefinition()
            row.height = .auto
            favorites.rowDefinitions.append(row)
        }
        for (index, tab) in tabs.enumerated() {
            let isSelected = tab.id == window.state.selectedTabID
            let tile = Button()
            tile.content = favicon(for: tab)
            tile.height = 45
            tile.horizontalAlignment = .stretch
            tile.cornerRadius = CornerRadius(8)
            tile.background = isSelected ? brushes.selection : brushes.controlFill
            setHover(tile, isSelected ? brushes.selection : brushes.controlHover)
            let title = store.tabs[tab.id]?.displayTitle ?? store.title(of: tab)
            try? AutomationProperties.setName(tile, title)
            try? ToolTipService.setToolTip(tile, title)
            try? Grid.setColumn(tile, Int32(index % columns))
            try? Grid.setRow(tile, Int32(index / columns))
            let id = tab.id
            tile.click.addHandler { [weak self] _, _ in self?.window.select(id) }
            favorites.children.append(tile)
        }
    }

    // MARK: - Rows

    private func header(for space: Space) -> UIElement {
        let header = StackPanel()
        header.orientation = .horizontal
        header.spacing = 6
        header.margin = Thickness(left: 9, top: 10, right: 0, bottom: 6)
        // Arc shows no icon next to the name of a space without one.
        if case let .emoji(emoji) = space.icon {
            let icon = TextBlock()
            icon.text = emoji
            icon.fontSize = 12
            header.children.append(icon)
        }
        let title = TextBlock()
        title.text = space.title
        title.fontSize = 12
        title.fontWeight = FontWeight(weight: 600)
        title.foreground = brushes.subtitle
        title.textTrimming = .characterEllipsis
        header.children.append(title)
        return header
    }

    private func appendRows(for node: SidebarNode, depth: Int, closable: Bool) {
        let selectedID = window.state.selectedTabID
        switch node {
        case let .tab(tab):
            list.children.append(row(
                title: store.tabs[tab.id]?.displayTitle ?? store.title(of: tab), icon: favicon(for: tab),
                isSelected: tab.id == selectedID, depth: depth,
                action: { [weak self] in self?.window.select(tab.id) },
                close: closable ? { [weak self] in self?.window.closeTab(tab.id) } : nil))
        case let .folder(folder):
            let icon = Glyph.view(folder.isExpanded ? Glyph.folderOpen : Glyph.folder, size: 16)
            list.children.append(row(
                title: folder.title, icon: icon, isSelected: false, depth: depth, isBold: true,
                action: { [weak self] in self?.window.store.update { $0.toggleFolder(folder.id) } }, close: nil))
            guard folder.isExpanded else { return }
            for child in folder.children {
                appendRows(for: child, depth: depth + 1, closable: closable)
            }
        case let .split(split):
            // Split views are not part of the Windows app yet: the row shows
            // the first tab.
            guard let first = split.tabs.first else { return }
            list.children.append(row(
                title: split.title, icon: Glyph.view(Glyph.split), isSelected: split.tabs.contains { $0.id == selectedID },
                depth: depth, action: { [weak self] in self?.window.select(first.id) },
                close: closable ? { [weak self] in self?.window.closeTab(first.id) } : nil))
        }
    }

    private func newTabRow() -> Button {
        let row = row(title: "New Tab", icon: Glyph.view(Glyph.add, size: 12), isSelected: false, depth: 0,
                      action: { [weak self] in self?.window.startNewTab() }, close: nil)
        row.foreground = brushes.subtitle
        return row
    }

    /// A row of the list: an icon and a title, with a close button shown
    /// under the pointer.
    private func row(title: String, icon: FrameworkElement, isSelected: Bool, depth: Int, isBold: Bool = false,
                     action: @escaping () -> Void, close: (() -> Void)?) -> Button {
        icon.width = 16
        let label = TextBlock()
        label.text = title
        label.fontSize = 14
        label.textTrimming = .characterEllipsis
        label.verticalAlignment = .center
        if isBold { label.fontWeight = FontWeight(weight: 600) }
        let content = Grid()
        content.columnSpacing = 12
        for width in [GridLength.auto, .star, .auto] {
            let column = ColumnDefinition()
            column.width = width
            content.columnDefinitions.append(column)
        }
        content.children.append(icon)
        try? Grid.setColumn(label, 1)
        content.children.append(label)

        let row = Button()
        row.content = content
        row.height = 36
        row.padding = Thickness(left: 9 + 14 * Double(depth), top: 0, right: 4, bottom: 0)
        row.horizontalAlignment = .stretch
        row.horizontalContentAlignment = .stretch
        row.cornerRadius = CornerRadius(8)
        row.background = isSelected ? brushes.selection : brushes.clear
        if isSelected { setHover(row, brushes.selection) }
        try? AutomationProperties.setName(row, title)
        row.click.addHandler { _, _ in action() }
        if let close {
            let closeButton = Button()
            closeButton.content = Glyph.view(Glyph.close, size: 10)
            closeButton.width = 24
            closeButton.height = 24
            closeButton.padding = Thickness()
            closeButton.cornerRadius = CornerRadius(6)
            try? AutomationProperties.setName(closeButton, "Close Tab")
            try? Grid.setColumn(closeButton, 2)
            content.children.append(closeButton)
            closeButton.click.addHandler { _, _ in close() }
            // Buttons handle their own pointer events: the row's content
            // reports the pointer, hit-testable where empty.
            content.background = brushes.clear
            Self.showOnHover(closeButton, in: content)
        }
        return row
    }

    /// Separator between pinned and today tabs, with Arc's "Clear" button
    /// under the pointer.
    private func divider(for space: Space) -> UIElement {
        let divider = Grid()
        divider.height = space.pinned.isEmpty ? 0 : 20
        divider.margin = Thickness(left: 9, top: 2, right: 4, bottom: 2)
        // Hit-testable where empty, for the pointer to show "Clear".
        divider.background = brushes.clear
        for width in [GridLength.star, .auto] {
            let column = ColumnDefinition()
            column.width = width
            divider.columnDefinitions.append(column)
        }
        let line = Border()
        line.height = 1
        line.verticalAlignment = .center
        line.background = brushes.separator
        try? Grid.setColumnSpan(line, 2)
        divider.children.append(line)
        guard !space.today.isEmpty, !space.pinned.isEmpty else { return divider }

        let label = StackPanel()
        label.orientation = .horizontal
        label.spacing = 4
        label.children.append(Glyph.view(Glyph.clear, size: 10))
        let text = TextBlock()
        text.text = "Clear"
        text.fontSize = 11
        text.fontWeight = FontWeight(weight: 600)
        label.children.append(text)
        let clear = Button()
        clear.content = label
        clear.height = 20
        clear.padding = Thickness(left: 6, top: 0, right: 6, bottom: 0)
        clear.margin = Thickness(left: 8, top: 0, right: 0, bottom: 0)
        clear.foreground = brushes.subtitle
        try? AutomationProperties.setName(clear, "Clear")
        try? ToolTipService.setToolTip(clear, "Archive all unpinned tabs")
        try? Grid.setColumn(clear, 1)
        divider.children.append(clear)
        clear.click.addHandler { [weak self] _, _ in self?.window.clearToday() }
        // The line makes room for "Clear" while it shows.
        Self.showOnHover(clear, in: divider) { shown in try? Grid.setColumnSpan(line, shown ? 1 : 2) }
        return divider
    }

    // MARK: - Spaces

    private func updateSpaceBar(selected: Foundation.UUID) {
        spaceBar.children.clear()
        for space in store.state.spaces {
            let button = Button()
            switch space.icon {
            case let .emoji(emoji): button.content = emoji
            default: button.content = String(space.title.prefix(1)).uppercased()
            }
            button.width = 27
            button.height = 27
            button.padding = Thickness()
            button.cornerRadius = CornerRadius(6)
            button.fontSize = 13
            button.foreground = brushes.icon
            button.opacity = space.id == selected ? 1 : 0.5
            try? AutomationProperties.setName(button, space.title)
            try? ToolTipService.setToolTip(button, space.title)
            let id = space.id
            button.click.addHandler { [weak self] _, _ in self?.window.selectSpace(id) }
            spaceBar.children.append(button)
        }
    }

    // MARK: - Helpers

    private func favicon(for tab: Tab) -> FrameworkElement {
        guard let favicon = store.tabs[tab.id]?.favicon ?? FaviconCache.shared.image(for: tab.url) else {
            let globe = Glyph.view(Glyph.globe)
            globe.foreground = brushes.icon
            return globe
        }
        let image = Image()
        image.source = favicon.bitmap
        image.width = 16
        image.height = 16
        image.verticalAlignment = .center
        return image
    }

    /// `button`'s fill under the pointer and pressed, in place of the
    /// window's.
    private func setHover(_ button: Button, _ brush: SolidColorBrush) {
        _ = button.resources.insert("ButtonBackgroundPointerOver", brush)
        _ = button.resources.insert("ButtonBackgroundPressed", brush)
    }

    /// Shows `button` only while the pointer is over `container`. Hidden, it
    /// stays in the accessibility tree.
    private static func showOnHover(_ button: Button, in container: UIElement,
                                    onChange: ((Bool) -> Void)? = nil) {
        func show(_ shown: Bool) {
            button.opacity = shown ? 1 : 0
            button.isHitTestVisible = shown
            onChange?(shown)
        }
        show(false)
        container.pointerEntered.addHandler { _, _ in show(true) }
        container.pointerExited.addHandler { _, _ in show(false) }
    }
}

extension CornerRadius {
    init(_ radius: Double) {
        self.init(topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius)
    }
}
