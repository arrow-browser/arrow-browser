import ArrowCore
import ArrowKit
import Foundation
import UWP
import WindowsFoundation
import WinUI

/// The archive, the task manager and importing from other browsers.
extension BrowserWindow {
    // MARK: - Archive

    /// Arc's archive, over the sidebar's archive button: the tabs archived
    /// last, which reopen on a click.
    func showArchive() {
        let flyout = Flyout()
        flyout.shouldConstrainToRootBounds = false
        flyout.placement = .topEdgeAlignedLeft
        let archive = store.state.archive
        let content = StackPanel()
        content.width = 260
        if archive.isEmpty {
            content.spacing = 6
            content.padding = Thickness(left: 4, top: 4, right: 4, bottom: 4)
            let icon = Glyph.view(Glyph.archive, size: 20)
            let title = TextBlock()
            title.text = "Nothing here yet!"
            title.fontSize = 15
            title.horizontalAlignment = .center
            let text = TextBlock()
            text.text = "Hover your mouse over a tab and press the X to archive it."
            text.textWrapping = .wrap
            text.fontSize = 13
            text.opacity = 0.75
            text.margin = Thickness(left: 14, top: 0, right: 14, bottom: 0)
            for element: UIElement in [icon, title, text] {
                content.children.append(element)
            }
        } else {
            let heading = TextBlock()
            heading.text = "Archived Tabs"
            heading.fontSize = 13
            heading.fontWeight = FontWeight(weight: 600)
            heading.margin = Thickness(left: 8, top: 0, right: 0, bottom: 6)
            content.children.append(heading)
            let rows = StackPanel()
            rows.spacing = 2
            for entry in archive.prefix(50) {
                rows.children.append(archiveRow(entry) { [weak self] in
                    try? flyout.hide()
                    self?.restoreArchived(entry.id)
                })
            }
            let scroller = ScrollViewer()
            scroller.maxHeight = 420
            scroller.content = rows
            content.children.append(scroller)
        }
        flyout.content = content
        try? flyout.showAt(sidebar.archiveAnchor)
    }

    private func archiveRow(_ entry: ArchivedTab, open: @escaping () -> Void) -> Button {
        let icon: FrameworkElement
        if let favicon = FaviconCache.shared.image(for: entry.tab.url) {
            let image = Image()
            image.source = favicon.bitmap
            image.width = 16
            image.height = 16
            icon = image
        } else {
            icon = Glyph.view(Glyph.globe)
        }
        let title = TextBlock()
        title.text = store.title(of: entry.tab)
        title.fontSize = 13
        title.textTrimming = .characterEllipsis
        let when = TextBlock()
        when.text = Self.archiveDate(entry.archivedAt)
        when.fontSize = 11
        when.opacity = 0.6
        let content = Grid()
        content.columnSpacing = 10
        for width in [GridLength.auto, .star, .auto] {
            let column = ColumnDefinition()
            column.width = width
            content.columnDefinitions.append(column)
        }
        content.children.append(icon)
        try? Grid.setColumn(title, 1)
        content.children.append(title)
        try? Grid.setColumn(when, 2)
        when.verticalAlignment = .center
        content.children.append(when)
        let row = Button()
        row.content = content
        row.height = 34
        row.horizontalAlignment = .stretch
        row.horizontalContentAlignment = .stretch
        row.background = brushes.clear
        row.borderThickness = Thickness()
        row.cornerRadius = CornerRadius(6)
        try? AutomationProperties.setName(row, title.text)
        try? ToolTipService.setToolTip(row, entry.tab.url)
        row.click.addHandler { _, _ in open() }
        return row
    }

    private static func archiveDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    func restoreArchived(_ tabID: Foundation.UUID) {
        var restored: (tab: Tab, spaceID: Foundation.UUID)?
        store.update { restored = $0.restoreArchived(tabID, into: state.selectedSpaceID) }
        if let restored { select(restored.tab.id) }
    }

    // MARK: - Capture and boosts

    /// Saves an image of the page in the Downloads folder.
    func capture(_ tab: WebTab) {
        guard let engine = tab.engine else { return }
        Task {
            guard let data = await engine.captureScreenshot() else { return }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                .appendingPathComponent("Arrow Capture \(formatter.string(from: Date())).png")
            guard (try? data.write(to: file)) != nil else { return }
            store.playSound(.event)
            state.showToast("Capture saved to Downloads")
        }
    }

    /// The site's boost: its custom CSS, on or off.
    func editBoost(for tab: WebTab) {
        guard let host = URLDisplay.host(of: tab.url) else { return }
        let domain = host.replacingOccurrences(of: "www.", with: "")
        var boost = store.boosts.first { $0.domain == domain } ?? Boost(name: domain, domain: domain)
        let enabled = ToggleSwitch()
        enabled.header = "Boost \(domain)"
        enabled.onContent = "On"
        enabled.offContent = "Off"
        enabled.isOn = boost.isEnabled
        let css = TextBox()
        css.header = "CSS"
        css.text = boost.css
        css.acceptsReturn = true
        css.textWrapping = .wrap
        css.height = 180
        css.fontFamily = FontFamily("Cascadia Mono, Consolas")
        css.placeholderText = "body { font-size: 18px; }"
        let content = StackPanel()
        content.spacing = 12
        content.children.append(enabled)
        content.children.append(css)
        Sheet(window: self, title: "Boost This Site", content: content, width: 480, actions: [
            Sheet.Action(title: "Save", isPrimary: true) { [weak self] in
                boost.isEnabled = enabled.isOn
                boost.css = css.text
                self?.store.saveBoost(boost)
                return true
            },
            Sheet.Action(title: "Cancel"),
        ]).show(focusing: css)
    }

    // MARK: - Task manager

    /// Arc's task manager: the open tabs, each of which can be closed.
    func showTaskManager() {
        let rows = StackPanel()
        rows.spacing = 4
        let tabs = store.tabs.values.filter { $0.engine != nil }.sorted { $0.displayTitle < $1.displayTitle }
        var sheet: Sheet?
        for tab in tabs {
            let row = Grid()
            row.columnSpacing = 8
            for width in [GridLength.star, .auto] {
                let column = ColumnDefinition()
                column.width = width
                row.columnDefinitions.append(column)
            }
            let title = TextBlock()
            title.text = tab.displayTitle
            title.textTrimming = .characterEllipsis
            title.verticalAlignment = .center
            row.children.append(title)
            let end = Button()
            end.content = "End"
            try? Grid.setColumn(end, 1)
            row.children.append(end)
            let id = tab.id
            end.click.addHandler { [weak self] _, _ in
                self?.store.discardRuntime(id)
                sheet?.close()
                self?.showTaskManager()
            }
            rows.children.append(row)
        }
        if tabs.isEmpty {
            let empty = TextBlock()
            empty.text = "No page is running."
            rows.children.append(empty)
        }
        let scroller = ScrollViewer()
        scroller.maxHeight = 360
        scroller.content = rows
        sheet = Sheet(window: self, title: "Task Manager", content: scroller, width: 480,
                      actions: [Sheet.Action(title: "Close", isPrimary: true)])
        sheet?.show()
    }

    // MARK: - Import

    /// Chromium browsers whose bookmarks can be imported, under
    /// %LOCALAPPDATA%.
    static let importableBrowsers: [(name: String, directory: String)] = [
        ("Google Chrome", "Google\\Chrome\\User Data"),
        ("Microsoft Edge", "Microsoft\\Edge\\User Data"),
        ("Brave", "BraveSoftware\\Brave-Browser\\User Data"),
        ("Vivaldi", "Vivaldi\\User Data"),
        ("Chromium", "Chromium\\User Data"),
    ]

    /// Imports another browser's bookmarks as a pinned folder.
    func importFromBrowser() {
        let localAppData = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? ""
        let available = Self.importableBrowsers.filter { browser in
            FileManager.default.fileExists(atPath: "\(localAppData)\\\(browser.directory)\\Default\\Bookmarks")
        }
        let content = StackPanel()
        content.spacing = 8
        let text = TextBlock()
        text.textWrapping = .wrap
        content.children.append(text)
        guard !available.isEmpty else {
            text.text = "No browser with bookmarks was found on this PC."
            Sheet(window: self, title: "Import from Another Browser", content: content,
                  actions: [Sheet.Action(title: "Close", isPrimary: true)]).show()
            return
        }
        text.text = "Bookmarks are added to your space as a pinned folder."
        var choice = available[0]
        for browser in available {
            let radio = RadioButton()
            radio.content = browser.name
            radio.groupName = "browser"
            radio.isChecked = browser.name == choice.name
            radio.checked.addHandler { _, _ in choice = browser }
            content.children.append(radio)
        }
        Sheet(window: self, title: "Import from Another Browser", content: content, actions: [
            Sheet.Action(title: "Import", isPrimary: true) { [weak self] in
                guard let self else { return true }
                let path = "\(localAppData)\\\(choice.directory)\\Default\\Bookmarks"
                let count = importChromiumBookmarks(at: URL(fileURLWithPath: path), name: choice.name)
                showMessage("Import from \(choice.name)", count > 0 ? "\(count) bookmarks imported." : "No bookmarks found.")
                return true
            },
            Sheet.Action(title: "Cancel"),
        ]).show()
    }

    /// Adds a Chromium browser's bookmarks bar and other bookmarks as a
    /// pinned folder of the current space: the number of bookmarks.
    func importChromiumBookmarks(at url: URL, name: String) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        let imported = Self.chromiumBookmarks(data)
        guard !imported.isEmpty else { return 0 }
        let spaceID = state.selectedSpaceID
        store.update { browser in
            guard let index = browser.spaceIndex(spaceID) else { return }
            browser.spaces[index].pinned.append(.folder(ArrowKit.Folder(title: "\(name) Bookmarks", isExpanded: false,
                                                                         children: imported)))
        }
        return imported.allTabs.count
    }

    /// A Chromium `Bookmarks` file's bookmarks bar and other bookmarks, as
    /// pinned tabs and folders (web addresses only).
    static func chromiumBookmarks(_ data: Data) -> [SidebarNode] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { return [] }
        func nodes(_ value: Any?) -> [SidebarNode] {
            let children = (value as? [String: Any])?["children"] as? [Any] ?? []
            return children.compactMap { $0 as? [String: Any] }.compactMap { item in
                switch item["type"] as? String {
                case "url":
                    guard let address = item["url"] as? String, address.hasPrefix("http") else { return nil }
                    return .tab(Tab(url: address, title: item["name"] as? String ?? "", pinnedURL: address))
                case "folder":
                    let children = nodes(item)
                    return children.isEmpty ? nil
                        : .folder(ArrowKit.Folder(title: item["name"] as? String ?? "Folder", isExpanded: false, children: children))
                default:
                    return nil
                }
            }
        }
        return nodes(roots["bookmark_bar"]) + nodes(roots["other"])
    }
}
