import ArrowCEF
import ArrowCore
import ArrowKit
import SwiftUI

/// Panes of Preferences (⌘,), as in Arc 1.170.
enum SettingsPane: String, CaseIterable, Identifiable {
    case account, general, profiles, max, links, shortcuts, icon, advanced

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .account: "person.crop.square.filled.and.at.rectangle"
        case .general: "gearshape"
        case .profiles: "person"
        case .max: "camera.macro"
        case .links: "rectangle.on.rectangle"
        case .shortcuts: "keyboard"
        case .icon: "arrow.up.forward.app"
        case .advanced: "slider.horizontal.3"
        }
    }
}

/// Sheets opened from the panes.
enum SettingsSheet: String, Identifiable {
    case previews, search, clearData, airTraffic, recovery, moreSettings, passwords, cards

    var id: String { rawValue }
}

/// Selected pane and sheet, shared with the commands that open Preferences.
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()

    var pane: SettingsPane = .general {
        didSet { onPaneChange?(pane) }
    }

    var sheet: SettingsSheet?
    @ObservationIgnored var onPaneChange: ((SettingsPane) -> Void)?
}

/// Preferences window (⌘,): 684 × 650 pt, with a toolbar of panes and the
/// pane's name as title, like Arc's (an AppKit tab view controller).
final class SettingsWindowController: NSWindowController {
    private let tabs = SettingsTabViewController()

    init(store: BrowserStore) {
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        tabs.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: SettingsPaneView(pane: pane).environment(store))
            host.sizingOptions = []
            host.preferredContentSize = NSSize(width: 684, height: 562)
            // The tab view controller titles the window after the selected pane.
            host.title = SettingsView.title(of: pane, store: store)
            let item = NSTabViewItem(viewController: host)
            item.label = host.title ?? ""
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: item.label)
            item.identifier = pane.rawValue
            tabs.addTabViewItem(item)
        }
        let navigation = SettingsNavigation.shared
        tabs.selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: navigation.pane) ?? 0
        navigation.onPaneChange = { [weak self] pane in
            guard let self, let index = SettingsPane.allCases.firstIndex(of: pane),
                  tabs.selectedTabViewItemIndex != index else { return }
            tabs.selectedTabViewItemIndex = index
        }
        // The account pane is named after the signed-in user.
        tabs.accountTitle = { SettingsView.title(of: .account, store: store) }
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class SettingsTabViewController: NSTabViewController {
    var accountTitle: (() -> String)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String, let pane = SettingsPane(rawValue: id),
           SettingsNavigation.shared.pane != pane {
            SettingsNavigation.shared.pane = pane
        }
        if let accountTitle, let account = tabViewItems.first {
            account.label = accountTitle()
            account.viewController?.title = account.label
        }
    }
}

/// One pane, with the sheets panes open.
private struct SettingsPaneView: View {
    let pane: SettingsPane
    @Bindable private var navigation = SettingsNavigation.shared

    var body: some View {
        content
            .frame(width: 684, height: 562)
            .sheet(item: navigation.pane == pane ? $navigation.sheet : .constant(nil)) { sheet in
                switch sheet {
                case .previews: PreviewsSheet()
                case .search: SearchSettingsSheet()
                case .clearData: ClearBrowsingDataSheet()
                case .airTraffic: AirTrafficControlSheet()
                case .recovery: RecoveryCardSheet()
                case .moreSettings: MoreSettingsSheet()
                case .passwords: PasswordsSheet()
                case .cards: CardsSheet()
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .account: AccountPane()
        case .general: GeneralPane()
        case .profiles: ProfilesPane()
        case .max: MaxPane()
        case .links: LinksPane()
        case .shortcuts: ShortcutsPane()
        case .icon: IconPane()
        case .advanced: AdvancedPane()
        }
    }
}

enum SettingsView {
    /// The account pane is named after the user, as in Arc.
    @MainActor
    static func accountTitle(_ store: BrowserStore) -> String {
        guard let user = store.cloud.user else { return "Account" }
        return user.displayName.isEmpty ? String(user.email.prefix { $0 != "@" }) : user.displayName
    }

    @MainActor
    static func title(of pane: SettingsPane, store: BrowserStore) -> String {
        pane == .account ? accountTitle(store) : pane.rawValue.capitalized
    }
}

// MARK: - Building blocks

/// A rounded group of rows.
private struct PrefsGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }
}

private struct PrefsDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 10)
    }
}

private struct PrefsRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var icon: (symbol: String, color: Color)?
    var info: String?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            if let icon { IconTile(symbol: icon.symbol, color: icon.color) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 13))
                    if let info { InfoButton(text: info) }
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(minHeight: 41)
    }
}

private struct PrefsToggle: View {
    let title: String
    var subtitle: String?
    var icon: (symbol: String, color: Color)?
    var info: String?
    @Binding var isOn: Bool

    var body: some View {
        PrefsRow(title: title, subtitle: subtitle, icon: icon, info: info) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }
}

private struct IconTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color))
    }
}

private struct InfoButton: View {
    let text: String
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .popover(isPresented: $isShown) {
                Text(text).font(.system(size: 12)).padding(12).frame(width: 260, alignment: .leading)
            }
            .accessibilityLabel("Information")
    }
}

/// Paragraph above a group.
private struct PrefsText: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func sheetLayout<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 14) {
        Text(title).font(.system(size: 15, weight: .semibold))
        content()
        HStack {
            Spacer()
            Button("Done") { SettingsNavigation.shared.sheet = nil }.keyboardShortcut(.defaultAction)
        }
    }
    .padding(20)
    .frame(width: 460)
}

// MARK: - Account

private struct AccountPane: View {
    @Environment(BrowserStore.self) private var store
    @State private var isDefault = DefaultBrowser.isArrow

    var body: some View {
        @Bindable var store = store
        let cloud = store.cloud
        VStack(spacing: 22) {
            if !isDefault {
                HStack(spacing: 10) {
                    Text("Arrow isn’t your default browser.")
                    Button {
                        DefaultBrowser.setDefault(Bundle.main.bundleURL)
                        isDefault = true
                    } label: {
                        Label("Make Arrow your default", systemImage: "heart.fill")
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                )
            }
            HStack(alignment: .top, spacing: 34) {
                VStack(spacing: 18) {
                    MemberCard(name: SettingsView.accountTitle(store) == "Account" ? NSFullUserName() : SettingsView.accountTitle(store),
                               since: memberSince, colors: themeColors)
                    HStack(spacing: 28) {
                        Button { shareCard() } label: { Image(systemName: "square.and.arrow.up") }
                        Button { saveCard() } label: { Image(systemName: "square.and.arrow.down") }
                        Button { copyCard() } label: { Image(systemName: "doc.on.doc") }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                VStack(spacing: 12) {
                    if let user = cloud.user {
                        PrefsGroup {
                            PrefsRow(title: "Account") {
                                Text(user.email).foregroundStyle(.secondary)
                                Menu {
                                    Button("Sync Now") { Task { await cloud.syncNow() } }
                                    Button("Sign Out") { Task { await cloud.signOut() } }
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .menuStyle(.button)
                                .menuIndicator(.hidden)
                                .fixedSize()
                            }
                        }
                        PrefsGroup {
                            PrefsRow(title: "Sync Sidebar") {
                                Toggle("Sync Sidebar", isOn: $store.settings.syncEnabled)
                                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            }
                            if let date = cloud.lastSyncDate {
                                HStack(spacing: 6) {
                                    Circle().fill(cloud.lastSyncError == nil ? .green : .orange).frame(width: 7, height: 7)
                                    Text("Last synced: \(date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.bottom, 8)
                            }
                            PrefsDivider()
                            Text("Arrow Sync is end-to-end encrypted, only you can see your data. [Learn more](\(privacyURL)) or view your [Recovery Card](arrow-settings://recovery).")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        PrefsGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Arrow Cloud").font(.system(size: 13, weight: .semibold))
                                Text("Sign in to an Arrow Cloud server to sync your sidebar between Macs, share spaces and use Max.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                TextField("Server URL", text: $store.settings.cloudServerURL, prompt: Text("https://arrow.example.com"))
                                AccountView()
                            }
                            .padding(10)
                        }
                    }
                    PrefsGroup {
                        PrefsRow(title: "Gift Arrow to a Friend") {
                            Button { (NSApp.delegate as? AppDelegate)?.shareArrow(nil) } label: {
                                Label("Share Arrow", systemImage: "gift")
                            }
                        }
                        PrefsDivider()
                        Text("Arrow is free and open source. Share it with someone who misses Arc.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(width: 348)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
        .padding(.horizontal, 30)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "arrow-settings" else { return .systemAction }
            SettingsNavigation.shared.sheet = .recovery
            return .handled
        })
    }

    private var privacyURL: String { AppDelegate.projectURL.absoluteString + "/blob/main/docs/PRIVACY.md" }

    private var themeColors: [Color] {
        (store.state.spaces.first?.theme.colors ?? [RGBColor(hex: 0x3F7E8C), RGBColor(hex: 0x8E2FA8)]).map(Color.init)
    }

    /// When Arrow's data folder was created.
    private var memberSince: Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: store.dataDirectory.path)
        return attributes?[.creationDate] as? Date ?? Date()
    }

    private func cardImage() -> NSImage? {
        let renderer = ImageRenderer(content: MemberCard(name: SettingsView.accountTitle(store), since: memberSince,
                                                         colors: themeColors))
        renderer.scale = 2
        return renderer.nsImage
    }

    private func shareCard() {
        guard let image = cardImage(), let window = NSApp.keyWindow, let view = window.contentView else { return }
        NSSharingServicePicker(items: [image]).show(relativeTo: NSRect(x: 150, y: 80, width: 1, height: 1), of: view,
                                                     preferredEdge: .minY)
    }

    private func saveCard() {
        guard let image = cardImage(), let data = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Arrow Card.png"
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url { try? png.write(to: url) }
    }

    private func copyCard() {
        guard let image = cardImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}

/// The member card of the account pane.
private struct MemberCard: View {
    let name: String
    let since: Date
    let colors: [Color]
    private let ink = Color(red: 0.75, green: 0.08, blue: 0.62)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LeafShape()
                .fill(LinearGradient(colors: colors, startPoint: .bottomLeading, endPoint: .topTrailing))
                .frame(height: 196)
            Text(name)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 18)
            Text("ARROW MEMBER")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .kerning(1.2)
                .foregroundStyle(ink)
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                HStack(spacing: 0) {
                    Text("ARROW").padding(.horizontal, 6)
                    Rectangle().fill(ink).frame(width: 1)
                    Text(since.formatted(date: .abbreviated, time: .omitted)).padding(.horizontal, 6)
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(ink)
                .frame(height: 16)
                .overlay(Rectangle().strokeBorder(ink, lineWidth: 1))
                Spacer()
                Text("OPEN\nSOURCE")
                    .font(.system(size: 9, weight: .heavy, design: .serif))
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(ink)
            }
        }
        .padding(16)
        .frame(width: 246, height: 368)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(red: 0.99, green: 0.98, blue: 0.91)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.black.opacity(0.06)))
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
    }
}

/// Leaf with points at the bottom left and top right.
private struct LeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

private struct RecoveryCardSheet: View {
    @Environment(BrowserStore.self) private var store
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        sheetLayout("Recovery Card") {
            Text("Your synced data is end-to-end encrypted with this key. Keep it to restore your sidebar on another Mac.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Text(store.cloud.recoveryKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.cloud.recoveryKey, forType: .string)
                }
            }
            HStack {
                TextField("Paste a recovery key from another Mac", text: $key)
                Button("Use Key") { error = store.cloud.restore(recoveryKey: key) ? nil : "Invalid recovery key" }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 10) {
            PrefsGroup {
                PrefsToggle(title: "Automatically update my Arrow",
                            info: "Arrow downloads updates from your Arrow Cloud server, checks their signature and installs them when you restart.",
                            isOn: $store.settings.automaticallyInstallUpdates)
                PrefsDivider()
                PrefsToggle(title: "Warn before quitting", isOn: $store.settings.warnBeforeQuitting)
            }
            PrefsGroup {
                PrefsRow(title: "Previews") {
                    Button("Previews Settings…") { SettingsNavigation.shared.sheet = .previews }
                }
                PrefsDivider()
                PrefsRow(title: "Manage your default search engine, Auto-Archive, and downloads in Profile Settings.") {
                    Button("Profile Settings…") { SettingsNavigation.shared.pane = .profiles }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 64)
        .padding(.top, 20)
    }
}

private struct PreviewsSheet: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        @Bindable var store = store
        sheetLayout("Show Arrow Previews:") {
            Toggle("When hovering pinned and favorite tabs", isOn: $store.settings.showTabPreviewsOnHover)
            Text("Hover a favorite or a pinned tab to glance at its page without switching to it.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Profiles

private struct ProfilesPane: View {
    @Environment(BrowserStore.self) private var store
    @State private var selection: UUID?

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 14) {
            PrefsText(text: "Profiles help keep your data separate across Spaces — like history, logins, cookies, and extensions. You can use any Profile across one or more Spaces. [Learn more.](https://github.com/euskadi31/arrow-browser#readme)")
            HStack(alignment: .top, spacing: 10) {
                profileList
                    .frame(width: 206)
                VStack(alignment: .leading, spacing: 10) {
                    PrefsGroup {
                        PrefsRow(title: "Search engine") {
                            Picker("Search engine", selection: $store.settings.searchEngine) {
                                ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                            }
                            .labelsHidden().frame(width: 150)
                        }
                        PrefsDivider()
                        PrefsRow(title: "Manage search") {
                            Button("Search Settings…") { SettingsNavigation.shared.sheet = .search }
                        }
                        PrefsDivider()
                        PrefsToggle(title: "Include search engine suggestions", isOn: $store.settings.searchSuggestions)
                    }
                    PrefsGroup {
                        PrefsRow(title: "Archive tabs after",
                                 info: "Today tabs you haven’t visited for this long move to the Archive (⇧⌘L).") {
                            Picker("Archive tabs after", selection: $store.settings.archiveInterval) {
                                ForEach(ArchiveInterval.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().frame(width: 150)
                        }
                        PrefsDivider()
                        PrefsRow(title: "New documents") {
                            Picker("New documents", selection: $store.settings.documentApp) {
                                ForEach(DocumentApp.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().frame(width: 150)
                        }
                        PrefsDivider()
                        PrefsRow(title: "Download location") { DownloadLocationPicker() }
                    }
                    Text("Your Data and Settings").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.leading, 10)
                    PrefsGroup {
                        dataRow("Privacy and Security", "lock.fill", .blue) { SettingsNavigation.shared.sheet = .moreSettings }
                        PrefsDivider()
                        dataRow("Passwords", "key.fill", .green) { SettingsNavigation.shared.sheet = .passwords }
                        PrefsDivider()
                        dataRow("Credit Cards", "creditcard.fill", .yellow) { SettingsNavigation.shared.sheet = .cards }
                        PrefsDivider()
                        dataRow("Notifications", "bell.fill", .orange) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!)
                        }
                        PrefsDivider()
                        dataRow("Clear Browsing Data", "trash.fill", .red) { SettingsNavigation.shared.sheet = .clearData }
                    }
                }
                .frame(width: 344)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 64)
        .padding(.top, 18)
        .onAppear { selection = selection ?? store.state.profiles.first?.id }
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            Text("Your Profiles")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.state.profiles) { profile in
                        let count = store.state.spaces.filter { $0.profileID == profile.id }.count
                        HStack {
                            Text(profile.name).font(.system(size: 13))
                            Spacer()
                            Text(count == 1 ? "1 Space" : "\(count) Spaces").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(selection == profile.id ? Color.accentColor.opacity(0.15) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { selection = profile.id }
                    }
                }
                .padding(8)
            }
            Divider()
            HStack(spacing: 0) {
                Button { addProfile() } label: { Image(systemName: "plus").frame(width: 28, height: 22) }
                Divider().frame(height: 16)
                Button { deleteProfile() } label: { Image(systemName: "minus").frame(width: 28, height: 22) }
                    .disabled(!canDelete)
                Divider().frame(height: 16)
                Button { renameProfile() } label: { Image(systemName: "rectangle.and.pencil.and.ellipsis").frame(width: 32, height: 22) }
                    .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(4)
        }
        .frame(height: 482)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }

    /// Only Profiles not assigned to any Spaces can be deleted, never the default one (as in Arc).
    private var canDelete: Bool {
        guard let selection, let profile = store.state.profile(selection) else { return false }
        return !profile.isDefault && !store.state.spaces.contains { $0.profileID == selection }
    }

    private func dataRow(_ title: String, _ symbol: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PrefsRow(title: title, icon: (symbol, color)) {
                Image(systemName: "arrow.right").foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func addProfile() {
        guard let name = askName(title: "New Profile", value: "") else { return }
        store.update { selection = $0.createProfile(name: name).id }
    }

    private func renameProfile() {
        guard let selection, let profile = store.state.profile(selection),
              let name = askName(title: "Rename Profile", value: profile.name) else { return }
        store.update { $0.renameProfile(selection, to: name) }
    }

    private func deleteProfile() {
        guard let selection, canDelete else { return }
        store.update { $0.deleteProfile(selection) }
        self.selection = store.state.profiles.first?.id
    }

    private func askName(title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        field.placeholderString = "Profile name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// Downloads folder, another folder, or ask each time (Arc's three choices).
private struct DownloadLocationPicker: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        Menu {
            Button("Downloads") { store.settings.downloadLocation = .downloads }
            Button("Ask where to save each file") { store.settings.downloadLocation = .ask }
            Divider()
            Button("Other…") { chooseFolder() }
        } label: {
            Label(title, systemImage: store.settings.downloadLocation == .ask ? "questionmark.folder" : "folder.fill")
        }
        .frame(width: 150)
    }

    private var title: String {
        switch store.settings.downloadLocation {
        case .downloads: "Downloads"
        case .ask: "Ask"
        case .folder: URL(fileURLWithPath: store.settings.downloadFolder).lastPathComponent
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.downloadFolder = url.path
        store.settings.downloadLocation = .folder
    }
}

private struct SearchSettingsSheet: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        @Bindable var store = store
        sheetLayout("Search Settings") {
            Picker("Default search engine", selection: $store.settings.searchEngine) {
                ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
            }
            Text("Site search: type a site’s name in the command bar, then press Tab.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(SiteSearch.builtIn + [.chatGPT], id: \.keyword) { site in
                        HStack {
                            FaviconView(url: "https://\(site.domain)", size: 16)
                            Text(site.name)
                            Spacer()
                            Text(site.keyword).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
            .frame(height: 260)
        }
    }
}

private struct ClearBrowsingDataSheet: View {
    @Environment(BrowserStore.self) private var store
    @State private var range = 3
    @State private var history = true
    @State private var cookies = false
    @State private var cache = true

    private let ranges: [(String, TimeInterval?)] = [
        ("Last hour", 3600), ("Last 24 hours", 86400), ("Last 7 days", 7 * 86400), ("All time", nil),
    ]

    var body: some View {
        sheetLayout("Clear Browsing Data") {
            Picker("Time range", selection: $range) {
                ForEach(ranges.indices, id: \.self) { Text(ranges[$0].0).tag($0) }
            }
            Toggle("Browsing history", isOn: $history)
            Toggle("Cookies and other site data", isOn: $cookies)
            Toggle("Cached images and files", isOn: $cache)
            Text("Cookies and cached files are cleared for all time, in every profile. Cookies sign you out of most sites.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Clear Data") {
                    let since = ranges[range].1.map { Date().addingTimeInterval(-$0) }
                    store.clearBrowsingData(since: since, history: history, cookies: cookies, cache: cache)
                    SettingsNavigation.shared.sheet = nil
                }
                .disabled(!history && !cookies && !cache)
            }
        }
    }
}

// MARK: - Max

private struct MaxPane: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MaxBanner()
                VStack(alignment: .leading, spacing: 14) {
                    PrefsText(text: "Let Arrow do more for you with Max, so you can do less. Power up your browsing with AI and spend time on the things that matter — on or off screen.")
                    PrefsGroup {
                        PrefsRow(title: "Enable Max", icon: ("camera.macro", Color(red: 0.55, green: 0.35, blue: 0.95))) {
                            Button { toggleMax() } label: {
                                Text(store.settings.aiEnabled ? "Turn Off Max" : "Turn On Max")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 20)
                                    .frame(height: 28)
                                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color(red: 0.23, green: 0.18, blue: 0.96)))
                            }
                            .buttonStyle(.plain)
                        }
                        PrefsDivider()
                        PrefsToggle(title: "Automatically enable future Arrow Max features",
                                    isOn: $store.settings.autoEnableNewMaxFeatures)
                    }
                    PrefsGroup {
                        feature("Tidy Tabs", "Press the ✦ icon to let your Sidebar organize itself whenever you have more than six Today Tabs.",
                                "wand.and.stars", .purple, $store.settings.tidyTabs)
                        PrefsDivider()
                        feature("Instant Links", "Press Shift + Enter for any web search to instantly open the top result.",
                                "bolt.fill", .blue, $store.settings.instantLinks)
                        PrefsDivider()
                        feature("5-Second Previews", "Instant summaries appear when you hold Shift while hovering a link, and in Peek with ✦.",
                                "eye", .teal, $store.settings.linkPreviews)
                        PrefsDivider()
                        feature("Tidy Tab Titles", "Have your tabs automatically renamed with tidier, shorter titles when you Pin them.",
                                "textformat", .pink, $store.settings.tidyTabTitles)
                        PrefsDivider()
                        feature("Tidy Downloads", "Keep your many files more organized with smartly renamed downloads — and make them a little easier to find later.",
                                "arrow.down.doc", .orange, $store.settings.tidyDownloads)
                        PrefsDivider()
                        feature("ChatGPT in the Command Bar", "Add ChatGPT to your Search suggestions, or start typing “ChatGPT”, hit Tab, to ask any question instantly.",
                                "bubble.left.and.text.bubble.right", .green, $store.settings.chatGPTInCommandBar)
                    }
                    Text("Max features require that we send data to our AI partners. [Learn more about what we send](\(AppDelegate.projectURL.absoluteString)/blob/main/docs/PRIVACY.md)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 64)
                .padding(.bottom, 20)
            }
        }
    }

    private func feature(_ title: String, _ text: String, _ symbol: String, _ color: Color, _ isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.18))
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(color)
            }
            .frame(width: 88, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(!store.settings.aiEnabled && title != "Instant Links" && title != "ChatGPT in the Command Bar")
        }
        .padding(10)
    }

    /// Max goes through the AI endpoint of the Arrow Cloud server.
    private func toggleMax() {
        if store.settings.aiEnabled {
            store.settings.aiEnabled = false
        } else if store.cloud.isSignedIn {
            store.settings.aiEnabled = true
            if store.settings.autoEnableNewMaxFeatures {
                store.settings.tidyTabs = true
                store.settings.tidyTabTitles = true
                store.settings.tidyDownloads = true
                store.settings.linkPreviews = true
            }
        } else {
            SettingsNavigation.shared.pane = .account
        }
    }
}

/// Blue banner with flowers, as at the top of Arc's Max pane.
private struct MaxBanner: View {
    private let flowers: [(CGFloat, CGFloat, CGFloat)] = [
        (0.03, 0.12, 22), (0.29, 0.18, 14), (0.15, 0.62, 30), (0.42, 0.62, 18), (0.64, 0.12, 22), (0.70, 0.55, 22), (0.98, 0.70, 26),
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.23, green: 0.18, blue: 0.96)
                ForEach(flowers.indices, id: \.self) { index in
                    let flower = flowers[index]
                    Image(systemName: "camera.macro")
                        .font(.system(size: flower.2, weight: .bold))
                        .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.62))
                        .position(x: proxy.size.width * flower.0, y: proxy.size.height * flower.1)
                }
                Text("MAX")
                    .font(.system(size: 46, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: Color(red: 1, green: 0.4, blue: 0.55), radius: 0, x: 2, y: 2)
            }
        }
        .frame(height: 128)
        .clipShape(WaveBottom())
    }
}

private struct WaveBottom: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 6))
        let waves = Int(rect.width / 12)
        for index in (0...waves).reversed() {
            let x = CGFloat(index) * 12
            path.addQuadCurve(to: CGPoint(x: max(x - 12, 0), y: rect.maxY - 6),
                              control: CGPoint(x: x - 6, y: index.isMultiple(of: 2) ? rect.maxY : rect.maxY - 12))
        }
        path.addLine(to: CGPoint(x: 0, y: 0))
        return path
    }
}

// MARK: - Links

private struct LinksPane: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LinksBanner()
                VStack(alignment: .leading, spacing: 14) {
                    PrefsText(text: "Little Arrow is a smaller, simpler Arrow window. It’s perfect for quick lookups and reading funny tweets your friends send you.")
                    PrefsGroup {
                        PrefsToggle(title: "Open Little Arrow when I press ⌥⌘N in any app", isOn: $store.settings.littleArrowShortcut)
                        PrefsDivider()
                        PrefsToggle(title: "Open Little Arrow when clicking on links with ⌥⌘ held",
                                    isOn: $store.settings.littleArrowOnOptionCommandClick)
                        PrefsDivider()
                        PrefsToggle(title: "Links from other apps open in Little Arrow", isOn: Binding(
                            get: { store.settings.externalLinks == .littleArrow },
                            set: { store.settings.externalLinks = $0 ? .littleArrow : .activeSpace }))
                        PrefsDivider()
                        PrefsRow(title: "Archive Little Arrows after:") {
                            Picker("Archive Little Arrows after", selection: $store.settings.littleArrowArchive) {
                                ForEach(LittleArrowArchive.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().frame(width: 150)
                        }
                    }
                    Divider().padding(.vertical, 6)
                    PrefsText(text: "Peek is a way to preview a link without opening a new tab. It’s perfect for quickly looking at a link from an email, news article, or tweet.")
                    PrefsGroup {
                        PrefsToggle(title: "Open a Peek window when clicking on links with Shift held",
                                    isOn: $store.settings.peekOnShiftClick)
                        PrefsDivider()
                        PrefsToggle(title: "Open a Peek window when clicking on links to other sites",
                                    subtitle: "Note: This only affects Favorites and Pinned tabs", isOn: $store.settings.peekEnabled)
                    }
                    Divider().padding(.vertical, 6)
                    HStack(spacing: 6) {
                        Text("Choose where links open inside Arrow.").font(.system(size: 13))
                        InfoButton(text: "Routes let you choose where specific sites open inside Arrow. For example, you can route Spotify links to always open inside your Personal space.")
                        Spacer()
                        Button("Air Traffic Control…") { SettingsNavigation.shared.sheet = .airTraffic }
                    }
                }
                .padding(.horizontal, 64)
                .padding(.bottom, 20)
            }
        }
    }
}

/// Pink banner with a small window, as at the top of Arc's Links pane.
private struct LinksBanner: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            Color(red: 1, green: 0.66, blue: 0.66)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.black.opacity(0.15)).frame(width: 6, height: 6) }
                    }
                    Text("Work").font(.system(size: 8, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.06)))
                    Spacer()
                    Text("arrow.example").font(.system(size: 8)).foregroundStyle(.secondary)
                    Spacer()
                    Text("Open in Work ⌘O").font(.system(size: 8, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.06)))
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Color(white: 0.97))
                Color(red: 1, green: 0.78, blue: 0.78)
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
            .padding(.horizontal, 60)
            .padding(.top, 50)
        }
        .frame(height: 128)
        .clipShape(WaveBottom())
    }
}

private struct AirTrafficControlSheet: View {
    @Environment(BrowserStore.self) private var store
    @State private var condition: AirTrafficRule.Condition = .hostIs
    @State private var value = ""
    @State private var spaceID: UUID?

    var body: some View {
        @Bindable var store = store
        sheetLayout("Air Traffic Control") {
            Text("Routes let you choose where specific sites open inside Arrow. For example, you can route Spotify links to always open inside your Personal space.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(store.settings.airTrafficRules) { rule in
                HStack {
                    Text(label(rule.condition)).foregroundStyle(.secondary)
                    Text(rule.value).fontWeight(.medium)
                    Image(systemName: "arrow.turn.down.right")
                    Text(store.state.space(rule.spaceID)?.title ?? "Most Recent Space")
                    Spacer()
                    Button { store.settings.airTrafficRules.removeAll { $0.id == rule.id } } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Picker("Condition", selection: $condition) {
                    ForEach(AirTrafficRule.Condition.allCases, id: \.self) { Text(label($0)).tag($0) }
                }
                .labelsHidden().frame(width: 130)
                TextField("spotify.com", text: $value)
                Picker("Space", selection: $spaceID) {
                    ForEach(store.state.spaces) { Text($0.title).tag(Optional($0.id)) }
                }
                .labelsHidden().frame(width: 120)
                Button("Add") {
                    guard let spaceID, !value.isEmpty else { return }
                    store.settings.airTrafficRules.append(AirTrafficRule(condition: condition, value: value, spaceID: spaceID))
                    value = ""
                }
            }
        }
        .onAppear { spaceID = spaceID ?? store.state.spaces.first?.id }
    }

    private func label(_ condition: AirTrafficRule.Condition) -> String {
        switch condition {
        case .hostIs: "Domain is"
        case .urlContains: "URL contains"
        case .urlStartsWith: "URL starts with"
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @Environment(BrowserStore.self) private var store
    @State private var query = ""
    @State private var commands: [MainMenu.Command] = []

    var body: some View {
        VStack(spacing: 28) {
            HStack(spacing: 8) {
                Text("Start with the basics")
                Button { (NSApp.delegate as? AppDelegate)?.showKeyboardShortcuts(nil) } label: {
                    Label("Learn the Essential Shortcuts", systemImage: "command.circle.fill")
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1))
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Type a feature name or shortcut (like “Command”)", text: $query).textFieldStyle(.plain)
                    }
                    .padding(10)
                    Divider()
                    Text("Default Shortcuts")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { command in
                                HStack {
                                    Text(command.title).font(.system(size: 13)).lineLimit(1)
                                    Spacer()
                                    ShortcutRecorder(commandID: command.id, item: command.item)
                                }
                                .padding(.horizontal, 22)
                                .frame(height: 48)
                                Divider().padding(.horizontal, 22)
                            }
                        }
                    }
                }
                .frame(width: 336)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        keyTile("command")
                        keyTile("face.smiling")
                    }
                    Text("Custom Shortcuts").font(.system(size: 13, weight: .semibold))
                    Text("Change shortcuts for your favorite actions. Click a shortcut, then press the new keys; Delete removes it.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Reset All Shortcuts") { store.settings.customShortcuts = [:] }
                        .disabled(store.settings.customShortcuts.isEmpty)
                }
                .frame(width: 200, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 63)
        .padding(.trailing, 40)
        .padding(.vertical, 20)
        .onAppear { commands = MainMenu.commands() }
    }

    private var filtered: [MainMenu.Command] {
        let terms = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !terms.isEmpty else { return commands }
        return commands.filter {
            $0.title.lowercased().contains(terms) || ShortcutRecorder.display($0.item).lowercased().contains(terms)
                || (terms.contains("command") && $0.item.keyEquivalentModifierMask.contains(.command))
        }
    }

    private func keyTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(Color(red: 0.12, green: 0.36, blue: 0.95))
            .frame(width: 58, height: 58)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(red: 0.78, green: 0.86, blue: 1)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(red: 0.12, green: 0.36, blue: 0.95), lineWidth: 3))
    }
}

/// A key cap that records a new shortcut when clicked.
private struct ShortcutRecorder: View {
    let commandID: String
    let item: NSMenuItem
    @Environment(BrowserStore.self) private var store
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button { isRecording ? stop() : start() } label: {
            Text(isRecording ? "Type…" : Self.display(item, custom: store.settings.customShortcuts[commandID]))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isRecording ? Color.accentColor : .secondary)
                .frame(minWidth: 46)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    static func display(_ item: NSMenuItem, custom: String? = nil) -> String {
        let shortcut = custom.map(MainMenu.decode) ?? (key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
        guard !shortcut.key.isEmpty else { return "---" }
        var text = ""
        if shortcut.modifiers.contains(.control) { text += "⌃" }
        if shortcut.modifiers.contains(.option) { text += "⌥" }
        if shortcut.modifiers.contains(.shift) { text += "⇧" }
        if shortcut.modifiers.contains(.command) { text += "⌘" }
        let names: [Int: String] = [NSUpArrowFunctionKey: "↑", NSDownArrowFunctionKey: "↓", NSLeftArrowFunctionKey: "←",
                                    NSRightArrowFunctionKey: "→", 0x1B: "⎋", 0x09: "⇥", 0x0D: "↩", 0x7F: "⌫"]
        let key = shortcut.key.unicodeScalars.first.map { names[Int($0.value)] ?? shortcut.key.uppercased() } ?? ""
        return text + key
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 53: break // Escape cancels.
        case 51: store.settings.customShortcuts[commandID] = "" // Delete removes the shortcut.
        default:
            let isFunctionKey = event.modifierFlags.contains(.function)
            guard !modifiers.subtracting(.shift).isEmpty || isFunctionKey,
                  let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else {
                NSSound.beep()
                return
            }
            store.settings.customShortcuts[commandID] = MainMenu.encode(key: key, modifiers: modifiers)
        }
        stop()
    }
}

// MARK: - Icon

private struct IconPane: View {
    @State private var selected = AppIcons.selected

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(AppIcons.names.enumerated()), id: \.element) { index, name in
                if index > 0 { Divider().padding(.leading, 64).padding(.trailing, 40) }
                Button {
                    selected = name
                    AppIcons.select(name)
                } label: {
                    HStack(spacing: 22) {
                        Image(systemName: selected == name ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(selected == name ? Color.accentColor : .secondary)
                        if let image = AppIcons.image(name) {
                            Image(nsImage: image).resizable().frame(width: 52, height: 52)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(index == 0 ? "The Original Arrow" : name).font(.system(size: 13, weight: .semibold))
                            if selected == name {
                                Text("CURRENT ICON").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 15)
                    .frame(height: 80)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .padding(.horizontal, 63)
        .padding(.top, 20)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Advanced

private struct AdvancedPane: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let blue = Color(red: 0.0, green: 0.48, blue: 1.0)
        let green = Color(red: 0.2, green: 0.78, blue: 0.35)
        let red = Color(red: 1.0, green: 0.27, blue: 0.27)
        let purple = Color(red: 0.75, green: 0.35, blue: 0.95)
        VStack(spacing: 10) {
            PrefsGroup {
                PrefsToggle(title: "Play Arrow sound effects", icon: ("speaker.wave.2.fill", blue), isOn: $store.settings.soundEffects)
                PrefsDivider()
                PrefsToggle(title: "Haptic feedback when reordering tabs", icon: ("hand.tap.fill", blue),
                            isOn: $store.settings.hapticFeedback)
            }
            PrefsGroup {
                PrefsToggle(title: "When opening Arrow, restore windows from previous session", icon: ("macwindow.on.rectangle", green),
                            isOn: $store.settings.restoreWindows)
                PrefsDivider()
                PrefsToggle(title: "Allow window dragging from the top of webpages", icon: ("rectangle.topthird.inset.filled", green),
                            isOn: $store.settings.dragWindowFromPageTop)
                PrefsDivider()
                PrefsToggle(title: "Show full URL when Toolbar is enabled", icon: ("ellipsis.rectangle", red),
                            isOn: $store.settings.showFullURLInToolbar)
                PrefsDivider()
                PrefsToggle(title: "Enable Shared Quotes when highlighting text.",
                            subtitle: "If disabled, you can still copy URL as a quote using ⌃⇧⌘C.", icon: ("quote.bubble.fill", red),
                            isOn: $store.settings.sharedQuotes)
            }
            PrefsGroup {
                PrefsToggle(title: "Enable Picture in Picture when you leave a video tab", icon: ("pip.fill", purple),
                            isOn: $store.settings.automaticPictureInPicture)
                PrefsDivider()
                PrefsToggle(title: "Allow websites to get your theme data", icon: ("paintpalette.fill", purple),
                            isOn: $store.settings.shareThemeWithWebsites)
                PrefsDivider()
                PrefsToggle(title: "Enable Boosts on websites you visit", icon: ("wand.and.rays", purple),
                            isOn: $store.settings.boostsEnabled)
            }
            HStack {
                Button("More Settings…") { SettingsNavigation.shared.sheet = .moreSettings }
                Button("Reset Translated-site Prompts") {
                    store.settings.neverTranslateLanguages = []
                    store.settings.neverTranslateSites = []
                }
                .disabled(store.settings.neverTranslateLanguages.isEmpty && store.settings.neverTranslateSites.isEmpty)
                Spacer()
                Button("Export Data") { (NSApp.delegate as? AppDelegate)?.exportData(nil) }
            }
            Spacer()
        }
        .padding(.horizontal, 63)
        .padding(.top, 20)
    }
}

/// Arrow's own settings, which Arc keeps in its Chromium settings.
private struct MoreSettingsSheet: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        @Bindable var store = store
        sheetLayout("More Settings") {
            Form {
                Section("Privacy and Security") {
                    Toggle("Block ads and trackers", isOn: $store.settings.adBlockerEnabled)
                    if store.settings.adBlockerEnabled {
                        LabeledContent("Filter rules", value: store.adBlocker.ruleCount.formatted())
                        Button("Update Filter Lists") { Task { await store.adBlocker.refresh() } }
                    }
                    Button("Clear Browsing Data…") { SettingsNavigation.shared.sheet = .clearData }
                }
                Section("Sidebar") {
                    Toggle("Show URL bar", isOn: $store.settings.showURLBar)
                    Picker("Sidebar position", selection: $store.settings.sidebarOnRight) {
                        Text("Left").tag(false)
                        Text("Right").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Developer mode (show full URLs)", isOn: $store.settings.developerMode)
                }
                Section("Data") {
                    Button("Clear Archive") { store.update { $0.archive.removeAll() } }
                    Button("Reveal Arrow Data in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.dataDirectory])
                    }
                }
                Section("About") {
                    LabeledContent("Rendering engine", value: "Chromium \(CEFVersion.chromium)")
                    LabeledContent("CEF", value: CEFVersion.cef)
                }
            }
            .formStyle(.grouped)
            .frame(height: 420)
        }
    }
}

// MARK: - Passwords and cards

/// Saved logins; revealing a password asks for the Mac's password or Touch ID.
private struct PasswordsSheet: View {
    @Environment(BrowserStore.self) private var store
    @State private var logins = PasswordStore.logins()
    @State private var revealed: [String: String] = [:]
    @State private var query = ""

    var body: some View {
        @Bindable var store = store
        sheetLayout("Passwords") {
            Toggle("Offer to save passwords", isOn: $store.settings.offerToSavePasswords)
            TextField("Search", text: $query)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(logins.filter { query.isEmpty || $0.host.localizedCaseInsensitiveContains(query)
                        || $0.username.localizedCaseInsensitiveContains(query) }) { login in
                        HStack {
                            FaviconView(url: "https://\(login.host)", size: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(login.host).font(.system(size: 13))
                                Text(login.username.isEmpty ? "No username" : login.username)
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(revealed[login.id] ?? "••••••••").font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                            Button { reveal(login) } label: { Image(systemName: revealed[login.id] == nil ? "eye" : "eye.slash") }
                                .buttonStyle(.borderless)
                            Button {
                                PasswordStore.delete(host: login.host, username: login.username)
                                logins = PasswordStore.logins()
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                    if logins.isEmpty {
                        Text("Passwords you save in Arrow appear here.").foregroundStyle(.secondary).padding()
                    }
                }
            }
            .frame(height: 240)
            if !store.settings.neverSavePasswordSites.isEmpty {
                Text("Never saved for: " + store.settings.neverSavePasswordSites.joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Clear Never-Saved Sites") { store.settings.neverSavePasswordSites = [] }
            }
        }
    }

    private func reveal(_ login: PasswordStore.Login) {
        if revealed[login.id] != nil {
            revealed[login.id] = nil
            return
        }
        Task {
            guard await LocalAuthentication.confirm("show a saved password") else { return }
            revealed[login.id] = PasswordStore.password(host: login.host, username: login.username)
        }
    }
}

private struct CardsSheet: View {
    @Environment(BrowserStore.self) private var store
    @State private var cards = CardStore.cards()
    @State private var holder = ""
    @State private var number = ""
    @State private var expiry = ""

    var body: some View {
        @Bindable var store = store
        sheetLayout("Credit Cards") {
            Toggle("Save and fill payment cards", isOn: $store.settings.autofillCards)
            ForEach(cards) { card in
                HStack {
                    Image(systemName: "creditcard.fill").foregroundStyle(.secondary)
                    Text(card.label)
                    Text(card.expiry).foregroundStyle(.secondary)
                    Text(card.holder).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        CardStore.delete(card)
                        cards = CardStore.cards()
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            Divider()
            HStack {
                TextField("Name on card", text: $holder)
                TextField("Card number", text: $number)
                TextField("MM/YY", text: $expiry).frame(width: 64)
                Button("Add") {
                    guard PaymentCard.isValidNumber(number), let date = PaymentCard.parseExpiry(expiry) else {
                        NSSound.beep()
                        return
                    }
                    CardStore.save(PaymentCard(holder: holder, number: number, expiryMonth: date.month, expiryYear: date.year))
                    cards = CardStore.cards()
                    holder = ""
                    number = ""
                    expiry = ""
                }
            }
            Text("Security codes are never saved.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
