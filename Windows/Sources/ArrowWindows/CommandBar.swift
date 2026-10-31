import ArrowCore
import ArrowKit
import Foundation
import UWP
import WinSDK
import WindowsFoundation
import WinUI

/// Arc's command bar (Ctrl+T, Ctrl+L): a field floating over the window,
/// with the open tabs, history, suggestions and commands matching what is
/// typed, on ArrowCore's `CommandBarModel`. A windowed popup, which shows
/// over the page's browser window.
@MainActor
final class CommandBar {
    enum Placement {
        /// In the middle of the window (Ctrl+T).
        case center
        /// Over the address in the title bar (Ctrl+L, a click on it).
        case address
    }

    let model: CommandBarModel
    let placement: Placement
    /// Called once the bar has closed, whatever closed it.
    var onClose: (() -> Void)?
    private unowned let window: BrowserWindow
    private let popup = Popup()
    private let panel = Border()
    private let field = TextBox()
    private let fieldIcon = Glyph.view(Glyph.search)
    private let siteChip = Border()
    private let siteName = TextBlock()
    private let hint = StackPanel()
    private let hintText = TextBlock()
    private let separator = Border()
    private let scroller = ScrollViewer()
    private let rows = StackPanel()
    private let colors: Colors

    init(model: CommandBarModel, placement: Placement, window: BrowserWindow) {
        self.model = model
        self.placement = placement
        self.window = window
        colors = Colors(window.brushes.palette)
        layout()
        handleEvents()
        observe { [weak self] in self?.update() }
    }

    /// Opens the bar over `root`, the window's content, with the keyboard.
    func open(over root: FrameworkElement) {
        popup.xamlRoot = root.xamlRoot
        place(in: root)
        field.text = model.text
        popup.isOpen = true
        _ = try? field.focus(.programmatic)
        if !model.text.isEmpty { try? field.selectAll() }
    }

    /// Fits the bar to `root`'s size.
    func place(in root: FrameworkElement) {
        let width: Double
        switch placement {
        case .center:
            // Arc's, as the macOS app measured it.
            width = min(764, root.actualWidth - 80)
            popup.verticalOffset = max(root.actualHeight / 2 - 168, 40)
        case .address:
            width = min(640, root.actualWidth - 16)
            popup.verticalOffset = 2
        }
        panel.width = max(width, 0)
        popup.horizontalOffset = (root.actualWidth - width) / 2
    }

    func close() {
        popup.isOpen = false
    }

    /// Searches `site` with what comes next ("youtube", then Tab).
    func searchSite(_ site: SiteSearch) {
        model.activeSiteSearch = site
        model.text = ""
        field.text = ""
    }

    // MARK: - Layout

    private func layout() {
        let content = Grid()
        for (index, child) in ([fieldRow(), separator, scroller] as [FrameworkElement]).enumerated() {
            let row = RowDefinition()
            row.height = .auto
            try? Grid.setRow(child, Int32(index))
            content.rowDefinitions.append(row)
            content.children.append(child)
        }
        separator.height = 1
        separator.background = colors.stroke
        rows.spacing = 4
        rows.padding = Thickness(left: 10, top: 6, right: 10, bottom: 6)
        scroller.content = rows
        scroller.maxHeight = 440
        panel.child = content
        panel.background = colors.fill
        panel.borderBrush = colors.stroke
        panel.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        panel.cornerRadius = CornerRadius(12)
        popup.child = panel
        // Its own window, over the browser's.
        popup.shouldConstrainToRootBounds = false
        popup.isLightDismissEnabled = true
    }

    /// The field, after the kind of the selected row or the site searched,
    /// and before the site search a Tab would start.
    private func fieldRow() -> Grid {
        let row = Grid()
        row.height = 62
        row.padding = Thickness(left: 20, top: 0, right: 16, bottom: 0)
        row.columnSpacing = 9
        for width in [GridLength.auto, .star, .auto] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        fieldIcon.width = 24
        fieldIcon.foreground = colors.secondary
        row.children.append(fieldIcon)
        siteName.fontSize = 13
        siteName.fontWeight = FontWeight(weight: 600)
        siteName.foreground = colors.text
        siteChip.child = siteName
        siteChip.padding = Thickness(left: 8, top: 4, right: 8, bottom: 4)
        siteChip.cornerRadius = CornerRadius(12)
        siteChip.background = colors.tile
        siteChip.verticalAlignment = .center
        row.children.append(siteChip)

        field.fontSize = 18
        field.fontWeight = FontWeight(weight: 500)
        field.minHeight = 0
        field.padding = Thickness()
        field.verticalAlignment = .center
        field.isSpellCheckEnabled = false
        field.selectionHighlightColor = colors.accent
        try? AutomationProperties.setName(field, "Command Bar")
        // The field draws on the panel: no fill, border or focus line.
        let keys: [(String, SolidColorBrush)] = [
            ("Background", colors.clear), ("BorderBrush", colors.clear), ("Foreground", colors.text),
            ("PlaceholderForeground", colors.secondary),
        ]
        for (key, brush) in keys {
            for state in ["", "PointerOver", "Focused"] {
                _ = field.resources.insert("TextControl\(key)\(state)", brush)
            }
        }
        try? Grid.setColumn(field, 1)
        row.children.append(field)

        hintText.fontSize = 13
        hintText.foreground = colors.secondary
        hintText.verticalAlignment = .center
        hint.orientation = .horizontal
        hint.spacing = 6
        hint.children.append(hintText)
        hint.children.append(keyCap("Tab"))
        try? Grid.setColumn(hint, 2)
        row.children.append(hint)
        return row
    }

    private func update() {
        let items = model.items
        let selectedIndex = model.selectedIndex
        rows.children.clear()
        for (index, item) in items.enumerated() {
            rows.children.append(row(for: item, at: index, isSelected: index == selectedIndex))
        }
        separator.visibility = items.isEmpty ? .collapsed : .visible
        scroller.visibility = items.isEmpty ? .collapsed : .visible
        scrollToRow(selectedIndex)

        // Arc shows the kind of the selected row (history, search…) in the
        // field.
        let symbol = model.typedText.isEmpty ? nil : model.selectedItem?.symbol
        fieldIcon.text = Glyph.symbol(symbol ?? "magnifyingglass")
        let site = model.activeSiteSearch
        siteName.text = site?.name ?? ""
        siteChip.visibility = site == nil ? .collapsed : .visible
        fieldIcon.visibility = site == nil ? .visible : .collapsed
        field.placeholderText = model.placeholder
        let siteHint = model.siteSearchHint
        hintText.text = siteHint.map { "Search \($0.name)" } ?? ""
        hint.visibility = siteHint == nil ? .collapsed : .visible
    }

    /// A row: its icon (a glyph, or the page's favicon), its title and
    /// subtitle, and what it does ("Switch to Tab", a shortcut).
    private func row(for item: CommandBarItem, at index: Int, isSelected: Bool) -> UIElement {
        let foreground = isSelected ? colors.onAccent : colors.text
        let row = Grid()
        row.height = 46
        row.padding = Thickness(left: 10, top: 0, right: 13, bottom: 0)
        row.columnSpacing = 9
        row.cornerRadius = CornerRadius(7)
        // Hit-testable where empty.
        row.background = isSelected ? colors.accent : colors.clear
        for width in [GridLength(value: 24, gridUnitType: .pixel), .star, .auto] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        if let symbol = item.symbol {
            let icon = Glyph.view(Glyph.symbol(symbol), size: 13)
            icon.foreground = foreground
            row.children.append(icon)
        } else {
            // Arc sets the selected row's favicon on a white tile.
            let tile = Border()
            tile.width = 24
            tile.height = 24
            tile.cornerRadius = CornerRadius(6)
            tile.background = isSelected ? colors.onAccent : colors.clear
            tile.child = favicon(for: item)
            row.children.append(tile)
        }

        let label = TextBlock()
        label.fontSize = 14
        label.textTrimming = .characterEllipsis
        label.verticalAlignment = .center
        let title = Run()
        title.text = item.title
        title.fontWeight = FontWeight(weight: 500)
        title.foreground = foreground
        label.inlines.append(title)
        if let subtitle = item.subtitle {
            let run = Run()
            run.text = "  —  \(subtitle)"
            run.foreground = isSelected ? colors.onAccentSecondary : colors.secondary
            label.inlines.append(run)
        }
        try? Grid.setColumn(label, 1)
        row.children.append(label)

        if let action = item.actionLabel {
            let actions = StackPanel()
            actions.orientation = .horizontal
            actions.spacing = 8
            actions.verticalAlignment = .center
            let text = TextBlock()
            text.text = action
            text.fontSize = 13
            text.verticalAlignment = .center
            text.foreground = isSelected ? colors.onAccent : colors.secondary
            actions.children.append(text)
            if case .switchToTab = item.kind {
                let arrow = Glyph.view(Glyph.forward, size: 11)
                arrow.foreground = isSelected ? colors.accent : colors.secondary
                let tile = Border()
                tile.width = 24
                tile.height = 24
                tile.cornerRadius = CornerRadius(6)
                tile.background = isSelected ? colors.onAccent : colors.tile
                tile.child = arrow
                actions.children.append(tile)
            }
            try? Grid.setColumn(actions, 2)
            row.children.append(actions)
        }
        try? AutomationProperties.setName(row, item.title)
        row.pointerEntered.addHandler { [weak self] _, _ in
            guard let self, model.selectedIndex != index else { return }
            model.selectedIndex = index
        }
        row.tapped.addHandler { [weak self] _, _ in
            guard let self else { return }
            window.perform(item, from: self)
        }
        return row
    }

    /// Scrolls the list to show the row at `index`.
    private func scrollToRow(_ index: Int) {
        let rowHeight = 46.0, spacing = 4.0
        let top = rows.padding.top + Double(index) * (rowHeight + spacing)
        let offset = scroller.verticalOffset
        if top < offset {
            _ = try? scroller.changeView(nil, top, nil)
        } else if scroller.viewportHeight > 0, top + rowHeight > offset + scroller.viewportHeight {
            _ = try? scroller.changeView(nil, top + rowHeight + rows.padding.bottom - scroller.viewportHeight, nil)
        }
    }

    private func favicon(for item: CommandBarItem) -> FrameworkElement {
        var image: PageImage?
        if case let .switchToTab(id) = item.kind { image = window.store.tabs[id]?.favicon }
        guard let image = image ?? item.url.flatMap({ FaviconCache.shared.image(for: $0) }) else {
            let globe = Glyph.view(Glyph.globe)
            globe.foreground = colors.secondary
            return globe
        }
        let view = Image()
        view.source = image.bitmap
        view.width = 16
        view.height = 16
        return view
    }

    /// A key, as Arc draws it in the bar ("Tab").
    private func keyCap(_ label: String) -> Border {
        let text = TextBlock()
        text.text = label
        text.fontSize = 11
        text.fontWeight = FontWeight(weight: 500)
        text.foreground = colors.secondary
        text.verticalAlignment = .center
        let cap = Border()
        cap.child = text
        cap.height = 18
        cap.padding = Thickness(left: 5, top: 0, right: 5, bottom: 0)
        cap.cornerRadius = CornerRadius(4)
        cap.background = colors.tile
        cap.verticalAlignment = .center
        return cap
    }

    // MARK: - Events

    private func handleEvents() {
        field.textChanged.addHandler { [weak self] _, _ in self?.fieldDidChange() }
        // Before the field moves its caret with the arrows, or Tab moves the
        // keyboard away.
        field.previewKeyDown.addHandler { [weak self] _, event in
            guard let self, let event else { return }
            event.handled = handleKey(event.key)
        }
        popup.closed.addHandler { [weak self] _, _ in self?.onClose?() }
    }

    private func fieldDidChange() {
        let text = field.text
        guard text != model.text else { return }
        model.text = text
        // Typing forward completes the address from history, selected.
        guard model.text != text else { return }
        field.text = model.text
        if let range = model.selectedRange {
            let utf16 = model.text.utf16
            let start = utf16.distance(from: utf16.startIndex, to: range.lowerBound)
            try? field.select(Int32(start), Int32(utf16.distance(from: range.lowerBound, to: range.upperBound)))
        }
    }

    /// Handles `key` in the field: whether it was the bar's.
    private func handleKey(_ key: VirtualKey) -> Bool {
        switch key {
        case .down:
            model.moveSelection(1)
        case .up:
            model.moveSelection(-1)
        case .enter:
            submit()
        case .escape:
            window.dismissCommandBar()
        case .tab:
            // "youtube" then Tab searches YouTube; Tab stays in the field.
            if model.acceptSiteSearchHint() { field.text = "" }
        case .back:
            guard field.text.isEmpty, model.activeSiteSearch != nil else { return false }
            model.clearSiteSearch()
        default:
            return false
        }
        return true
    }

    private func submit() {
        // Max ▸ Instant Links: Shift+Enter opens the top result of a search.
        if GetKeyState(VK_SHIFT) < 0, let url = model.instantLinkURL {
            window.open(url, from: self)
        } else if let item = model.selectedItem {
            window.perform(item, from: self)
        } else if !model.text.isEmpty {
            let url = model.activeSiteSearch.map { $0.searchURL(for: model.text) }
                ?? URLInput.resolve(model.text, engine: window.store.settings.searchEngine)
            window.open(url, from: self)
        }
    }

    // MARK: - Colors

    /// A light or dark panel, whatever the space's colors, with its accent
    /// on the selected row.
    private struct Colors {
        let fill: SolidColorBrush
        let text: SolidColorBrush
        let secondary: SolidColorBrush
        let stroke: SolidColorBrush
        let tile: SolidColorBrush
        let accent: SolidColorBrush
        let onAccent = SolidColorBrush(Color(.white))
        let onAccentSecondary = SolidColorBrush(Color(RGBColor.white.withAlpha(0.75)))
        let clear = SolidColorBrush(Color(a: 0, r: 0, g: 0, b: 0))

        init(_ palette: ThemePalette) {
            let primary: RGBColor = palette.isDark ? .white : .black
            fill = SolidColorBrush(Color(palette.isDark ? RGBColor(hex: 0x292929) : RGBColor(hex: 0xF9F9F9)))
            text = SolidColorBrush(Color(primary.withAlpha(0.88)))
            secondary = SolidColorBrush(Color(primary.withAlpha(0.5)))
            stroke = SolidColorBrush(Color(primary.withAlpha(0.08)))
            tile = SolidColorBrush(Color(primary.withAlpha(0.07)))
            accent = SolidColorBrush(Color(palette.accent))
        }
    }
}
