import ArrowCore
import ArrowKit
import Foundation
import UWP
import WinAppSDK
import WindowsFoundation
import WinUI

/// Arc's settings on Windows: one window of sections (Account, Profiles,
/// Sync, General, Extensions, Max, Advanced), each a column of Windows 11
/// cards, over Mica.
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
        try? window.appWindow.resize(SizeInt32(width: 700, height: 640))
        sections.padding = Thickness(left: 36, top: 44, right: 36, bottom: 36)
        sections.spacing = 8
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
        card("Sidebar Sync", settings.syncEnabled ? "Sync enabled" : "Sync disabled",
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
        card("Block ads and trackers", nil,
             trailing: toggle(settings.adBlockerEnabled) { [weak self] in self?.store.settings.adBlockerEnabled = $0 })
        card("Search suggestions", nil,
             trailing: toggle(settings.searchSuggestions) { [weak self] in self?.store.settings.searchSuggestions = $0 })
        card("Sound effects", nil,
             trailing: toggle(settings.soundEffects) { [weak self] in self?.store.settings.soundEffects = $0 })

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

        // Advanced
        heading("Advanced", .advanced)
        card("Export Spaces and tabs", "A zip archive of Arrow's data, in your Downloads folder.",
             trailing: button("Export Data") { [weak self] in self?.exportData() })
        card("Developer mode", "Shows full addresses and developer tools in menus.",
             trailing: toggle(settings.developerMode) { [weak self] in self?.store.settings.developerMode = $0 })
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
        text.margin = Thickness(left: 0, top: sections.children.size == 0 ? 0 : 24, right: 0, bottom: 4)
        sections.children.append(text)
        if let section { anchors[section] = text }
    }

    private func text(_ string: String) {
        let text = TextBlock()
        text.text = string
        text.fontSize = 12
        text.textWrapping = .wrap
        text.margin = Thickness(left: 0, top: 0, right: 0, bottom: 4)
        sections.children.append(text)
    }

    /// A Windows 11 settings card: a title, a description, a control.
    private func card(_ title: String, _ detail: String?, trailing: UIElement) {
        let card = Grid()
        card.padding = Thickness(left: 20, top: 14, right: 16, bottom: 14)
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
        card.children.append(labels)
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

    private func toggle(_ isOn: Bool, action: @escaping (Bool) -> Void) -> ToggleSwitch {
        let toggle = ToggleSwitch()
        // Arc's English, not the system's language.
        toggle.onContent = "On"
        toggle.offContent = "Off"
        toggle.isOn = isOn
        toggle.toggled.addHandler { _, _ in action(toggle.isOn) }
        return toggle
    }

    private func choice(_ titles: [String], selected: Int, action: @escaping (Int) -> Void) -> ComboBox {
        let combo = ComboBox()
        for title in titles {
            combo.items.append(title)
        }
        combo.selectedIndex = Int32(selected)
        combo.minWidth = 160
        combo.selectionChanged.addHandler { _, _ in
            let index = Int(combo.selectedIndex)
            if index >= 0 { action(index) }
        }
        return combo
    }
}
