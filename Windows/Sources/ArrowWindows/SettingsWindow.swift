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
    /// The profile whose page shows (Arc's "Profiles / Default"), if any.
    private var shownProfileID: Foundation.UUID?
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
        // Arc's settings open with the keyboard on none of their controls
        // (WinUI would frame the first button when opened from the
        // keyboard): this empty control takes it; Tab goes on to the page.
        let start = ContentControl()
        start.isTabStop = true
        start.useSystemFocusVisuals = false
        root.children.append(start)
        start.loaded.addHandler { _, _ in _ = try? start.focus(.programmatic) }
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
        sections.children.clear()
        anchors = [:]
        if let id = shownProfileID, let profile = store.state.profiles.first(where: { $0.id == id }) {
            buildProfilePage(profile)
        } else {
            buildMainPage()
        }
    }

    private func buildMainPage() {
        let settings = store.settings
        let cloud = store.cloud
        sections.spacing = 4

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
        // Arc's profile cards open the profile's page.
        for profile in store.state.profiles {
            let spaces = store.state.spaces.filter { $0.profileID == profile.id }.map(\.title)
            let detail = spaces.isEmpty ? "Not used by any Space"
                : "This Profile is used by your \(spaces.joined(separator: ", ")) Space\(spaces.count > 1 ? "s" : "")"
            let open = iconButton(Glyph.chevronRight, name: "Open \(profile.name)") { [weak self] in
                self?.showProfile(profile.id)
            }
            let card = card(profile.name, detail, trailing: open)
            card.tapped.addHandler { [weak self] _, _ in self?.showProfile(profile.id) }
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

    // MARK: - Profile page

    /// Arc's page of a profile: its search and related settings (Arrow's,
    /// shared by all profiles, as in the macOS app's Profiles pane), Clear
    /// Browsing Data and Delete. Arc's window grows to show it.
    private func showProfile(_ id: Foundation.UUID) {
        shownProfileID = id
        try? window.appWindow.resize(SizeInt32(width: 700, height: 800))
        rebuild()
        _ = try? scroller.changeView(nil, 0, nil)
    }

    private func showMainPage() {
        shownProfileID = nil
        try? window.appWindow.resize(SizeInt32(width: 700, height: 600))
        rebuild()
    }

    private func buildProfilePage(_ profile: Profile) {
        let settings = store.settings
        sections.spacing = 8

        // "← Profiles / Default", Rename Profile at the right.
        let header = Grid()
        for width in [GridLength.auto, .auto, .star, .auto] {
            let column = ColumnDefinition()
            column.width = width
            header.columnDefinitions.append(column)
        }
        // The arrow sits in the margin, the title where headings start.
        header.margin = Thickness(left: -28, top: 0, right: 0, bottom: 8)
        let back = iconButton(Glyph.back, name: "Back") { [weak self] in self?.showMainPage() }
        back.width = 24
        back.height = 24
        back.verticalAlignment = .top
        back.margin = Thickness(left: 0, top: 3, right: 4, bottom: 0)
        header.children.append(back)
        let path = StackPanel()
        path.orientation = .horizontal
        path.verticalAlignment = .top
        path.margin = Thickness(left: 0, top: -1, right: 0, bottom: 0)
        let profiles = TextBlock()
        profiles.text = "Profiles"
        profiles.foreground = accentText
        profiles.tapped.addHandler { [weak self] _, _ in self?.showMainPage() }
        let separator = TextBlock()
        separator.text = "/"
        separator.opacity = 0.5
        separator.margin = Thickness(left: 8, top: 0, right: 9, bottom: 0)
        let name = TextBlock()
        name.text = profile.name
        for text in [profiles, separator, name] {
            text.fontSize = 20
            text.fontWeight = FontWeight(weight: 600)
            path.children.append(text)
        }
        try? Grid.setColumn(path, 1)
        header.children.append(path)
        let rename = button("Rename Profile") { [weak self] in self?.renameProfile(profile) }
        rename.minWidth = 151
        try? Grid.setColumn(rename, 3)
        header.children.append(rename)
        sections.children.append(header)

        subheading("Search Settings")
        card("Search Engine", nil, trailing: choice(SearchEngine.allCases.map(\.name),
             selected: SearchEngine.allCases.firstIndex(of: settings.searchEngine) ?? 0) { [weak self] index in
            self?.store.settings.searchEngine = SearchEngine.allCases[index]
        })
        card("Include search engine suggestions", nil,
             trailing: toggle(settings.searchSuggestions) { [weak self] in self?.store.settings.searchSuggestions = $0 })

        subheading("Related Settings")
        // Arc marks the default choice.
        let intervals = ArchiveInterval.allCases.map { $0 == ArrowSettings().archiveInterval ? "\($0.title) (default)" : $0.title }
        card("Archive tabs after", nil, trailing: choice(intervals,
             selected: ArchiveInterval.allCases.firstIndex(of: settings.archiveInterval) ?? 0) { [weak self] index in
            self?.store.settings.archiveInterval = ArchiveInterval.allCases[index]
        })
        let locations: [DownloadLocation] = [.downloads, .ask]
        card("Save downloads to", nil, trailing: choice(["Downloads", "Ask every time"],
             selected: locations.firstIndex(of: settings.downloadLocation) ?? 0) { [weak self] index in
            self?.store.settings.downloadLocation = locations[index]
        })

        // Arc's links, those Arrow has on Windows, and Delete at the right.
        let footer = Grid()
        footer.margin = Thickness(left: 0, top: 24, right: 0, bottom: 0)
        for width in [GridLength.star, .auto] {
            let column = ColumnDefinition()
            column.width = width
            footer.columnDefinitions.append(column)
        }
        let links = StackPanel()
        links.spacing = 8
        links.children.append(link("Notifications", glyph: Glyph.bell) {
            _ = "ms-settings:notifications".withWideString { address in
                "open".withWideString { verb in ShellExecuteW(nil, verb, address, nil, nil, SW_SHOWNORMAL) }
            }
        })
        links.children.append(link("Clear Browsing Data", glyph: Glyph.delete) { [weak self] in self?.clearBrowsingData() })
        footer.children.append(links)
        let canDelete = !profile.isDefault && !store.state.spaces.contains { $0.profileID == profile.id }
        let delete = link("Delete “\(profile.name)” Profile", glyph: nil, color: RGBColor(hex: 0xC42B1C)) { [weak self] in
            self?.store.update { $0.deleteProfile(profile.id) }
            self?.showMainPage()
        }
        delete.isEnabled = canDelete
        delete.opacity = canDelete ? 1 : 0.5
        delete.verticalAlignment = .bottom
        delete.margin = Thickness(left: 0, top: 0, right: 12, bottom: 0)
        try? Grid.setColumn(delete, 1)
        footer.children.append(delete)
        sections.children.append(footer)
    }

    private func subheading(_ title: String) {
        let text = TextBlock()
        text.text = title
        text.fontSize = 14
        text.fontWeight = FontWeight(weight: 600)
        text.margin = Thickness(left: 0, top: sections.children.size <= 1 ? 0 : 8, right: 0, bottom: 0)
        sections.children.append(text)
    }

    /// Arc's links under a profile's settings: an icon and a title, in the
    /// accent color.
    private func link(_ title: String, glyph: String?, color: RGBColor? = nil, action: @escaping () -> Void) -> Button {
        let content = StackPanel()
        content.orientation = .horizontal
        content.spacing = 8
        let brush = color.map { SolidColorBrush(Color($0)) } ?? accentText
        if let glyph {
            let icon = Glyph.view(glyph, size: 16)
            icon.foreground = brush
            content.children.append(icon)
        }
        let text = TextBlock()
        text.text = title
        text.fontSize = 12
        text.fontWeight = FontWeight(weight: 600)
        text.foreground = brush
        text.verticalAlignment = .center
        content.children.append(text)
        let button = Button()
        button.content = content
        button.padding = Thickness()
        button.minHeight = 0
        button.background = SolidColorBrush(Color(a: 0, r: 0, g: 0, b: 0))
        button.borderThickness = Thickness()
        try? AutomationProperties.setName(button, title)
        button.click.addHandler { _, _ in action() }
        return button
    }

    private func iconButton(_ glyph: String, name: String, action: @escaping () -> Void) -> Button {
        let button = Button()
        button.content = Glyph.view(glyph, size: 14)
        button.width = 32
        button.height = 32
        button.padding = Thickness()
        button.background = SolidColorBrush(Color(a: 0, r: 0, g: 0, b: 0))
        button.borderThickness = Thickness()
        button.verticalAlignment = .center
        try? AutomationProperties.setName(button, name)
        button.click.addHandler { _, _ in action() }
        return button
    }

    /// Links and the breadcrumb, in the accent's text color.
    private var accentText: Brush {
        (try? Application.current.resources.lookup("AccentTextFillColorPrimaryBrush") as? Brush)
            ?? SolidColorBrush(Color(RGBColor(hex: 0x003E92)))
    }

    private func renameProfile(_ profile: Profile) {
        let name = TextBox()
        name.text = profile.name
        try? name.selectAll()
        let dialog = ContentDialog()
        dialog.xamlRoot = window.content.xamlRoot
        dialog.title = "Rename Profile"
        dialog.content = name
        dialog.primaryButtonText = "Rename"
        dialog.closeButtonText = "Cancel"
        dialog.defaultButton = .primary
        dialog.requestedTheme = isDark ? .dark : .light
        dialog.primaryButtonClick.addHandler { [weak self] _, _ in
            let title = name.text.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return }
            self?.store.update { $0.renameProfile(profile.id, to: title) }
            self?.rebuild()
        }
        _ = try? dialog.showAsync()
    }

    /// Chromium's choices, for every profile and all time.
    private func clearBrowsingData() {
        let options = StackPanel()
        options.spacing = 4
        let history = CheckBox()
        history.content = "Browsing history"
        let cookies = CheckBox()
        cookies.content = "Cookies and other site data"
        let cache = CheckBox()
        cache.content = "Cached images and files"
        for box in [history, cookies, cache] {
            box.isChecked = true
            options.children.append(box)
        }
        let dialog = ContentDialog()
        dialog.xamlRoot = window.content.xamlRoot
        dialog.title = "Clear Browsing Data"
        dialog.content = options
        dialog.primaryButtonText = "Clear Data"
        dialog.closeButtonText = "Cancel"
        dialog.requestedTheme = isDark ? .dark : .light
        dialog.primaryButtonClick.addHandler { [weak self] _, _ in
            self?.store.clearBrowsingData(since: nil, history: history.isChecked == true, cookies: cookies.isChecked == true,
                                          cache: cache.isChecked == true)
        }
        _ = try? dialog.showAsync()
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
    @discardableResult
    private func card(_ title: String, _ detail: String?, icon: String? = nil, trailing: UIElement) -> Grid {
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
        return card
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
