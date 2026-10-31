import ArrowCore
import ArrowKit
import Foundation
import UWP
import WindowsFoundation
import WinUI

/// Spaces and folders: creating them, their icon and theme, deleting them.
extension BrowserWindow {
    /// Emoji offered for a space's icon, as Arc's picker starts.
    static let spaceEmoji = ["🏠", "💼", "🎨", "📚", "🎮", "🎵", "✈️", "🛒", "💡", "🔬", "🧪", "📝", "🌍", "⭐️", "❤️", "🔥",
                             "🌱", "☕️", "🍿", "⚽️", "🐶", "🐱", "🚀", "🎓"]

    /// Asks for a new space's name, icon and color, then switches to it,
    /// with `nodeID` moved into it (Move to ▸ New Space…).
    func newSpace(moving nodeID: Foundation.UUID? = nil) {
        let name = TextBox()
        name.placeholderText = "Space name"
        let emoji = TextBox()
        emoji.placeholderText = "Icon (an emoji, optional)"
        var theme = SpaceTheme.presets[store.state.spaces.count % SpaceTheme.presets.count]
        let swatches = themeSwatches(selected: theme) { theme = $0 }
        let content = StackPanel()
        content.spacing = 12
        for element: UIElement in [name, emoji, swatches] {
            content.children.append(element)
        }
        let sheet = Sheet(window: self, title: "Create a Space", content: content, actions: [
            Sheet.Action(title: "Create Space", isPrimary: true) { [weak self] in
                guard let self else { return true }
                let title = name.text.trimmingCharacters(in: .whitespaces)
                let icon = emoji.text.trimmingCharacters(in: .whitespaces)
                // Read before the update, which has the state exclusively.
                let profileID = selectedSpace?.profileID
                var space: Space?
                store.update { browser in
                    let created = browser.createSpace(title: title.isEmpty ? "New Space" : title,
                                                      icon: icon.isEmpty ? nil : .emoji(icon), theme: theme,
                                                      profileID: profileID)
                    if let nodeID { _ = browser.move(nodeID, to: SidebarLocation(spaceID: created.id, section: .pinned)) }
                    space = created
                }
                if let space { selectSpace(space.id) }
                return true
            },
            Sheet.Action(title: "Cancel"),
        ])
        sheet.show(focusing: name)
    }

    /// Arc's Edit Theme Color: a preset or any color, light or dark, and
    /// its strength, applied while chosen.
    func editTheme(of spaceID: Foundation.UUID) {
        guard let space = store.state.space(spaceID) else { return }
        let original = space.theme
        var theme = space.theme
        let apply: (SpaceTheme) -> Void = { [weak self] new in
            theme = new
            self?.store.update { $0.updateSpace(spaceID) { $0.theme = new } }
        }
        let picker = ColorPicker()
        picker.color = Color(theme.primary)
        picker.isAlphaEnabled = false
        picker.isMoreButtonVisible = false
        picker.isColorSliderVisible = true
        picker.isColorChannelTextInputVisible = false
        picker.isHexInputVisible = true
        picker.colorChanged.addHandler { _, event in
            guard let color = event?.newColor else { return }
            let picked = RGBColor(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255)
            apply(SpaceTheme(primary: picked, harmony: theme.harmony, appearance: theme.appearance,
                             intensity: theme.intensity, grain: theme.grain))
        }
        let swatches = themeSwatches(selected: theme) { preset in
            picker.color = Color(preset.primary)
            apply(SpaceTheme(primary: preset.primary, harmony: preset.harmony, appearance: theme.appearance,
                             intensity: theme.intensity, grain: theme.grain))
        }
        let appearance = StackPanel()
        appearance.orientation = .horizontal
        appearance.spacing = 12
        for (title, value) in [("Light", ThemeAppearance.light), ("Dark", .dark), ("Auto", .automatic)] {
            let radio = RadioButton()
            radio.content = title
            radio.groupName = "appearance"
            radio.isChecked = theme.appearance == value
            radio.checked.addHandler { _, _ in
                var new = theme
                new.appearance = value
                apply(new)
            }
            appearance.children.append(radio)
        }
        let intensity = Slider()
        intensity.header = "Intensity"
        intensity.minimum = 0
        intensity.maximum = 100
        intensity.value = theme.intensity * 100
        intensity.valueChanged.addHandler { _, event in
            guard let event else { return }
            var new = theme
            new.intensity = event.newValue / 100
            apply(new)
        }
        let content = StackPanel()
        content.spacing = 12
        for element: UIElement in [swatches, picker, appearance, intensity] {
            content.children.append(element)
        }
        Sheet(window: self, title: "Edit Theme Color", content: content, width: 380, actions: [
            Sheet.Action(title: "Done", isPrimary: true),
            Sheet.Action(title: "Cancel") { [weak self] in
                self?.store.update { $0.updateSpace(spaceID) { $0.theme = original } }
                return true
            },
        ]).show()
    }

    /// Arc's Change Space Icon: an emoji, or none.
    func editIcon(of spaceID: Foundation.UUID) {
        let grid = Grid()
        grid.columnSpacing = 4
        grid.rowSpacing = 4
        let columns = 8
        for _ in 0..<columns {
            let column = ColumnDefinition()
            column.width = .star
            grid.columnDefinitions.append(column)
        }
        for _ in 0..<(Self.spaceEmoji.count + columns - 1) / columns {
            let row = RowDefinition()
            row.height = .auto
            grid.rowDefinitions.append(row)
        }
        var sheet: Sheet?
        for (index, emoji) in Self.spaceEmoji.enumerated() {
            let button = Button()
            button.content = emoji
            button.fontSize = 18
            button.horizontalAlignment = .stretch
            button.background = brushes.clear
            button.borderThickness = Thickness()
            try? Grid.setColumn(button, Int32(index % columns))
            try? Grid.setRow(button, Int32(index / columns))
            button.click.addHandler { [weak self] _, _ in
                self?.store.update { $0.updateSpace(spaceID) { $0.icon = .emoji(emoji) } }
                sheet?.close()
            }
            grid.children.append(button)
        }
        let custom = TextBox()
        custom.placeholderText = "Or type any emoji"
        let content = StackPanel()
        content.spacing = 12
        content.children.append(grid)
        content.children.append(custom)
        sheet = Sheet(window: self, title: "Change Space Icon", content: content, actions: [
            Sheet.Action(title: "Done", isPrimary: true) { [weak self] in
                let emoji = custom.text.trimmingCharacters(in: .whitespaces)
                if !emoji.isEmpty { self?.store.update { $0.updateSpace(spaceID) { $0.icon = .emoji(emoji) } } }
                return true
            },
            Sheet.Action(title: "No Icon") { [weak self] in
                self?.store.update { $0.updateSpace(spaceID) { $0.icon = nil } }
                return true
            },
        ])
        sheet?.show()
    }

    func deleteSpace(_ spaceID: Foundation.UUID) {
        guard let space = store.state.space(spaceID), store.state.spaces.count > 1 else { return }
        let text = TextBlock()
        text.text = "Its pinned tabs and folders are deleted, its today tabs archived."
        text.textWrapping = .wrap
        Sheet(window: self, title: "Delete “\(space.title)”?", content: text, actions: [
            Sheet.Action(title: "Delete Space", isPrimary: true) { [weak self] in
                guard let self else { return true }
                let next = store.state.spaces.first { $0.id != spaceID }?.id
                if let next { selectSpace(next) }
                store.update { $0.deleteSpace(spaceID) }
                return true
            },
            Sheet.Action(title: "Cancel"),
        ]).show()
    }

    // MARK: - Folders

    /// Arc's Live Folders ▸ GitHub: the space's GitHub Live Folder, pinned,
    /// filled with the pull requests of the user signed in to GitHub.
    func addGitHubLiveFolder() {
        LiveFolders.shared.addGitHub(in: state.selectedSpaceID)
    }

    /// Delete Live Folder, confirmed as Arc does.
    func deleteLiveFolder(_ folder: ArrowKit.Folder) {
        let text = TextBlock()
        text.text = "You can restore this folder at any time by right-clicking the sidebar."
        text.textWrapping = .wrap
        Sheet(window: self, title: "Delete your \(folder.title) Live Folder?", content: text, actions: [
            Sheet.Action(title: "Delete", isPrimary: true) {
                LiveFolders.shared.delete(folder.id)
                return true
            },
            Sheet.Action(title: "Cancel"),
        ]).show()
    }

    /// A new profile, used by `spaceID` (Set Profile ▸ New Profile…).
    func newProfile(for spaceID: Foundation.UUID) {
        let name = TextBox()
        name.placeholderText = "Profile name"
        Sheet(window: self, title: "New Profile", content: name, actions: [
            Sheet.Action(title: "Create Profile", isPrimary: true) { [weak self] in
                let title = name.text.trimmingCharacters(in: .whitespaces)
                guard let self, !title.isEmpty else { return false }
                store.update { browser in
                    let profile = browser.createProfile(name: title)
                    browser.updateSpace(spaceID) { $0.profileID = profile.id }
                }
                return true
            },
            Sheet.Action(title: "Cancel"),
        ]).show(focusing: name)
    }

    /// A folder inside `parentID`, renamed at once.
    func newFolder(in parentID: Foundation.UUID) {
        let spaceID = state.selectedSpaceID
        var folder: ArrowKit.Folder?
        store.update { browser in
            guard let created = browser.createFolder(in: spaceID) else { return }
            _ = browser.move(created.id, to: SidebarLocation(spaceID: spaceID, section: .pinned, folderID: parentID))
            browser.expandFolders(containing: created.id)
            folder = created
        }
        state.renamingNodeID = folder?.id
    }

    /// A space named after the folder, with its tabs pinned.
    func turnIntoSpace(_ folder: ArrowKit.Folder) {
        var space: Space?
        let theme = SpaceTheme.presets[store.state.spaces.count % SpaceTheme.presets.count]
        let profileID = selectedSpace?.profileID
        store.update { browser in
            let created = browser.createSpace(title: folder.title, theme: theme, profileID: profileID)
            for node in folder.children {
                _ = browser.move(node.id, to: SidebarLocation(spaceID: created.id, section: .pinned))
            }
            _ = browser.delete(folder.id)
            space = created
        }
        if let space { selectSpace(space.id) }
    }

    /// A copy of the folder with new tabs for its pages.
    func duplicateFolder(_ folder: ArrowKit.Folder) {
        let spaceID = state.selectedSpaceID
        store.update { browser in
            let ids = folder.children.allTabs.compactMap { tab in
                browser.openTab(url: tab.pinnedURL ?? tab.url, title: tab.title, in: spaceID)?.id
            }
            _ = browser.createFolder(in: spaceID, title: "\(folder.title) Copy", containing: ids)
        }
    }

    // MARK: - Helpers

    /// A row of theme presets as color dots, `selected` outlined.
    private func themeSwatches(selected: SpaceTheme, onPick: @escaping (SpaceTheme) -> Void) -> StackPanel {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 8
        var dots: [Border] = []
        for preset in SpaceTheme.presets {
            let dot = Border()
            dot.width = 28
            dot.height = 28
            dot.cornerRadius = CornerRadius(14)
            dot.background = SolidColorBrush(Color(preset.primary))
            dot.borderThickness = Thickness(left: 2, top: 2, right: 2, bottom: 2)
            dot.borderBrush = preset.primary == selected.primary ? brushes.title : brushes.clear
            dot.tapped.addHandler { [weak self] _, _ in
                for other in dots { other.borderBrush = self?.brushes.clear }
                dot.borderBrush = self?.brushes.title
                onPick(preset)
            }
            dots.append(dot)
            row.children.append(dot)
        }
        return row
    }
}
