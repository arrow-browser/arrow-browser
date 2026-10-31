import ArrowCore
import ArrowKit
import Foundation
import UWP
import WindowsFoundation
import WinUI

/// The sidebar, laid out as Arc's: the favorites grid, the space's name,
/// its pinned tabs and folders, the divider with "Clear", New Tab and
/// today's tabs, and at the bottom the archive, the space switcher and the
/// Add menu. Rows have Arc's context menus, and rename in place.
@MainActor
final class Sidebar {
    let element = Grid()
    private unowned let window: BrowserWindow
    private let favorites = Grid()
    private let list = StackPanel()
    private let scroller = ScrollViewer()
    private let bottomBar = Grid()
    private let archiveButton = Sidebar.barButton(Glyph.archive, name: "Archive")
    private let downloadsButton = Sidebar.barButton(Glyph.download, name: "Downloads")
    private let addButton = Sidebar.barButton(Glyph.add, name: "Add")
    private let spaceBar = StackPanel()
    /// Arc's media controls, for a tab playing out of sight.
    private let mediaBar = Border()
    /// Pages never visited whose favicon was asked for, once each.
    private var requestedFavicons: Set<String> = []
    /// The tab paused from the media controls, which stay (with Play) while
    /// it shows the same page.
    private var pausedMedia: (id: Foundation.UUID, url: String)?

    init(window: BrowserWindow) throws {
        self.window = window
        element.padding = Thickness(left: 8, top: 1, right: 8, bottom: 0)
        favorites.columnSpacing = 8
        favorites.rowSpacing = 8
        list.spacing = 2
        scroller.content = list
        // Hit-testable where empty: a right click there opens the space's menu.
        list.background = window.brushes.clear
        list.minHeight = 400
        list.setContextMenu { [weak self] in self?.spaceMenu() }
        // Dropped under the rows, a node goes last in today's tabs; on the
        // favorites, it becomes one.
        makeDropTarget(list) { [weak self] in
            let spaceID = self?.state.selectedSpaceID
            let count = spaceID.flatMap { self?.store.state.space($0)?.today.count } ?? 0
            return SidebarLocation(spaceID: spaceID, section: .today, index: count)
        }
        makeDropTarget(favorites) { .favorites() }
        layoutBottomBar()
        // Apart from the rows: downloads change many times a second.
        observe { [weak self] in
            guard let self else { return }
            downloadsButton.visibility = store.downloads.items.isEmpty ? .collapsed : .visible
        }
        mediaBar.cornerRadius = CornerRadius(8)
        mediaBar.padding = Thickness(left: 9, top: 6, right: 4, bottom: 6)
        mediaBar.margin = Thickness(left: 0, top: 6, right: 0, bottom: 0)
        mediaBar.visibility = .collapsed
        observe { [weak self] in self?.updateMediaBar() }
        let rows: [(FrameworkElement, GridLength)] = [(favorites, .auto), (scroller, .star), (mediaBar, .auto),
                                                      (bottomBar, .auto)]
        for (index, (child, height)) in rows.enumerated() {
            let definition = RowDefinition()
            definition.height = height
            element.rowDefinitions.append(definition)
            try Grid.setRow(child, Int32(index))
            element.children.append(child)
        }
    }

    private var store: BrowserStore { window.store }
    private var state: WindowState { window.state }
    private var brushes: ThemeBrushes { window.brushes }

    /// The archive button, where Arc's archive opens.
    var archiveAnchor: FrameworkElement { archiveButton }

    func update() {
        guard let space = store.state.space(state.selectedSpaceID) else { return }
        updateFavorites(store.state.favorites(for: space.profileID))
        list.children.clear()
        list.children.append(header(for: space))
        for (index, node) in space.pinned.enumerated() {
            appendRows(for: node, section: .pinned, depth: 0, folderID: nil, index: index)
        }
        list.children.append(divider(for: space))
        list.children.append(newTabRow())
        for (index, node) in space.today.enumerated() {
            appendRows(for: node, section: .today, depth: 0, folderID: nil, index: index)
        }
        updateSpaceBar(selected: space.id)
    }

    // MARK: - Favorites

    private func updateFavorites(_ tabs: [Tab]) {
        favorites.children.clear()
        favorites.columnDefinitions.clear()
        favorites.rowDefinitions.clear()
        favorites.margin = Thickness(left: 0, top: 0, right: 0, bottom: tabs.isEmpty ? -10 : 8)
        // Empty, a strip where a dragged tab becomes the first favorite.
        favorites.minHeight = tabs.isEmpty ? 10 : 0
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
            let isSelected = tab.id == state.selectedTabID
            let tile = Button()
            tile.content = favicon(for: tab)
            tile.height = 45
            // Arc's favicon sits a pixel below the middle.
            tile.padding = Thickness(left: 0, top: 1, right: 0, bottom: 0)
            tile.horizontalAlignment = .stretch
            tile.cornerRadius = CornerRadius(8)
            tile.background = isSelected ? brushes.selection : brushes.controlFill
            setHover(tile, isSelected ? brushes.selection : brushes.controlHover)
            let title = title(of: tab)
            try? AutomationProperties.setName(tile, title)
            try? ToolTipService.setToolTip(tile, title)
            try? Grid.setColumn(tile, Int32(index % columns))
            try? Grid.setRow(tile, Int32(index / columns))
            let id = tab.id
            tile.click.addHandler { [weak self] _, _ in self?.window.select(id) }
            tile.setContextMenu { [weak self] in self?.favoriteMenu(for: tab) }
            makeDraggable(tile, nodeID: tab.id)
            makeDropTarget(tile) { .favorites(index: index) }
            favorites.children.append(tile)
        }
    }

    // MARK: - Rows

    private func header(for space: Space) -> UIElement {
        // Arc's: a 16-pixel icon, the name 5 pixels after it, the rows 10
        // pixels below.
        let header = StackPanel()
        header.orientation = .horizontal
        header.spacing = 5
        header.margin = Thickness(left: 9, top: 10, right: 0, bottom: 8)
        // Hit-testable where empty, for its menu.
        header.background = brushes.clear
        // Arc shows the space's icon, emoji or symbol, before its name; none
        // for a space without one.
        switch space.icon {
        case let .emoji(emoji)?:
            let icon = TextBlock()
            icon.text = emoji
            icon.fontSize = 12
            icon.width = 16
            icon.textAlignment = .center
            header.children.append(icon)
        case let .symbol(name)?:
            let icon = Glyph.view(Glyph.symbol(name), size: 14)
            icon.foreground = brushes.title
            icon.width = 16
            icon.textAlignment = .center
            icon.verticalAlignment = .center
            header.children.append(icon)
        case nil:
            break
        }
        if state.renamingNodeID == space.id {
            header.children.append(renameField(space.title, width: 150) { [weak self] title in
                guard !title.isEmpty else { return }
                self?.store.update { $0.updateSpace(space.id) { $0.title = title } }
            })
            return header
        }
        let title = TextBlock()
        title.text = space.title
        title.fontSize = 12
        title.fontWeight = FontWeight(weight: 600)
        title.foreground = brushes.subtitle
        title.textTrimming = .characterEllipsis
        header.children.append(title)
        header.doubleTapped.addHandler { [weak self] _, _ in self?.window.rename(space.id) }
        // Dropped on the space's name, a node is pinned first.
        makeDropTarget(header) { SidebarLocation(spaceID: space.id, section: .pinned, index: 0) }
        header.setContextMenu { [weak self] in self?.spaceMenu() }
        return header
    }

    private func appendRows(for node: SidebarNode, section: SidebarSection, depth: Int, folderID: Foundation.UUID?,
                            index: Int) {
        let selectedID = state.selectedTabID
        let spaceID = state.selectedSpaceID
        // Dropped on a row, a node goes before it.
        let before = SidebarLocation(spaceID: spaceID, section: section, folderID: folderID, index: index)
        switch node {
        case let .tab(tab):
            let live = store.tabs[tab.id]
            let row = row(title: title(of: tab), icon: favicon(for: tab), isSelected: tab.id == selectedID, depth: depth,
                          renaming: tab.id, rename: { [weak self] title in
                              self?.store.update { $0.updateTab(tab.id) { $0.customTitle = title.isEmpty ? nil : title } }
                          },
                          action: { [weak self] in self?.window.select(tab.id) },
                          close: { [weak self] in self?.window.closeTab(tab.id) },
                          audio: live.flatMap { $0.isPlayingMedia || $0.isMuted ? $0 : nil })
            row.setContextMenu { [weak self] in self?.tabMenu(for: tab, section: section) }
            makeDraggable(row, nodeID: tab.id)
            makeDropTarget(row) { before }
            list.children.append(row)
        case let .folder(folder):
            // A live folder shows Arc's bolt; a closed one Arc's filled folder.
            let icon: FrameworkElement
            if !LiveFolders.shared.isLive(folder.id), !folder.isExpanded {
                icon = closedFolderIcon()
            } else {
                let glyph = Glyph.view(LiveFolders.shared.isLive(folder.id) ? Glyph.live : Glyph.folderOpen, size: 16)
                glyph.foreground = brushes.folder
                icon = glyph
            }
            let row = row(title: folder.title, icon: icon, isSelected: false, depth: depth, isBold: true,
                          renaming: folder.id, rename: { [weak self] title in
                              guard !title.isEmpty else { return }
                              self?.store.update { $0.renameFolder(folder.id, to: title) }
                          },
                          action: { [weak self] in self?.window.store.update { $0.toggleFolder(folder.id) } }, close: nil)
            row.setContextMenu { [weak self] in self?.folderMenu(for: folder) }
            makeDraggable(row, nodeID: folder.id)
            // Dropped on a folder, a node goes in it.
            makeDropTarget(row) { SidebarLocation(spaceID: spaceID, section: .pinned, folderID: folder.id, index: 0) }
            list.children.append(row)
            guard folder.isExpanded else { return }
            for (childIndex, child) in folder.children.enumerated() {
                appendRows(for: child, section: section, depth: depth + 1, folderID: folder.id, index: childIndex)
            }
            if let note = liveFolderNote(folder, depth: depth + 1) { list.children.append(note) }
        case let .split(split):
            guard let first = split.tabs.first else { return }
            let isSelected = split.tabs.contains { $0.id == selectedID }
            let row = row(title: split.title, icon: Glyph.view(Glyph.splitView), isSelected: isSelected, depth: depth,
                          action: { [weak self] in self?.window.select(first.id) },
                          close: section == .today ? { [weak self] in
                              for tab in split.tabs { self?.window.closeTab(tab.id) }
                          } : nil)
            row.setContextMenu { [weak self] in
                Menu.flyout([
                    Menu.title("Split View Context Menu"),
                    Menu.item("Separate Split View") { self?.window.separateSplitView(split.id) },
                ])
            }
            makeDraggable(row, nodeID: split.id)
            makeDropTarget(row) { before }
            list.children.append(row)
        }
    }

    /// Arc's line in a live folder that cannot show pull requests: signed
    /// out of GitHub, GitHub unreachable (both open GitHub), or none yet.
    private func liveFolderNote(_ folder: ArrowKit.Folder, depth: Int) -> UIElement? {
        let liveFolders = LiveFolders.shared
        guard liveFolders.isLive(folder.id) else { return nil }
        let note: (text: String, url: String?)
        switch liveFolders.status[folder.id] {
        case .signedOut:
            note = (LiveFolders.signInText, LiveFolders.signInURL)
        case .unreachable where folder.children.isEmpty:
            note = (LiveFolders.unreachableText, LiveFolders.pullsURL)
        case nil where folder.children.isEmpty:
            note = (LiveFolders.emptyText, nil)
        default:
            return nil
        }
        let text = TextBlock()
        text.text = note.text
        text.fontSize = 12
        text.textWrapping = .wrap
        text.margin = Thickness(left: 10 + Double(depth) * 16, top: 4, right: 10, bottom: 6)
        text.foreground = note.url == nil ? brushes.subtitle : brushes.title
        if let url = note.url {
            text.textDecorations = .underline
            text.tapped.addHandler { [weak self] _, _ in self?.window.openNewTab(url) }
        }
        return text
    }

    private func newTabRow() -> Button {
        let row = row(title: "New Tab", icon: Glyph.view(Glyph.add, size: 12), isSelected: false, depth: 0,
                      action: { [weak self] in self?.window.startNewTab() }, close: nil)
        row.foreground = brushes.subtitle
        return row
    }

    /// A row of the list: an icon and a title, with a close button shown
    /// under the pointer, or a field while it is renamed.
    private func row(title: String, icon: FrameworkElement, isSelected: Bool, depth: Int, isBold: Bool = false,
                     renaming nodeID: Foundation.UUID? = nil, rename: ((String) -> Void)? = nil,
                     action: @escaping () -> Void, close: (() -> Void)?, audio: WebTab? = nil) -> Button {
        icon.width = 16
        let content = Grid()
        content.columnSpacing = 12
        for width in [GridLength.auto, .star, .auto, .auto] {
            let column = ColumnDefinition()
            column.width = width
            content.columnDefinitions.append(column)
        }
        content.children.append(icon)
        if let nodeID, let rename, state.renamingNodeID == nodeID {
            let field = renameField(title, width: nil, commit: rename)
            try? Grid.setColumn(field, 1)
            content.children.append(field)
        } else {
            let label = TextBlock()
            label.text = title
            label.fontSize = 14
            label.textTrimming = .characterEllipsis
            label.verticalAlignment = .center
            if isBold { label.fontWeight = FontWeight(weight: 600) }
            try? Grid.setColumn(label, 1)
            content.children.append(label)
        }

        let row = Button()
        row.content = content
        row.height = 36
        row.padding = Thickness(left: 9 + 14 * Double(depth), top: 0, right: 4, bottom: 0)
        row.horizontalAlignment = .stretch
        row.horizontalContentAlignment = .stretch
        row.cornerRadius = CornerRadius(8)
        row.background = isSelected ? brushes.selection : brushes.clear
        if isSelected {
            setHover(row, brushes.selection)
            row.borderThickness = Thickness(left: 0, top: 0, right: 0, bottom: 1)
            row.borderBrush = brushes.selectionEdge
            _ = row.resources.insert("ButtonBorderBrushPointerOver", brushes.selectionEdge)
            _ = row.resources.insert("ButtonBorderBrushPressed", brushes.selectionEdge)
        }
        try? AutomationProperties.setName(row, title)
        row.click.addHandler { _, _ in action() }
        if let audio {
            // Arc's speaker: the tab plays sound; a click mutes it.
            let speaker = Button()
            speaker.content = Glyph.view(audio.isMuted ? Glyph.mute : Glyph.speaker, size: 12)
            speaker.width = 24
            speaker.height = 24
            speaker.padding = Thickness()
            speaker.cornerRadius = CornerRadius(6)
            try? AutomationProperties.setName(speaker, audio.isMuted ? "Unmute" : "Mute")
            try? Grid.setColumn(speaker, 2)
            content.children.append(speaker)
            let tabID = audio.id
            speaker.click.addHandler { [weak self] _, _ in self?.window.toggleMute(tabID) }
        }
        if let close {
            let closeButton = Button()
            closeButton.content = Glyph.view(Glyph.close, size: 10)
            closeButton.width = 24
            closeButton.height = 24
            closeButton.padding = Thickness()
            closeButton.cornerRadius = CornerRadius(6)
            try? AutomationProperties.setName(closeButton, "Close Tab")
            try? Grid.setColumn(closeButton, 3)
            content.children.append(closeButton)
            closeButton.click.addHandler { _, _ in close() }
            // Buttons handle their own pointer events: the row's content
            // reports the pointer, hit-testable where empty.
            content.background = brushes.clear
            Self.showOnHover(closeButton, in: content)
        }
        return row
    }

    /// The field of a row being renamed: Enter or a click elsewhere keeps
    /// the new name, Escape the old one.
    private func renameField(_ text: String, width: Double?, commit: @escaping (String) -> Void) -> TextBox {
        let field = TextBox()
        field.text = text
        field.fontSize = 14
        field.minHeight = 0
        field.padding = Thickness(left: 4, top: 2, right: 4, bottom: 2)
        field.verticalAlignment = .center
        if let width { field.width = width }
        var isDone = false
        // The field itself, not weakly: its Swift object would go while WinUI
        // shows it.
        let finish: (Bool) -> Void = { [weak self] keep in
            guard !isDone, let self else { return }
            isDone = true
            if keep { commit(field.text.trimmingCharacters(in: .whitespaces)) }
            state.renamingNodeID = nil
        }
        field.keyDown.addHandler { _, event in
            guard let event else { return }
            switch event.key {
            case .enter:
                event.handled = true
                finish(true)
            case .escape:
                event.handled = true
                finish(false)
            default:
                break
            }
        }
        field.lostFocus.addHandler { _, _ in finish(true) }
        field.loaded.addHandler { _, _ in
            _ = try? field.focus(.programmatic)
            try? field.selectAll()
        }
        return field
    }

    /// Separator between pinned and today tabs, with Arc's "Clear" button
    /// under the pointer.
    private func divider(for space: Space) -> UIElement {
        let divider = Grid()
        divider.height = space.pinned.isEmpty ? 0 : 20
        // Dropped on the divider, a node goes first in today's tabs.
        makeDropTarget(divider) { SidebarLocation(spaceID: space.id, section: .today, index: 0) }
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

    // MARK: - Bottom bar

    /// The archive on the left, the spaces in the middle, Add on the right.
    private func layoutBottomBar() {
        bottomBar.margin = Thickness(left: 3, top: 6, right: 2, bottom: 11)
        for width in [GridLength.auto, .star, .auto] {
            let column = ColumnDefinition()
            column.width = width
            bottomBar.columnDefinitions.append(column)
        }
        let leading = StackPanel()
        leading.orientation = .horizontal
        leading.spacing = 2
        leading.children.append(archiveButton)
        // Shown while there are downloads.
        downloadsButton.visibility = .collapsed
        leading.children.append(downloadsButton)
        bottomBar.children.append(leading)
        spaceBar.orientation = .horizontal
        spaceBar.spacing = 2
        spaceBar.horizontalAlignment = .center
        try? Grid.setColumn(spaceBar, 1)
        bottomBar.children.append(spaceBar)
        try? Grid.setColumn(addButton, 2)
        bottomBar.children.append(addButton)
        archiveButton.click.addHandler { [weak self] _, _ in self?.window.showArchive() }
        downloadsButton.click.addHandler { [weak self] _, _ in
            guard let self else { return }
            window.showDownloads(under: downloadsButton)
        }
        addButton.click.addHandler { [weak self] _, _ in
            guard let self else { return }
            let menu = window.addMenu()
            menu.placement = .top
            try? menu.showAt(addButton)
        }
    }

    private func updateSpaceBar(selected: Foundation.UUID) {
        archiveButton.foreground = brushes.icon
        addButton.foreground = brushes.icon
        downloadsButton.foreground = brushes.icon
        spaceBar.children.clear()
        for space in store.state.spaces {
            let button = Button()
            switch space.icon {
            case let .emoji(emoji): button.content = emoji
            default:
                // Arc's dot for a space without an icon.
                let dot = Border()
                dot.width = 6
                dot.height = 6
                dot.cornerRadius = CornerRadius(3)
                dot.background = brushes.icon
                button.content = dot
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

    // MARK: - Media

    /// Shows the controls of a tab playing sound that the window does not
    /// show: its favicon and title (a click selects it), play or pause, and
    /// mute.
    private func updateMediaBar() {
        // The set of live tabs is not observable; what changes it is (the
        // tabs, the selected one).
        _ = (store.state, state.selectedTabID)
        let paused = pausedMedia.flatMap { paused in
            store.tabs[paused.id].flatMap { $0.url == paused.url ? $0 : nil }
        }
        let playing = store.tabs.values.first { $0.isPlayingMedia && !window.isDisplaying($0) }
            ?? paused.flatMap { window.isDisplaying($0) ? nil : $0 }
        guard let tab = playing else {
            pausedMedia = nil
            mediaBar.visibility = .collapsed
            mediaBar.child = nil
            return
        }
        let row = Grid()
        row.columnSpacing = 8
        for width in [GridLength.auto, .star, .auto, .auto] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        let icon: FrameworkElement
        if let favicon = tab.favicon {
            let image = Image()
            image.source = favicon.bitmap
            image.width = 16
            image.height = 16
            icon = image
        } else {
            icon = Glyph.view(Glyph.speaker, size: 13)
        }
        icon.verticalAlignment = .center
        row.children.append(icon)
        let title = TextBlock()
        title.text = tab.displayTitle
        title.fontSize = 12
        title.textTrimming = .characterEllipsis
        title.verticalAlignment = .center
        title.foreground = brushes.title
        try? Grid.setColumn(title, 1)
        row.children.append(title)
        let tabID = tab.id
        let isPlaying = tab.isPlayingMedia
        for (index, (glyph, name, action)) in [
            (isPlaying ? Glyph.pause : Glyph.play, isPlaying ? "Pause" : "Play", { [weak self] in
                self?.pausedMedia = isPlaying ? (tabID, tab.url) : nil
                tab.playPauseMedia()
            }),
            (tab.isMuted ? Glyph.mute : Glyph.speaker, tab.isMuted ? "Unmute" : "Mute",
             { [weak self] in self?.window.toggleMute(tabID) }),
        ].enumerated() {
            let button = Button()
            button.content = Glyph.view(glyph, size: 12)
            button.width = 26
            button.height = 26
            button.padding = Thickness()
            button.cornerRadius = CornerRadius(6)
            try? AutomationProperties.setName(button, name)
            try? ToolTipService.setToolTip(button, name)
            try? Grid.setColumn(button, Int32(index + 2))
            button.click.addHandler { _, _ in action() }
            // Not a tap of the row, which shows the tab.
            button.tapped.addHandler { _, args in args?.handled = true }
            row.children.append(button)
        }
        // Hit-testable where empty: a click shows the tab.
        row.background = brushes.clear
        row.tapped.addHandler { [weak self] _, _ in self?.window.select(tabID) }
        mediaBar.child = row
        mediaBar.background = brushes.controlFill
        mediaBar.visibility = .visible
        try? AutomationProperties.setName(mediaBar, "Now Playing")
    }

    // MARK: - Menus

    /// Arc's menu of a pinned or today tab.
    private func tabMenu(for tab: Tab, section: SidebarSection) -> MenuFlyout {
        let live = store.tabs[tab.id]
        let today = store.state.space(state.selectedSpaceID)?.today.allTabs.map(\.id) ?? []
        let index = today.firstIndex(of: tab.id)
        let isPinned = section == .pinned
        return Menu.flyout([
            Menu.title("Tab Context Menu"),
            Menu.item("Copy Link") { [weak self] in self?.window.copyLink(of: tab.id) },
            Menu.separator(),
            Menu.item("Rename…") { [weak self] in self?.window.rename(tab.id) },
            Menu.item(live?.isMuted == true ? "Unmute" : "Mute", isEnabled: live?.isPlayingMedia == true || live?.isMuted == true) { [weak self] in
                self?.window.toggleMute(tab.id)
            },
            Menu.separator(),
            Menu.item("Add Split View") { [weak self] in
                self?.window.select(tab.id)
                self?.window.addSplitView()
            },
            Menu.item("Duplicate") { [weak self] in self?.window.duplicateTab(tab.id) },
            Menu.submenu("Move to", moveMenu(for: tab.id)),
            Menu.separator(),
            isPinned
                ? Menu.item("Unpin Tab") { [weak self] in self?.store.update { $0.togglePin(tab.id) } }
                : Menu.item("Archive Other Tabs", isEnabled: today.count > 1) { [weak self] in
                    self?.window.archiveOtherTabs(than: tab.id)
                },
            isPinned
                ? Menu.item("Close Tab") { [weak self] in self?.window.closeTab(tab.id) }
                : Menu.item("Archive Tab") { [weak self] in self?.window.closeTab(tab.id) },
            isPinned ? nil : Menu.item("Archive Tabs Below", isEnabled: index.map { $0 < today.count - 1 } ?? false) { [weak self] in
                self?.window.archiveTabsBelow(tab.id)
            },
        ])
    }

    /// Arc's menu of a favorite.
    private func favoriteMenu(for tab: Tab) -> MenuFlyout {
        let live = store.tabs[tab.id]
        return Menu.flyout([
            Menu.title("Tab Context Menu"),
            Menu.item("Copy Link") { [weak self] in self?.window.copyLink(of: tab.id) },
            Menu.separator(),
            Menu.item(live?.isMuted == true ? "Unmute" : "Mute", isEnabled: live?.isPlayingMedia == true || live?.isMuted == true) { [weak self] in
                self?.window.toggleMute(tab.id)
            },
            Menu.separator(),
            Menu.submenu("Edit Pinned Page", [
                Menu.item("Use Current Page", isEnabled: live.map { $0.url != tab.pinnedURL } ?? false) { [weak self] in
                    guard let url = live?.url else { return }
                    self?.store.update { $0.updateTab(tab.id) { $0.pinnedURL = url } }
                },
                Menu.item("Go Back to Pinned Page", isEnabled: tab.pinnedURL != nil) {
                    guard let url = tab.pinnedURL else { return }
                    live?.load(url)
                },
            ]),
            Menu.item("Open in Split View", isEnabled: state.selectedTabID != nil && state.selectedTabID != tab.id) { [weak self] in
                self?.window.openInSplitView(tab.id)
            },
            Menu.item("Duplicate") { [weak self] in self?.window.duplicateTab(tab.id) },
            Menu.submenu("Move to", moveMenu(for: tab.id)),
            Menu.separator(),
            Menu.item("Remove Favorite") { [weak self] in
                guard let self else { return }
                store.update { _ = $0.move(tab.id, to: SidebarLocation(spaceID: state.selectedSpaceID, section: .pinned)) }
            },
        ])
    }

    /// Arc's menu of a folder ("List Context Menu").
    private func folderMenu(for folder: ArrowKit.Folder) -> MenuFlyout {
        if LiveFolders.shared.isLive(folder.id) { return liveFolderMenu(for: folder) }
        return Menu.flyout([
            Menu.title("List Context Menu"),
            Menu.item("New Nested Folder…") { [weak self] in self?.window.newFolder(in: folder.id) },
            Menu.item("Turn “\(folder.title)” into Space") { [weak self] in self?.window.turnIntoSpace(folder) },
            Menu.item("Copy All Links", isEnabled: !folder.children.allTabs.isEmpty) { [weak self] in
                self?.store.platform.copyToClipboard(folder.children.allTabs.map(\.url).joined(separator: "\n"))
            },
            Menu.separator(),
            Menu.item("Rename…") { [weak self] in self?.window.rename(folder.id) },
            Menu.separator(),
            Menu.item("Duplicate") { [weak self] in self?.window.duplicateFolder(folder) },
            Menu.submenu("Move to", moveMenu(for: folder.id)),
            Menu.separator(),
            Menu.item("Delete") { [weak self] in self?.store.update { _ = $0.delete(folder.id) } },
        ])
    }

    /// Arc's menu of the space (its name, or the sidebar's empty part).
    private func spaceMenu() -> MenuFlyout? {
        guard let space = store.state.space(state.selectedSpaceID) else { return nil }
        return Menu.flyout([
            Menu.title("Space Context Menu"),
            Menu.item("Change Space Icon…") { [weak self] in self?.window.editIcon(of: space.id) },
            Menu.item("Rename Space…") { [weak self] in self?.window.rename(space.id) },
            Menu.item("Edit Theme Color…") { [weak self] in self?.window.editTheme(of: space.id) },
            Menu.submenu("Set Profile", store.state.profiles.map { profile in
                Menu.toggle(profile.name, isOn: profile.id == space.profileID) { [weak self] in
                    self?.store.update { $0.updateSpace(space.id) { $0.profileID = profile.id } }
                }
            } + [
                Menu.separator(),
                Menu.item("New Profile…") { [weak self] in self?.window.newProfile(for: space.id) },
            ]),
            Menu.separator(),
            Menu.item("New Folder") { [weak self] in self?.window.newFolder() },
            Menu.submenu("Live Folders", [
                Menu.item("GitHub") { [weak self] in self?.window.addGitHubLiveFolder() },
            ]),
            Menu.separator(),
            Menu.item("Delete Space", isEnabled: store.state.spaces.count > 1) { [weak self] in
                self?.window.deleteSpace(space.id)
            },
        ])
    }

    /// Arc's menu of a live folder: the repositories of its pull requests,
    /// each shown or hidden.
    private func liveFolderMenu(for folder: ArrowKit.Folder) -> MenuFlyout {
        let liveFolders = LiveFolders.shared
        let repositories = liveFolders.repositories(of: folder.id)
        let tabs = folder.children.allTabs
        var entries: [Menu.Entry] = [Menu.title("Live Folder Context Menu")]
        for repository in repositories {
            entries.append(Menu.toggle(repository, isOn: liveFolders.isShown(repository, in: folder.id)) {
                liveFolders.toggle(repository, in: folder.id)
            })
        }
        if !repositories.isEmpty { entries.append(Menu.title(LiveFolders.repositoriesText)) }
        entries += [
            Menu.separator(),
            Menu.item("Copy All Links as Markdown", isEnabled: !tabs.isEmpty) { [weak self] in
                let links = tabs.map { "[\($0.displayTitle)](\($0.url))" }
                self?.store.platform.copyToClipboard(links.joined(separator: "\n"))
            },
            Menu.separator(),
            Menu.item("Delete Live Folder") { [weak self] in self?.window.deleteLiveFolder(folder) },
        ]
        return Menu.flyout(entries)
    }

    /// The spaces a tab or folder can move to.
    private func moveMenu(for nodeID: Foundation.UUID) -> [Menu.Entry] {
        store.state.spaces.filter { $0.id != state.selectedSpaceID }.map { space in
            Menu.item(space.title) { [weak self] in
                self?.store.update { _ = $0.move(nodeID, to: SidebarLocation(spaceID: space.id, section: .today)) }
            }
        } + [
            Menu.separator(),
            Menu.item("New Space…") { [weak self] in self?.window.newSpace(moving: nodeID) },
        ]
    }

    // MARK: - Drag and drop

    /// The node being dragged in a sidebar.
    private static var draggedNodeID: Foundation.UUID?

    /// Starts dragging `element` as `nodeID` once the pressed pointer moves
    /// away: its button keeps the pointer, so WinUI would not.
    private func makeDraggable(_ element: UIElement, nodeID: Foundation.UUID) {
        var origin: Point?
        element.canDrag = true
        element.pointerMoved.addHandler { sender, event in
            // The sender, not the element: its Swift object can be gone.
            guard let element = sender as? UIElement, let event,
                  let point = try? event.getCurrentPoint(element) else { return }
            guard point.properties.isLeftButtonPressed else {
                origin = nil
                return
            }
            guard let start = origin else {
                origin = point.position
                return
            }
            let distance = hypot(Double(point.position.x - start.x), Double(point.position.y - start.y))
            guard distance > 6 else { return }
            origin = nil
            Sidebar.draggedNodeID = nodeID
            // The button lets go of the pointer, which the drag takes.
            try? element.releasePointerCaptures()
            _ = try? element.startDragAsync(point)
        }
        element.dropCompleted.addHandler { _, _ in Sidebar.draggedNodeID = nil }
    }

    /// Moves the dragged node to `location` when dropped on `element`.
    private func makeDropTarget(_ element: UIElement, location: @escaping () -> SidebarLocation) {
        element.allowDrop = true
        element.dragOver.addHandler { _, event in
            guard let event, Sidebar.draggedNodeID != nil else { return }
            event.acceptedOperation = .move
            event.handled = true
        }
        element.drop.addHandler { [weak self] _, event in
            guard let self, let nodeID = Sidebar.draggedNodeID else { return }
            event?.handled = true
            Sidebar.draggedNodeID = nil
            let destination = location()
            store.update { _ = $0.move(nodeID, to: destination) }
        }
    }

    // MARK: - Helpers

    private func title(of tab: Tab) -> String {
        tab.customTitle.flatMap { $0.isEmpty ? nil : $0 } ?? store.tabs[tab.id]?.displayTitle ?? store.title(of: tab)
    }

    /// Arc's closed folder (18 x 16): a tab over a rounded body, outlined
    /// in the folder color, light inside.
    private func closedFolderIcon() -> FrameworkElement {
        let icon = Canvas()
        icon.width = 18
        icon.height = 16
        icon.verticalAlignment = .center
        let tab = Rectangle()
        tab.width = 8
        tab.height = 5
        tab.radiusX = 1.5
        tab.radiusY = 1.5
        tab.fill = brushes.folder
        let body = Rectangle()
        body.width = 18
        body.height = 13
        body.radiusX = 2.5
        body.radiusY = 2.5
        body.stroke = brushes.folder
        body.strokeThickness = 2
        body.fill = brushes.folderFill
        try? Canvas.setTop(body, 3)
        icon.children.append(tab)
        icon.children.append(body)
        return icon
    }

    private func favicon(for tab: Tab) -> FrameworkElement {
        guard let favicon = store.tabs[tab.id]?.favicon ?? FaviconCache.shared.image(for: tab.url) else {
            // A page never visited (a favorite, a pinned page) shows its
            // favicon too, as in Arc: fetched once.
            if requestedFavicons.insert(tab.url).inserted {
                let url = tab.url
                Task { [weak self] in
                    guard await FaviconCache.shared.fetch(for: url) != nil else { return }
                    self?.update()
                }
            }
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

    private static func barButton(_ glyph: String, name: String) -> Button {
        let button = Button()
        button.content = Glyph.view(glyph, size: 14)
        button.width = 27
        button.height = 27
        button.padding = Thickness()
        button.cornerRadius = CornerRadius(6)
        button.verticalAlignment = .center
        try? AutomationProperties.setName(button, name)
        try? ToolTipService.setToolTip(button, name)
        return button
    }
}

extension CornerRadius {
    init(_ radius: Double) {
        self.init(topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius)
    }
}
