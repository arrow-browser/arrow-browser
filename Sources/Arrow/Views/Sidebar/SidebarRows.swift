import ArrowCore
import ArrowKit
import CEF
import SwiftUI
import UniformTypeIdentifiers

/// A pinned or today entry: tab, folder or split view.
struct SidebarNodeView: View {
    let node: SidebarNode
    let section: SidebarSection
    let spaceID: UUID
    let controller: BrowserWindowController
    let depth: Int
    @Environment(BrowserStore.self) private var store

    var body: some View {
        switch node {
        case let .tab(tab):
            SidebarTabRow(tab: tab, section: section, controller: controller)
                .padding(.leading, CGFloat(depth) * 14)
                .onDrop(of: [.arrowSidebarItem, .url], delegate: SidebarDropDelegate(store: store, location: location(before: tab.id)))
        case let .folder(folder):
            FolderRow(folder: folder, spaceID: spaceID, controller: controller, depth: depth)
        case let .split(split):
            SplitRow(split: split, section: section, controller: controller)
                .padding(.leading, CGFloat(depth) * 14)
                .onDrop(of: [.arrowSidebarItem, .url], delegate: SidebarDropDelegate(store: store, location: location(before: split.id)))
        }
    }

    /// Drop location that inserts before `id` in its list.
    private func location(before id: UUID) -> SidebarLocation {
        guard let space = store.state.space(spaceID) else {
            return SidebarLocation(spaceID: spaceID, section: section)
        }
        let list = section == .pinned ? space.pinned : space.today
        if let index = list.firstIndex(where: { $0.id == id }) {
            return SidebarLocation(spaceID: spaceID, section: section, index: index)
        }
        if let folder = Self.parentFolder(of: id, in: list) {
            let index = folder.children.firstIndex { $0.id == id }
            return SidebarLocation(spaceID: spaceID, section: section, folderID: folder.id, index: index)
        }
        return SidebarLocation(spaceID: spaceID, section: section)
    }

    private static func parentFolder(of id: UUID, in nodes: [SidebarNode]) -> Folder? {
        for node in nodes {
            guard case let .folder(folder) = node else { continue }
            if folder.children.contains(where: { $0.id == id }) { return folder }
            if let nested = parentFolder(of: id, in: folder.children) { return nested }
        }
        return nil
    }
}

/// Row of a tab in the sidebar.
struct SidebarTabRow: View {
    let tab: Tab
    let section: SidebarSection
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state
    @Environment(\.palette) private var palette
    @State private var isHovered = false
    @State private var editedTitle = ""

    var body: some View {
        let live = store.tabs[tab.id]
        let isSelected = controller.displayedTabIDs.contains(tab.id) && controller.selectedSplit == nil
        HStack(spacing: 9.5) {
            ZStack(alignment: .bottomTrailing) {
                FaviconView(url: live?.url ?? tab.url, image: live?.favicon?.nsImage, size: 16)
                if live?.isLoading == true {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                        .offset(x: 4, y: 4)
                }
            }
            .frame(width: 18)

            if state.renamingNodeID == tab.id {
                TextField("Title", text: $editedTitle)
                    .textFieldStyle(.plain)
                    .onAppear { editedTitle = tab.displayTitle }
                    .onSubmit(commitRename)
                    .onExitCommand { state.renamingNodeID = nil }
            } else {
                Text(tab.customTitle ?? live?.displayTitle ?? store.title(of: tab))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if live?.isPlayingMedia == true || live?.isMuted == true {
                Button {
                    live?.isMuted.toggle()
                    if let live { store.syncTabModel(live) }
                } label: {
                    Image(systemName: live?.isMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(live?.isMuted == true ? "Unmute Tab" : "Mute Tab")
            }
            if live?.isCameraActive == true || live?.isMicrophoneActive == true {
                Image(systemName: live?.isCameraActive == true ? "video.fill" : "mic.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
            }
            if isHovered {
                trailingButtons(live: live)
            }
        }
        .font(.system(size: 13.5, weight: .medium))
        .foregroundStyle(palette.title)
        .padding(.horizontal, 8.5)
        .frame(height: 35)
        .background(rowBackground(isSelected: isSelected))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { controller.select(tab.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if section == .pinned { state.renamingNodeID = tab.id }
        })
        .onDrag { .sidebarItem(tab.id) }
        .contextMenu { SidebarTabMenu(tab: tab, controller: controller) }
        .help(live?.url ?? tab.url)
    }

    @ViewBuilder
    private func trailingButtons(live: WebTab?) -> some View {
        if section == .pinned, tab.hasNavigatedAwayFromPinnedURL, let pinnedURL = tab.pinnedURL {
            Button {
                live?.load(pinnedURL)
                store.update { $0.updateTab(tab.id) { $0.url = pinnedURL } }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Back to Pinned URL")
        }
        Button {
            controller.closeTab(tab.id)
        } label: {
            Image(systemName: section == .pinned ? "minus" : "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(palette.icon)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(palette.hover))
        }
        .buttonStyle(.plain)
        .help(section == .pinned ? "Unload Tab" : "Archive Tab (⌘W)")
    }

    private func rowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isSelected ? palette.selection : (isHovered ? palette.hover : .clear))
            .shadow(color: .black.opacity(isSelected ? 0.07 : 0), radius: 2, x: 0, y: 1)
    }

    private func commitRename() {
        let title = editedTitle.trimmingCharacters(in: .whitespaces)
        store.update { $0.updateTab(tab.id) { $0.customTitle = title.isEmpty ? nil : title } }
        state.renamingNodeID = nil
    }
}

/// A folder of pinned items (expand/collapse, drop into).
struct FolderRow: View {
    let folder: Folder
    let spaceID: UUID
    let controller: BrowserWindowController
    let depth: Int
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state
    @Environment(\.palette) private var palette
    @State private var isHovered = false
    @State private var isTargeted = false
    @State private var editedTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(systemName: folder.isExpanded ? "folder" : "folder.fill")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                if state.renamingNodeID == folder.id {
                    TextField("Folder name", text: $editedTitle)
                        .textFieldStyle(.plain)
                        .onAppear { editedTitle = folder.title }
                        .onSubmit {
                            store.update { $0.renameFolder(folder.id, to: editedTitle) }
                            state.renamingNodeID = nil
                        }
                        .onExitCommand { state.renamingNodeID = nil }
                } else {
                    Text(folder.title).lineLimit(1)
                }
                Spacer(minLength: 0)
                if isHovered {
                    Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.subtitle)
                }
            }
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(palette.title.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isTargeted ? palette.selection : (isHovered ? palette.hover : .clear))
            )
            .padding(.leading, CGFloat(depth) * 14)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture { store.update { $0.toggleFolder(folder.id) } }
            .simultaneousGesture(TapGesture(count: 2).onEnded { state.renamingNodeID = folder.id })
            .onDrag { .sidebarItem(folder.id) }
            .onDrop(of: [.arrowSidebarItem, .url], delegate: SidebarDropDelegate(
                store: store, location: SidebarLocation(spaceID: spaceID, section: .pinned, folderID: folder.id),
                isTargeted: $isTargeted))
            .contextMenu {
                Button("Rename Folder") { state.renamingNodeID = folder.id }
                Button(folder.isExpanded ? "Collapse" : "Expand") { store.update { $0.toggleFolder(folder.id) } }
                Button("Share Folder…") { controller.share(kind: "folder", title: folder.title, tabs: folder.children.allTabs) }
                Divider()
                Button("Delete Folder", role: .destructive) { store.delete(folder.id) }
            }

            if folder.isExpanded {
                ForEach(folder.children) { child in
                    SidebarNodeView(node: child, section: .pinned, spaceID: spaceID, controller: controller, depth: depth + 1)
                }
            }
        }
    }
}

/// A split view entry: favicons and titles of its panes.
struct SplitRow: View {
    let split: SplitView
    let section: SidebarSection
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        let isSelected = controller.selectedSplit?.id == split.id
        HStack(spacing: 6) {
            ForEach(Array(split.tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 {
                    Rectangle()
                        .fill(palette.subtitle.opacity(0.35))
                        .frame(width: 1, height: 16)
                }
                HStack(spacing: 6) {
                    FaviconView(url: tab.url, image: store.tabs[tab.id]?.favicon?.nsImage, size: 14)
                    if split.tabs.count <= 2 {
                        Text(store.tabs[tab.id]?.displayTitle ?? tab.displayTitle)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { controller.select(tab.id) }
            }
            if isHovered {
                Button {
                    for tab in split.tabs { controller.closeTab(tab.id) }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(palette.title.opacity(0.85))
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? palette.selection : (isHovered ? palette.hover : .clear))
                .shadow(color: .black.opacity(isSelected ? 0.07 : 0), radius: 2, y: 1)
        )
        .onHover { isHovered = $0 }
        .onDrag { .sidebarItem(split.id) }
        .contextMenu {
            Button("Separate Split View") { store.update { $0.dissolveSplit(split.id) } }
            Button(split.axis == .horizontal ? "Stack Vertically" : "Arrange Side by Side") {
                store.update { $0.updateSplit(split.id) { $0.axis = $0.axis == .horizontal ? .vertical : .horizontal } }
            }
        }
    }
}

/// Context menu of a tab row or favorite.
struct SidebarTabMenu: View {
    let tab: Tab
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state

    var body: some View {
        let isFavorite = store.state.isFavorite(tab.id)
        let isPinned = store.state.isPinned(tab.id)
        Button("Copy Link") { controller.copyToPasteboard(tab.url, toast: "Copied URL to clipboard") }
        Button("Rename…") { state.renamingNodeID = tab.id }
        Button("Duplicate") { controller.openNewTab(tab.url) }
        Divider()
        if !isFavorite {
            Button(isPinned ? "Unpin Tab" : "Pin Tab") { store.update { $0.togglePin(tab.id) } }
            Button("Add to Favorites") { store.update { $0.move(tab.id, to: .favorites()) } }
        } else {
            Button("Remove from Favorites") {
                store.update { $0.move(tab.id, to: SidebarLocation(spaceID: state.selectedSpaceID, section: .today, index: 0)) }
            }
        }
        if let selected = state.selectedTabID, selected != tab.id {
            Button("Open in Split View") {
                store.update { $0.addToSplit(tab.id, with: selected) }
                controller.select(tab.id)
            }
        }
        if store.state.spaces.count > 1, !isFavorite {
            Menu("Move to Space") {
                ForEach(store.state.spaces.filter { $0.id != store.state.spaceID(containing: tab.id) }) { space in
                    Button(space.title) {
                        store.update { $0.move(tab.id, to: SidebarLocation(spaceID: space.id, section: isPinned ? .pinned : .today, index: 0)) }
                    }
                }
            }
        }
        if let live = store.tabs[tab.id], live.isEngineLoaded {
            Button(live.isMuted ? "Unmute Tab" : "Mute Tab") { live.isMuted.toggle() }
        }
        Divider()
        if isPinned || isFavorite {
            Button("Delete", role: .destructive) { store.delete(tab.id) }
        } else {
            Button("Close Tab") { controller.closeTab(tab.id) }
        }
    }
}

extension UTType {
    /// Sidebar items being dragged (tab, folder, split). A private type, so
    /// web content does not accept these drags.
    static let arrowSidebarItem = UTType(exportedAs: "com.euskadi31.arrow.sidebar-item")
}

extension NSItemProvider {
    /// Provider for dragging the sidebar node `id`.
    static func sidebarItem(_ id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.arrowSidebarItem.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    /// Loads the UUID of a dragged sidebar item.
    func loadSidebarItem(_ completion: @escaping @Sendable (UUID?) -> Void) {
        _ = loadDataRepresentation(forTypeIdentifier: UTType.arrowSidebarItem.identifier) { data, _ in
            completion(data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(UUID.init(uuidString:)))
        }
    }
}

/// Moves dragged sidebar items; links dropped from pages open as tabs.
struct SidebarDropDelegate: DropDelegate {
    let store: BrowserStore
    let location: SidebarLocation
    var isTargeted: Binding<Bool>?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.arrowSidebarItem, .url])
    }

    func dropEntered(info: DropInfo) {
        isTargeted?.wrappedValue = true
    }

    func dropExited(info: DropInfo) {
        isTargeted?.wrappedValue = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted?.wrappedValue = false
        if store.settings.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        let store = store
        let location = location
        if let provider = info.itemProviders(for: [.arrowSidebarItem]).first {
            provider.loadSidebarItem { id in
                guard let id else { return }
                Task { @MainActor in
                    guard id != location.folderID else { return }
                    store.update { $0.move(id, to: location) }
                }
            }
            return true
        }
        guard let provider = info.itemProviders(for: [.url]).first, let spaceID = location.spaceID else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.scheme == "http" || url.scheme == "https" else { return }
            // A link dropped from a page opens as a new tab.
            Task { @MainActor in store.update { $0.openTab(url: url.absoluteString, in: spaceID) } }
        }
        return true
    }
}

/// "Site controls" popover of the address field: zoom, permissions,
/// boosts, cookies.
struct SiteControlsButton: View {
    let tab: WebTab
    let controller: BrowserWindowController
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .buttonStyle(.plain)
        .help("Site Controls")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SiteControlsView(tab: tab, controller: controller)
        }
    }
}

private struct SiteControlsView: View {
    let tab: WebTab
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                FaviconView(url: tab.url, image: tab.favicon?.nsImage, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(URLDisplay.short(tab.url)).font(.headline)
                    Text(tab.url.hasPrefix("https://") ? "Connection is secure" : "Connection is not secure")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text("Zoom")
                Spacer()
                Button { tab.zoomOut() } label: { Image(systemName: "minus") }
                Text("\(Int((pow(1.2, tab.zoomLevel) * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 48)
                Button { tab.zoomIn() } label: { Image(systemName: "plus") }
            }
            if store.settings.adBlockerEnabled {
                Toggle("Block ads and trackers", isOn: Binding(
                    get: { !store.adBlocker.isAllowed(site: tab.url) },
                    set: { block in
                        store.adBlocker.setAllowed(!block, site: tab.url)
                        tab.reload()
                    }))
                    .toggleStyle(.switch)
            }
            Button("Zap Elements…") { controller.zapElements(nil) }
            Button("Translate Page") { controller.translatePage(nil) }
            HStack {
                Text("Boosts")
                Spacer()
                Button(store.boosts(for: tab.url).isEmpty ? "Boost this Site…" : "Edit Boost…") {
                    controller.tabRequestsBoostEditor(tab)
                }
            }
            Divider()
            SitePermissionsView(tab: tab)
            Divider()
            Button("Clear Cookies and Refresh") { controller.clearCookiesAndReload(nil) }
            Button("Clear Cache and Refresh") { controller.clearCacheAndReload(nil) }
            Button("Share…") { controller.sharePage(nil) }
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(width: 280)
    }
}

/// Saved permissions of the current site (Chromium content settings).
private struct SitePermissionsView: View {
    let tab: WebTab
    @Environment(BrowserStore.self) private var store
    @State private var refresh = 0

    private static let rows: [(String, String, cef_content_setting_types_t)] = [
        ("Camera", "video", CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA),
        ("Microphone", "mic", CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC),
        ("Location", "location", CEF_CONTENT_SETTING_TYPE_GEOLOCATION),
        ("Notifications", "bell", CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS),
        ("Pop-ups", "macwindow.on.rectangle", CEF_CONTENT_SETTING_TYPE_POPUPS),
        ("Sound", "speaker.wave.2", CEF_CONTENT_SETTING_TYPE_SOUND),
    ]

    var body: some View {
        let context = store.cefContext(for: tab.profileID)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.rows, id: \.0) { title, symbol, type in
                HStack {
                    Label(title, systemImage: symbol)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { _ = refresh; return context.contentSetting(url: tab.url, type: type).rawValue },
                        set: { value in
                            context.setContentSetting(url: tab.url, type: type, value: cef_content_setting_values_t(rawValue: value))
                            refresh += 1
                        })) {
                        Text("Ask").tag(CEF_CONTENT_SETTING_VALUE_DEFAULT.rawValue)
                        Text("Allow").tag(CEF_CONTENT_SETTING_VALUE_ALLOW.rawValue)
                        Text("Block").tag(CEF_CONTENT_SETTING_VALUE_BLOCK.rawValue)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }
}

/// Mini player shown when a tab that is not visible plays media.
struct MediaControlsView: View {
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var palette

    var body: some View {
        let visible = Set(controller.displayedTabIDs)
        if let tab = store.tabs.values.first(where: { $0.isPlayingMedia && !visible.contains($0.id) && store.state.tab($0.id) != nil }) {
            HStack(spacing: 10) {
                FaviconView(url: tab.url, image: tab.favicon?.nsImage, size: 16)
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button { tab.playPauseMedia() } label: { Image(systemName: "pause.fill") }
                    .buttonStyle(.plain)
                Button { tab.isMuted.toggle() } label: {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(palette.title)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(SidebarControlBackground(cornerRadius: 10))
            .contentShape(Rectangle())
            .onTapGesture { controller.select(tab.id) }
            .padding(.top, 6)
        }
    }
}
