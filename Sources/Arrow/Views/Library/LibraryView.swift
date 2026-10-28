import ArrowKit
import SwiftUI
import UniformTypeIdentifiers

/// Arc's Library. It takes the place of the sidebar: a rail of sections
/// (Media, Downloads, Easels, Spaces, Boosts, Archived Tabs) and a searchable
/// list, with the page still on the right. Spaces lays the spaces out as
/// cards instead of a list.
struct LibraryView: View {
    let controller: BrowserWindowController
    let section: LibrarySection

    /// Rail plus list column, measured on Arc.
    static let railWidth: CGFloat = 112
    static let listWidth: CGFloat = 305

    var body: some View {
        HStack(spacing: 0) {
            LibraryRail(section: section)
                .frame(width: Self.railWidth)
                .zIndex(1)
            Group {
                if section == .spaces {
                    SpacesBoard(controller: controller)
                } else {
                    LibraryListColumn(controller: controller, section: section)
                        .frame(width: Self.listWidth)
                }
            }
            // The rail casts a soft shadow on the column next to it.
            .overlay(alignment: .leading) {
                LinearGradient(colors: [.black.opacity(0.05), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 36)
                    .allowsHitTesting(false)
            }
        }
        .id(section)
    }
}

// MARK: - Rail

private struct LibraryRail: View {
    let section: LibrarySection
    @Environment(WindowState.self) private var state

    var body: some View {
        ZStack {
            WindowDragArea()
            VStack(spacing: 20) {
                ForEach(LibrarySection.rail) { item in
                    LibraryRailItem(section: item, isSelected: item == section) {
                        state.sheet = .library(item)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 33) {
                LibraryRailButton(symbol: "arrow.left", help: "Back to Sidebar") { state.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                LibraryRailButton(symbol: "gift", help: "Share Arrow") {
                    NSApp.sendAction(#selector(AppDelegate.shareArrow(_:)), to: nil, from: nil)
                }
            }
            .padding(.leading, 8)
            .padding(.bottom, 8)
        }
    }
}

/// ← and 🎁 at the bottom of the rail.
private struct LibraryRailButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(palette.title.opacity(0.68))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovered ? palette.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

private struct LibraryRailItem: View {
    let section: LibrarySection
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                icon
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(height: 24)
                Text(section.railTitle)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isSelected ? palette.title : palette.title.opacity(0.72))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(palette.isDark ? 0 : (isSelected ? 0.065 : (isHovered ? 0.035 : 0))))
                    .fill(Color.white.opacity(palette.isDark ? (isSelected ? 0.1 : (isHovered ? 0.05 : 0)) : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(section.railTitle)
    }

    /// Arc draws the rail icons in a saturated tint of the space's hue
    /// (#6461FC on its default theme), deeper when selected.
    private var iconColor: Color {
        guard !palette.isDark else { return palette.accent }
        return Color(palette.theme.accent.withHSB(saturation: isSelected ? 0.68 : 0.61, brightness: 0.99))
    }

    @ViewBuilder private var icon: some View {
        switch section {
        case .easelsAndNotes:
            // Arc's easel: a window with a scribble.
            Image(systemName: "macwindow")
                .overlay(Image(systemName: "scribble").font(.system(size: 10, weight: .bold)).offset(y: 3))
        case .boosts:
            // Arc's boost: a brush on a tilted tile, with sparkles.
            ZStack {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .stroke(lineWidth: 1.8)
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(-12))
                Image(systemName: "paintbrush.pointed.fill").font(.system(size: 13, weight: .semibold))
                Image(systemName: "sparkle").font(.system(size: 6, weight: .bold)).offset(x: 6, y: -6)
            }
        case .spaces:
            Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
        default:
            Image(systemName: section.symbol)
        }
    }
}

// MARK: - List column

private struct LibraryListColumn: View {
    let controller: BrowserWindowController
    let section: LibrarySection
    @State private var query = ""
    @State private var spaceFilter: UUID?
    @State private var kindFilter: DownloadKind?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                LibrarySearchField(prompt: section.searchPrompt, text: $query)
                filter
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 6)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var filter: some View {
        switch section {
        case .archive: ArchiveFilter(selection: $spaceFilter)
        case .downloads: DownloadsFilter(selection: $kindFilter)
        case .history: HistoryClearMenu()
        default: EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .archive: ArchiveList(controller: controller, query: query, spaceID: spaceFilter)
        case .history: HistoryList(controller: controller, query: query)
        case .downloads: DownloadsList(query: query, kind: kindFilter)
        case .media: MediaList(query: query)
        case .easelsAndNotes: EaselsAndNotesList(controller: controller, query: query)
        case .boosts: BoostsList(controller: controller, query: query)
        case .spaces: EmptyView()
        }
    }
}

private struct LibrarySearchField: View {
    let prompt: String
    @Binding var text: String
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.subtitle)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(palette.subtitle))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.title)
        }
        .padding(.leading, 15)
        .padding(.trailing, 10)
        .frame(height: 36)
        // Darker than the sidebar's address field, as in Arc.
        .background(ZStack { SidebarControlBackground(); SidebarControlBackground() })
    }
}

/// "Filter" next to the search field.
private struct LibraryFilterMenu<Content: View>: View {
    var title = "Filter"
    var symbol = "line.3.horizontal.decrease.circle"
    let isActive: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.palette) private var palette

    var body: some View {
        Menu(content: content) {
            HStack(spacing: 5) {
                Image(systemName: isActive ? "\(symbol).fill" : symbol).font(.system(size: 13, weight: .medium))
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(isActive ? palette.accent : palette.subtitle)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(SidebarControlBackground())
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct ArchiveFilter: View {
    @Binding var selection: UUID?
    @Environment(BrowserStore.self) private var store

    var body: some View {
        LibraryFilterMenu(isActive: selection != nil) {
            Picker("Space", selection: $selection) {
                Text("All Spaces").tag(UUID?.none)
                Divider()
                ForEach(store.state.spaces) { Text($0.title).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
        }
    }
}

private enum DownloadKind: String, CaseIterable {
    case images = "Images"
    case videos = "Videos"
    case audio = "Audio"
    case documents = "Documents"
    case archives = "Archives"

    func matches(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return switch self {
        case .images: type.conforms(to: .image)
        case .videos: type.conforms(to: .movie)
        case .audio: type.conforms(to: .audio)
        case .documents: type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent)
        case .archives: type.conforms(to: .archive) || type.conforms(to: .diskImage)
        }
    }
}

private struct DownloadsFilter: View {
    @Binding var selection: DownloadKind?

    var body: some View {
        LibraryFilterMenu(isActive: selection != nil) {
            Picker("Kind", selection: $selection) {
                Text("All Downloads").tag(DownloadKind?.none)
                Divider()
                ForEach(DownloadKind.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            .pickerStyle(.inline)
        }
    }
}

private struct HistoryClearMenu: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        LibraryFilterMenu(title: "Clear", symbol: "trash.circle", isActive: false) {
            Button("Last Hour") { store.clearHistory(since: Date().addingTimeInterval(-3600)) }
            Button("Today") { store.clearHistory(since: Calendar.current.startOfDay(for: Date())) }
            Button("All History") { store.clearHistory() }
        }
    }
}

// MARK: - Shared pieces

private func matches(_ query: String, _ values: String...) -> Bool {
    let terms = query.lowercased().split(separator: " ")
    guard !terms.isEmpty else { return true }
    let haystack = values.joined(separator: " ").lowercased()
    return terms.allSatisfy { haystack.contains($0) }
}

/// Items grouped under "Today", "Yesterday", "Earlier This Week", then
/// relative dates ("5 days ago"), as in Arc's Library.
private struct DayGroups<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let date: (Item) -> Date
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.title) { group in
                    LibraryGroupHeader(title: group.title)
                    ForEach(group.items) { row($0) }
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
    }

    private var groups: [(title: String, items: [Item])] {
        var groups: [(title: String, items: [Item])] = []
        for item in items {
            let title = Self.title(for: date(item))
            if groups.last?.title == title {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append((title, [item]))
            }
        }
        return groups
    }

    static func title(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "Earlier This Week" }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .numeric
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        return days < 28 ? formatter.localizedString(from: DateComponents(day: -days))
            : formatter.localizedString(for: date, relativeTo: now)
    }
}

private struct LibraryGroupHeader: View {
    let title: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.subtitle)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
    }
}

/// A row of the list column: icon, title and a second line.
private struct LibraryItemRow<Icon: View, Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let accessory: () -> Accessory
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var isHovered = false

    init(title: String, subtitle: String, @ViewBuilder icon: @escaping () -> Icon,
         @ViewBuilder accessory: @escaping () -> Accessory, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.accessory = accessory
        self.action = action
    }

    var body: some View {
        HStack(spacing: 15) {
            icon().frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(palette.title)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.subtitle)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isHovered ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: action)
        .padding(.horizontal, 12)
    }
}

extension LibraryItemRow where Accessory == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder icon: @escaping () -> Icon, action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, icon: icon, accessory: { EmptyView() }, action: action)
    }
}

/// Centered icon, title and hint shown when a section is empty.
private struct LibraryEmptyState<Message: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let message: () -> Message
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(palette.subtitle.opacity(0.75))
                .frame(height: 46)
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(palette.title)
            message()
                .font(.system(size: 13))
                .foregroundStyle(palette.subtitle)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 30)
    }
}

// MARK: - Sections

private struct ArchiveList: View {
    let controller: BrowserWindowController
    let query: String
    let spaceID: UUID?
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state

    var body: some View {
        let entries = store.state.archive.filter {
            (spaceID == nil || $0.spaceID == spaceID) && matches(query, $0.tab.displayTitle, $0.tab.url)
        }
        if entries.isEmpty {
            LibraryEmptyState(symbol: "archivebox", title: "Nothing here yet!") {
                Text("Tabs you close, and the ones Arrow archives for you, show up here.")
            }
        } else {
            DayGroups(items: entries, date: \.archivedAt) { entry in
                LibraryItemRow(title: entry.tab.displayTitle, subtitle: URLDisplay.full(entry.tab.url)) {
                    FaviconView(url: entry.tab.url, size: 16)
                } action: {
                    var restored: (tab: Tab, spaceID: UUID)?
                    store.update { restored = $0.restoreArchived(entry.id, into: state.selectedSpaceID) }
                    state.sheet = nil
                    if let restored { controller.select(restored.tab.id) }
                }
            }
        }
    }
}

private struct HistoryList: View {
    let controller: BrowserWindowController
    let query: String
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state

    var body: some View {
        let entries = Array(store.history.entries.values
            .filter { matches(query, $0.title, $0.url) }
            .sorted { $0.lastVisit > $1.lastVisit }
            .prefix(500))
        if entries.isEmpty {
            LibraryEmptyState(symbol: "clock", title: "Nothing here yet!") {
                Text("Pages you visit show up here.")
            }
        } else {
            DayGroups(items: entries, date: \.lastVisit) { entry in
                LibraryItemRow(title: entry.title.isEmpty ? entry.url : entry.title, subtitle: URLDisplay.full(entry.url)) {
                    FaviconView(url: entry.url, size: 16)
                } action: {
                    state.sheet = nil
                    controller.openNewTab(entry.url)
                }
                .contextMenu {
                    Button("Remove from History") { store.clearHistoryEntry(entry.url) }
                }
            }
        }
    }
}

private struct DownloadsList: View {
    let query: String
    let kind: DownloadKind?
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let items = store.downloads.items
            .filter { matches(query, $0.fileName, $0.url) && (kind?.matches($0.destination) ?? true) }
            .sorted { $0.startedAt > $1.startedAt }
        if items.isEmpty {
            LibraryEmptyState(symbol: "arrow.down.circle", title: "Nothing here yet!") {
                Text("Come back after you’ve found some cool stuff to save.")
            }
        } else {
            DayGroups(items: items, date: \.startedAt) { item in
                LibraryItemRow(title: item.fileName, subtitle: detail(item)) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.destination.path)).resizable()
                } accessory: {
                    accessory(item)
                } action: {
                    if item.state == .complete { store.downloads.open(item) }
                }
                .contextMenu {
                    if item.state == .complete {
                        Button("Open") { store.downloads.open(item) }
                        Button("Show in Finder") { store.downloads.reveal(item) }
                    }
                }
            }
        }
    }

    private func detail(_ item: DownloadManager.Item) -> String {
        let size = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return switch item.state {
        case .inProgress, .paused: "\(size(item.receivedBytes)) of \(size(item.totalBytes))"
        case .complete: size(item.totalBytes)
        case .canceled: "Canceled"
        case .interrupted: "Failed"
        }
    }

    @ViewBuilder private func accessory(_ item: DownloadManager.Item) -> some View {
        HStack(spacing: 6) {
            switch item.state {
            case .inProgress:
                Button { store.downloads.pause(item) } label: { Image(systemName: "pause.circle") }
                Button { store.downloads.cancel(item) } label: { Image(systemName: "xmark.circle") }
            case .paused:
                Button { store.downloads.resume(item) } label: { Image(systemName: "play.circle") }
                Button { store.downloads.cancel(item) } label: { Image(systemName: "xmark.circle") }
            case .complete:
                Button { store.downloads.reveal(item) } label: { Image(systemName: "magnifyingglass.circle") }
                    .help("Show in Finder")
            default:
                EmptyView()
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14))
    }
}

private struct MediaList: View {
    let query: String
    @Environment(BrowserStore.self) private var store
    @State private var items: [MediaLibrary.Item] = []

    var body: some View {
        let shown = items.filter { matches(query, $0.url.lastPathComponent) }
        Group {
            if shown.isEmpty {
                LibraryEmptyState(symbol: "photo.on.rectangle.angled", title: "Nothing here yet!") {
                    Text("Captures (⇧⌘2) and the images and videos you download show up here.")
                }
            } else {
                DayGroups(items: shown, date: \.date) { item in
                    MediaRow(item: item) {
                        items.removeAll { $0 == item }
                    }
                }
            }
        }
        .onAppear { items = MediaLibrary.items(store) }
    }
}

private struct EaselsAndNotesList: View {
    let controller: BrowserWindowController
    let query: String
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state

    private struct Entry: Identifiable {
        var id: UUID
        var title: String
        var url: String
        var updatedAt: Date
        var isNote: Bool
        var detail: String
    }

    var body: some View {
        let entries = (store.notes.map { Entry(id: $0.id, title: $0.title, url: $0.url, updatedAt: $0.updatedAt, isNote: true,
                                               detail: "Note") }
            + store.easels.map { Entry(id: $0.id, title: $0.title, url: $0.url, updatedAt: $0.updatedAt, isNote: false,
                                       detail: $0.items.count == 1 ? "1 item" : "\($0.items.count) items") })
            .filter { matches(query, $0.title) }
            .sorted { $0.updatedAt > $1.updatedAt }
        if entries.isEmpty {
            LibraryEmptyState(symbol: "doc.plaintext", title: "Out of ideas!") {
                Text("Click the + sign in the Sidebar to create a new Easel.")
            }
        } else {
            DayGroups(items: entries, date: \.updatedAt) { entry in
                LibraryItemRow(title: entry.title, subtitle: entry.detail) {
                    Image(systemName: entry.isNote ? "note.text" : "scribble.variable")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                } action: {
                    state.sheet = nil
                    controller.openNewTab(entry.url)
                }
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        if entry.isNote { store.deleteNote(entry.id) } else { store.deleteEasel(entry.id) }
                    }
                }
            }
        }
    }
}

private struct BoostsList: View {
    let controller: BrowserWindowController
    let query: String
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state

    var body: some View {
        let boosts = store.boosts.filter { matches(query, $0.name, $0.domain) }
        if boosts.isEmpty {
            LibraryEmptyState(symbol: "paintbrush.pointed", title: "Nothing Boosted Yet!") {
                Text("Click \(Image(systemName: "paintbrush.pointed")) in the URL bar to make your own.")
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(boosts) { boost in
                        LibraryItemRow(title: boost.name, subtitle: boost.domain) {
                            FaviconView(url: "https://\(boost.domain)", size: 16)
                        } accessory: {
                            Toggle("", isOn: Binding(get: { boost.isEnabled }, set: { enabled in
                                var updated = boost
                                updated.isEnabled = enabled
                                store.saveBoost(updated)
                            }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                        } action: {
                            state.sheet = .boostEditor(boostID: boost.id, url: "https://\(boost.domain)")
                        }
                        .contextMenu {
                            Button("Edit Boost…") { state.sheet = .boostEditor(boostID: boost.id, url: "https://\(boost.domain)") }
                            Divider()
                            Button("Delete Boost", role: .destructive) { store.deleteBoost(boost.id) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: - Spaces

/// Library ▸ Spaces: one card per space, in sidebar order.
private struct SpacesBoard: View {
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 24) {
                    ForEach(store.state.spaces) { space in
                        SpaceCard(space: space)
                    }
                }
                .padding(.leading, 29)
                .padding(.vertical, 49)
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: true, vertical: false)

            Button { state.sheet = .spaceEditor(spaceID: nil) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(palette.isDark ? 0.15 : 0.9)))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            }
            .buttonStyle(.plain)
            .help("New Space")
            .padding(.leading, 36)
            .padding(.trailing, 42)
        }
    }
}

private struct SpaceCard: View {
    let space: Space
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state
    @Environment(\.colorScheme) private var colorScheme
    @State private var isTargeted = false

    private var palette: ThemePalette {
        space.theme.palette(isDark: space.theme.isDark(systemIsDark: colorScheme == .dark))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                SpaceIconView(icon: space.icon, size: 11)
                Text(space.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button { state.sheet = .spaceEditor(spaceID: space.id) } label: {
                    Image(systemName: "pencil").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Edit Space")
            }
            .foregroundStyle(Color(palette.title).opacity(0.75))
            .padding(.horizontal, 16)
            .frame(height: 48)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(space.pinned) { node in
                    SpaceCardRow(node: node, palette: palette)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 0)

            HStack {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .help("Drag to reorder")
                Spacer()
                Menu {
                    Button("Edit Space…") { state.sheet = .spaceEditor(spaceID: space.id) }
                    Divider()
                    Button("Delete Space", role: .destructive) { store.update { $0.deleteSpace(space.id) } }
                        .disabled(store.state.spaces.count < 2)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(palette.title).opacity(0.6))
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
        .frame(width: 240)
        .background(ThemeBackground(palette: palette))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(isTargeted ? 0.8 : 0), lineWidth: 2))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .draggable(space.id.uuidString)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first.flatMap(UUID.init(uuidString:)), id != space.id else { return false }
            store.update { state in
                guard let source = state.spaces.firstIndex(where: { $0.id == id }),
                      let target = state.spaces.firstIndex(where: { $0.id == space.id }) else { return }
                state.moveSpace(from: source, to: target)
            }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

private struct SpaceCardRow: View {
    let node: SidebarNode
    let palette: ThemePalette

    var body: some View {
        HStack(spacing: 8) {
            switch node {
            case let .tab(tab):
                FaviconView(url: tab.url, size: 14)
                Text(tab.displayTitle)
            case let .folder(folder):
                Image(systemName: "folder").font(.system(size: 11, weight: .medium)).frame(width: 14)
                Text(folder.title)
            case let .split(split):
                Image(systemName: "rectangle.split.2x1").font(.system(size: 11, weight: .medium)).frame(width: 14)
                Text(split.tabs.map(\.displayTitle).joined(separator: " | "))
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color(palette.title).opacity(0.85))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: 26)
    }
}
