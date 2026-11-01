import ArrowCore
import ArrowKit
import Foundation
import UWP
import WinAppSDK
import WindowsFoundation
import WinSDK
import WinUI

/// Arc's settings on Windows: one window of sections (Account, Profiles,
/// Sync, General, Advanced, then Arrow's Extensions, the Card and Max), each
/// a column of Windows 11 cards, over Mica.
@MainActor
final class SettingsWindow {
    enum Section: String {
        case account, profiles, general, extensions, max, advanced
    }

    private static var shared: SettingsWindow?

    private let store: BrowserStore
    private let window = Window()
    private let sections = StackPanel()
    private let scroller = ScrollViewer()
    private var anchors: [Section: FrameworkElement] = [:]
    private var isDark: Bool

    /// Shows the settings window, at `section`.
    static func show(section: Section? = nil) {
        guard let store = ArrowApp.store else { return }
        let settings = shared ?? SettingsWindow(store: store)
        shared = settings
        try? settings.window.activate()
        if let section { settings.scroll(to: section) }
    }

    private init(store: BrowserStore) {
        self.store = store
        isDark = store.platform.isDarkAppearance
        window.title = "Arrow Settings"
        window.extendsContentIntoTitleBar = true
        window.systemBackdrop = MicaBackdrop()
        try? window.appWindow.resize(SizeInt32(width: 700, height: 600))
        window.setArrowIcon()
        // Arc's settings window has only the close button.
        if let handle = try? window.handle() {
            let style = GetWindowLongPtrW(handle, GWL_STYLE)
            SetWindowLongPtrW(handle, GWL_STYLE, style & ~LONG_PTR(WS_MINIMIZEBOX | WS_MAXIMIZEBOX))
        }
        // Arc's spacing: 16 pixels before a heading, 8 after it (4 before
        // its description, 16 after that), 4 between cards.
        sections.padding = Thickness(left: 36, top: 36, right: 36, bottom: 36)
        sections.spacing = 4
        sections.maxWidth = 700
        scroller.content = sections
        let root = Grid()
        root.requestedTheme = isDark ? .dark : .light
        root.children.append(scroller)
        window.content = root
        window.closed.addHandler { _, _ in SettingsWindow.shared = nil }
        observe { [weak self] in self?.rebuild() }
    }

    private func scroll(to section: Section) {
        guard let anchor = anchors[section],
              let origin = try? anchor.transformToVisual(sections).transformPoint(Point(x: 0, y: 0)) else { return }
        _ = try? scroller.changeView(nil, Double(origin.y) - 12, nil)
    }

    private func rebuild() {
        let settings = store.settings
        let cloud = store.cloud
        sections.children.clear()
        anchors = [:]

        // Account
        heading("Account", .account)
        if cloud.isSignedIn, let user = cloud.user {
            card(user.displayName, user.email, trailing: button("Sign Out") { Task { await cloud.signOut() } })
        } else {
            card("Arrow Cloud", "Sign in to sync your sidebar across your computers.",
                 trailing: button("Sign In") { [weak self] in self?.showSignIn() })
        }

        // Profiles
        heading("Profiles", .profiles)
        text("Profiles help keep your data separate across Spaces — like history, logins, cookies, and extensions. "
             + "You can use any profile across one or more Spaces.")
        card("Add a new Profile", nil, trailing: button("New Profile", isAccent: true) { [weak self] in
            guard let self else { return }
            let name = "Profile \(store.state.profiles.count + 1)"
            store.update { _ = $0.createProfile(name: name) }
        })
        for profile in store.state.profiles {
            let spaces = store.state.spaces.filter { $0.profileID == profile.id }.map(\.title)
            let detail = spaces.isEmpty ? "Not used by any Space"
                : "This Profile is used by your \(spaces.joined(separator: ", ")) Space\(spaces.count > 1 ? "s" : "")"
            let delete = button("Delete") { [weak self] in self?.store.update { $0.deleteProfile(profile.id) } }
            delete.isEnabled = !profile.isDefault && spaces.isEmpty
            card(profile.name, detail, trailing: delete)
        }

        // Sync
        heading("Arrow Sync", nil)
        text("Arrow Sync is end-to-end encrypted, only you can see your data.")
        card("Sidebar Sync", settings.syncEnabled ? "Sync enabled" : "Sync disabled", icon: Glyph.sync,
             trailing: toggle(settings.syncEnabled) { [weak self] in self?.store.settings.syncEnabled = $0 })

        // General
        heading("General", .general)
        card("Window backdrop", "Mica to match Arrow's background to your desktop, or Acrylic for a transparent blur effect.",
             trailing: choice(WindowBackdrop.allCases.map(\.rawValue),
                              selected: WindowBackdrop.allCases.firstIndex(of: WindowBackdrop.current) ?? 0) { index in
            WindowBackdrop.current = WindowBackdrop.allCases[index]
            ArrowApp.applyBackdrop()
        })
        card("Search engine", "Used by the Command Bar.", trailing: choice(SearchEngine.allCases.map(\.name),
             selected: SearchEngine.allCases.firstIndex(of: settings.searchEngine) ?? 0) { [weak self] index in
            self?.store.settings.searchEngine = SearchEngine.allCases[index]
        })
        card("Archive tabs after", "Today tabs not used for this long are archived.",
             trailing: choice(ArchiveInterval.allCases.map(\.title),
                              selected: ArchiveInterval.allCases.firstIndex(of: settings.archiveInterval) ?? 0) { [weak self] index in
            self?.store.settings.archiveInterval = ArchiveInterval.allCases[index]
        })
        card("Open a Peek window when clicking on links with Shift held", nil,
             trailing: toggle(settings.peekOnShiftClick) { [weak self] in self?.store.settings.peekOnShiftClick = $0 })
        card("Open a Peek window when clicking on links to other sites", "This only affects Favorites and Pinned tabs.",
             trailing: toggle(settings.peekEnabled) { [weak self] in self?.store.settings.peekEnabled = $0 })
        card("Automatic Picture-in-Picture", "Videos keep playing when you switch tabs.",
             trailing: toggle(settings.automaticPictureInPicture) { [weak self] in
                 self?.store.settings.automaticPictureInPicture = $0
             })
        card("Open links from other apps in", "Little Arrow, or a new tab of your current Space.",
             trailing: choice(["Little Arrow", "Current Space"],
                              selected: settings.externalLinks == .littleArrow ? 0 : 1) { [weak self] index in
            self?.store.settings.externalLinks = index == 0 ? .littleArrow : .activeSpace
        })
        card("Block ads and trackers", nil,
             trailing: toggle(settings.adBlockerEnabled) { [weak self] in self?.store.settings.adBlockerEnabled = $0 })
        card("Search suggestions", nil,
             trailing: toggle(settings.searchSuggestions) { [weak self] in self?.store.settings.searchSuggestions = $0 })
        card("Sound effects", nil,
             trailing: toggle(settings.soundEffects) { [weak self] in self?.store.settings.soundEffects = $0 })

        // Advanced
        heading("Advanced", .advanced)
        card("Export Spaces and tabs", "A zip archive of Arrow's data, in your Downloads folder.",
             trailing: button("Export Data") { [weak self] in self?.exportData() })
        card("Developer mode", "Shows full addresses and developer tools in menus.",
             trailing: toggle(settings.developerMode) { [weak self] in self?.store.settings.developerMode = $0 })

        // Extensions
        heading("Extensions", .extensions)
        let extensions = ExtensionManager.shared.extensions
        if extensions.isEmpty {
            card("No extensions yet", "Add extensions from the Chrome Web Store.",
                 trailing: button("Chrome Web Store") { ArrowApp.openInFrontWindow("https://chromewebstore.google.com") })
        }
        for installed in extensions {
            let controls = StackPanel()
            controls.orientation = .horizontal
            controls.spacing = 8
            controls.children.append(toggle(installed.isEnabled) { ExtensionManager.shared.setEnabled(installed.id, $0) })
            controls.children.append(button("Remove") { ExtensionManager.shared.remove(installed.id) })
            card(installed.name, "Version \(installed.version)", trailing: controls)
        }

        // Card
        heading("Arrow Card", nil)
        text("Here's your Arrow Card. Show it off to the world or keep it to yourself.")
        sections.children.append(arrowCard())

        // Max
        heading("Arrow Max", .max)
        text("Let Arrow do more for you with Max. Max features send data to your Arrow Cloud server's AI partner.")
        card("Enable Max", nil, trailing: toggle(settings.aiEnabled) { [weak self] in self?.store.settings.aiEnabled = $0 })
        card("Tidy Tabs", "Press the 'Tidy' button to let your Sidebar organize itself whenever you have more than six Today Tabs.",
             trailing: toggle(settings.tidyTabs) { [weak self] in self?.store.settings.tidyTabs = $0 })
        let future = CheckBox()
        future.content = "Automatically enable future Arrow Max features"
        future.isChecked = settings.autoEnableNewMaxFeatures
        future.click.addHandler { [weak self] _, _ in self?.store.settings.autoEnableNewMaxFeatures = future.isChecked == true }
        sections.children.append(future)

    }

    /// Arc's card: the user's name, a title earned by browsing, and the day
    /// they started, over their space's colors.
    private func arrowCard() -> UIElement {
        let visits = store.history.entries.values.reduce(0) { $0 + $1.visitCount }
        let rank = switch visits {
        case ..<100: "CURIOUS EXPLORER"
        case ..<1000: "AVID SURFER"
        default: "MIGHTY READER"
        }
        let created = (try? FileManager.default.attributesOfItem(atPath: store.dataDirectory.path)[.creationDate]) as? Date
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        let name = store.cloud.user?.displayName ?? ProcessInfo.processInfo.environment["USERNAME"] ?? "Arrow"
        let theme = store.state.spaces.first?.theme ?? .lavender
        let background = LinearGradientBrush()
        background.startPoint = Point(x: 0, y: 0)
        background.endPoint = Point(x: 1, y: 1)
        let colors = theme.colors.count == 1 ? [theme.colors[0], theme.colors[0]] : theme.colors
        for (index, color) in colors.enumerated() {
            let stop = GradientStop()
            stop.color = Color(color)
            stop.offset = Double(index) / Double(colors.count - 1)
            background.gradientStops.append(stop)
        }
        let card = Grid()
        card.width = 340
        card.height = 200
        card.horizontalAlignment = .left
        card.cornerRadius = CornerRadius(16)
        card.padding = Thickness(left: 22, top: 20, right: 22, bottom: 18)
        card.background = background
        card.requestedTheme = .dark
        for height in [GridLength.auto, .star, .auto] {
            let row = RowDefinition()
            row.height = height
            card.rowDefinitions.append(row)
        }
        let brand = TextBlock()
        brand.text = "ARROW"
        brand.fontSize = 13
        brand.fontWeight = FontWeight(weight: 700)
        brand.horizontalAlignment = .right
        card.children.append(brand)
        let holder = TextBlock()
        holder.text = name
        holder.fontSize = 24
        holder.fontWeight = FontWeight(weight: 600)
        holder.verticalAlignment = .center
        holder.textTrimming = .characterEllipsis
        try? Grid.setRow(holder, 1)
        card.children.append(holder)
        let footer = Grid()
        for width in [GridLength.star, .auto] {
            let column = ColumnDefinition()
            column.width = width
            footer.columnDefinitions.append(column)
        }
        let title = TextBlock()
        title.text = rank
        title.fontSize = 12
        title.fontWeight = FontWeight(weight: 700)
        footer.children.append(title)
        let since = TextBlock()
        since.text = created.map { formatter.string(from: $0) } ?? ""
        since.fontSize = 12
        try? Grid.setColumn(since, 1)
        footer.children.append(since)
        try? Grid.setRow(footer, 2)
        card.children.append(footer)
        try? AutomationProperties.setName(card, "Arrow Card")
        return card
    }

    // MARK: - Actions

    private func showSignIn() {
        let email = TextBox()
        email.header = "Email"
        let password = PasswordBox()
        password.header = "Password"
        let server = TextBox()
        server.header = "Server URL"
        server.text = store.settings.cloudServerURL
        let message = TextBlock()
        message.textWrapping = .wrap
        let form = StackPanel()
        form.spacing = 12
        for element: UIElement in [email, password, server, message] {
            form.children.append(element)
        }
        let dialog = ContentDialog()
        dialog.xamlRoot = window.content.xamlRoot
        dialog.title = "Sign In to Arrow Cloud"
        dialog.content = form
        dialog.primaryButtonText = "Sign In"
        dialog.closeButtonText = "Cancel"
        dialog.requestedTheme = isDark ? .dark : .light
        dialog.primaryButtonClick.addHandler { [weak self] _, event in
            guard let self, let event else { return }
            event.cancel = true
            store.settings.cloudServerURL = server.text
            let deferral = try? event.getDeferral()
            Task {
                do {
                    try await self.store.cloud.signIn(email: email.text, password: password.password)
                    try? dialog.hide()
                } catch {
                    message.text = error.localizedDescription
                }
                try? deferral?.complete()
            }
        }
        _ = try? dialog.showAsync()
    }

    /// Zips Arrow's data into the Downloads folder (bsdtar ships with Windows).
    private func exportData() {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let destination = downloads.appendingPathComponent("Arrow Data.zip")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\tar.exe")
        tar.arguments = ["-a", "-c", "-f", destination.nativePath, "-C", store.dataDirectory.nativePath, "."]
        tar.terminationHandler = { process in
            Task { @MainActor in
                if process.terminationStatus == 0 { ArrowApp.store?.platform.reveal(destination) }
            }
        }
        try? tar.run()
    }

    // MARK: - Building blocks

    private func heading(_ title: String, _ section: Section?) {
        let text = TextBlock()
        text.text = title
        text.fontSize = 20
        text.fontWeight = FontWeight(weight: 600)
        text.margin = Thickness(left: 0, top: sections.children.size == 0 ? 0 : 12, right: 0, bottom: 4)
        sections.children.append(text)
        if let section { anchors[section] = text }
    }

    /// A heading's description.
    private func text(_ string: String) {
        let text = TextBlock()
        text.text = string
        text.fontSize = 12
        text.textWrapping = .wrap
        text.margin = Thickness(left: 0, top: -4, right: 0, bottom: 12)
        sections.children.append(text)
    }

    /// A Windows 11 settings card: an icon, a title, a description, a
    /// control.
    private func card(_ title: String, _ detail: String?, icon: String? = nil, trailing: UIElement) {
        let card = Grid()
        card.padding = Thickness(left: 24, top: 14, right: 16, bottom: 14)
        card.minHeight = 66
        card.cornerRadius = CornerRadius(4)
        card.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        card.borderBrush = SolidColorBrush(Color((isDark ? RGBColor.black : .black).withAlpha(isDark ? 0.3 : 0.06)))
        card.background = SolidColorBrush(Color(isDark ? RGBColor.white.withAlpha(0.05) : RGBColor.white.withAlpha(0.7)))
        card.columnSpacing = 16
        for width in [GridLength.star, .auto] {
            let column = ColumnDefinition()
            column.width = width
            card.columnDefinitions.append(column)
        }
        let labels = StackPanel()
        labels.verticalAlignment = .center
        let heading = TextBlock()
        heading.text = title
        heading.fontSize = 14
        heading.textWrapping = .wrap
        labels.children.append(heading)
        if let detail {
            let text = TextBlock()
            text.text = detail
            text.fontSize = 12
            text.opacity = 0.7
            text.textWrapping = .wrap
            labels.children.append(text)
        }
        if let icon {
            let header = StackPanel()
            header.orientation = .horizontal
            header.spacing = 14
            let glyph = Glyph.view(icon, size: 18)
            glyph.width = 20
            glyph.verticalAlignment = .center
            header.children.append(glyph)
            header.children.append(labels)
            card.children.append(header)
        } else {
            card.children.append(labels)
        }
        if let element = trailing as? FrameworkElement { element.verticalAlignment = .center }
        try? Grid.setColumn(trailing as? FrameworkElement, 1)
        card.children.append(trailing)
        sections.children.append(card)
    }

    private func button(_ title: String, isAccent: Bool = false, action: @escaping () -> Void) -> Button {
        let button = Button()
        button.content = title
        if isAccent, let style = try? Application.current.resources.lookup("AccentButtonStyle") as? Style {
            button.style = style
        }
        button.click.addHandler { _, _ in action() }
        return button
    }

    /// Arc's switch: "On" or "Off" (in English, not the system's language)
    /// before it, at the card's right.
    private func toggle(_ isOn: Bool, action: @escaping (Bool) -> Void) -> UIElement {
        let label = TextBlock()
        label.text = isOn ? "On" : "Off"
        label.fontSize = 14
        label.verticalAlignment = .center
        let toggle = ToggleSwitch()
        toggle.minWidth = 0
        // The switch's own text goes before it: none after.
        toggle.onContent = Border()
        toggle.offContent = Border()
        toggle.isOn = isOn
        toggle.toggled.addHandler { _, _ in
            label.text = toggle.isOn ? "On" : "Off"
            action(toggle.isOn)
        }
        let control = StackPanel()
        control.orientation = .horizontal
        control.spacing = 12
        control.children.append(label)
        control.children.append(toggle)
        return control
    }

    private func choice(_ titles: [String], selected: Int, action: @escaping (Int) -> Void) -> ComboBox {
        let combo = ComboBox()
        for title in titles {
            combo.items.append(title)
        }
        combo.selectedIndex = Int32(selected)
        // As wide as the choice, as Arc's.
        combo.minWidth = 0
        combo.selectionChanged.addHandler { _, _ in
            let index = Int(combo.selectedIndex)
            if index >= 0 { action(index) }
        }
        return combo
    }
}
