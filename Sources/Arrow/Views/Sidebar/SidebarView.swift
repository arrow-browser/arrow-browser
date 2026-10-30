import ArrowCore
import ArrowKit
import SwiftUI
import UniformTypeIdentifiers

/// Arc's sidebar: navigation header, address field, favorites, the spaces
/// (swipe between them) and the space switcher.
struct SidebarView: View {
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            SidebarTopBar(controller: controller)
            if store.settings.showURLBar && !store.settings.showToolbar {
                SidebarURLField(controller: controller)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
            FavoritesGrid(controller: controller)
                .padding(.horizontal, 8)
            SpacePager(controller: controller)
            MediaControlsView(controller: controller)
                .padding(.horizontal, 8)
            UpdateReadyButton()
                .padding(.horizontal, 8)
            SidebarBottomBar(controller: controller)
        }
    }
}

// MARK: - Header

struct SidebarTopBar: View {
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state

    var body: some View {
        let tab = controller.selectedTab
        HStack(spacing: 6) {
            // Room for the traffic lights.
            Color.clear.frame(width: store.settings.sidebarOnRight ? 0 : 64, height: 1)
            ChromeButton(symbol: "sidebar.left", help: "Hide Sidebar (⌘S)") {
                controller.setSidebarVisible(!state.isSidebarVisible)
            }
            Spacer(minLength: 0)
            if !store.settings.showToolbar {
                NavigationButtons(tab: tab)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: ArrowWindow.trafficLightCenterY * 2)
        .background(WindowDragArea())
    }
}

/// Back, forward and reload (sidebar header or toolbar).
struct NavigationButtons: View {
    let tab: WebTab?

    var body: some View {
        HStack(spacing: 6) {
            ChromeButton(symbol: "arrow.left", help: "Go Back (⌘[)", isEnabled: tab?.canGoBack ?? false) {
                tab?.goBack()
            }
            ChromeButton(symbol: "arrow.right", help: "Go Forward (⌘])", isEnabled: tab?.canGoForward ?? false) {
                tab?.goForward()
            }
            ChromeButton(symbol: tab?.isLoading == true ? "xmark" : "arrow.clockwise", help: "Reload (⌘R)",
                         isEnabled: tab?.engine != nil) {
                if tab?.isLoading == true { tab?.stopLoading() } else { tab?.reload() }
            }
        }
    }
}

// MARK: - Address field

struct SidebarURLField: View {
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state
    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        let tab = controller.selectedTab
        // Notes and easels show their name, like Arc.
        let text = tab.map { tab in
            if tab.internalPage != nil { return tab.displayTitle }
            return store.settings.developerMode ? URLDisplay.full(tab.url) : URLDisplay.short(tab.url)
        } ?? ""
        HStack(spacing: 7) {
            if text.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.subtitle)
                Text("Search or Enter URL…")
                    .foregroundStyle(palette.subtitle)
            } else {
                if tab?.url.hasPrefix("https://") == false, tab?.url.hasPrefix("http://") == true {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.subtitle)
                }
                Text(text)
                    .foregroundStyle(palette.title.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if isHovered, let tab, tab.engine != nil {
                Button {
                    controller.copyURL(nil)
                } label: {
                    Image(systemName: "link")
                }
                .buttonStyle(.plain)
                .help("Copy URL (⇧⌘C)")
                ExtensionsMenuButton(controller: controller)
                SiteControlsButton(tab: tab, controller: controller)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(palette.icon)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(SidebarControlBackground(cornerRadius: 10))
        .overlay(alignment: .bottom) {
            if let tab, tab.isLoading {
                LoadingGlow(progress: tab.progress)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { controller.openCommandBar(nil) }
    }
}

/// Arc's glowing progress line under the address field.
private struct LoadingGlow: View {
    var progress: Double
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(palette.accent)
                .frame(width: max(proxy.size.width * progress, 12), height: 2)
                .shadow(color: palette.accent.opacity(0.8), radius: 4)
                .animation(.easeOut(duration: 0.25), value: progress)
        }
        .frame(height: 2)
        .padding(.horizontal, 8)
        .padding(.bottom, 1)
    }
}

// MARK: - Favorites

struct FavoritesGrid: View {
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state

    var body: some View {
        let profileID = store.state.space(state.selectedSpaceID)?.profileID ?? store.state.defaultProfile.id
        let favorites = store.state.favorites(for: profileID)
        let columns = favorites.count <= 4 ? max(favorites.count, 1) : (favorites.count <= 6 ? 3 : 4)
        Group {
            if favorites.isEmpty {
                Color.clear.frame(height: 4)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                    ForEach(favorites) { favorite in
                        FavoriteTile(tab: favorite, controller: controller)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .onDrop(of: [.arrowSidebarItem, .url], delegate: SidebarDropDelegate(store: store, location: .favorites()))
    }
}

private struct FavoriteTile: View {
    let tab: Tab
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state
    @Environment(\.palette) private var palette
    @State private var isHovered = false
    @State private var showsPreview = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        let isSelected = controller.displayedTabIDs.contains(tab.id)
        let live = store.tabs[tab.id]
        ZStack(alignment: .topTrailing) {
            FaviconView(url: tab.url, image: live?.favicon?.nsImage, size: 16)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? palette.selection : (isHovered ? palette.controlFill.opacity(1.6) : palette.controlFill))
                        .shadow(color: .black.opacity(isSelected ? 0.08 : 0), radius: 2, y: 1)
                )
            if live?.isPlayingMedia == true {
                Image(systemName: live?.isMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(palette.icon)
                    .padding(5)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            hoverTask?.cancel()
            guard hovering else {
                showsPreview = false
                return
            }
            // Arc's glance: a preview after resting on a favorite.
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, !controller.displayedTabIDs.contains(tab.id) else { return }
                showsPreview = true
            }
        }
        .onTapGesture {
            showsPreview = false
            controller.select(tab.id)
        }
        .popover(isPresented: $showsPreview, arrowEdge: store.settings.sidebarOnRight ? .leading : .trailing) {
            FavoritePreview(tab: tab, live: live)
        }
        .onDrag { .sidebarItem(tab.id) }
        .contextMenu { SidebarTabMenu(tab: tab, controller: controller) }
    }
}

/// Hover preview of a favorite: last rendering of the page and its title.
private struct FavoritePreview: View {
    let tab: Tab
    let live: WebTab?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot = live?.snapshot?.nsImage {
                Image(nsImage: snapshot)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 340, height: 220, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(spacing: 8) {
                FaviconView(url: tab.url, image: live?.favicon?.nsImage, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(live?.displayTitle ?? tab.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(URLDisplay.short(live?.url ?? tab.url))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(width: 360, alignment: .leading)
    }
}

// MARK: - Spaces

/// Horizontally paged list of spaces (two-finger swipe to switch).
struct SpacePager: View {
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state
    @State private var visibleSpaceID: UUID?

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(store.state.spaces) { space in
                    SpacePage(space: space, controller: controller)
                        .containerRelativeFrame(.horizontal)
                        .id(space.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.never)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visibleSpaceID)
        .onAppear { visibleSpaceID = state.selectedSpaceID }
        .onChange(of: state.selectedSpaceID) { _, newValue in
            if visibleSpaceID != newValue {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { visibleSpaceID = newValue }
            }
        }
        .onChange(of: visibleSpaceID) { _, newValue in
            if let newValue, newValue != state.selectedSpaceID { controller.selectSpace(newValue) }
        }
    }
}

/// One space: its name, pinned tabs, the "New Tab" row and today's tabs.
struct SpacePage: View {
    let space: Space
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollViewReader { reader in
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                SpaceHeader(space: space, controller: controller)

                if !state.isPinnedCollapsed {
                    ForEach(space.pinned) { node in
                        SidebarNodeView(node: node, section: .pinned, spaceID: space.id, controller: controller, depth: 0)
                    }
                }
                Color.clear
                    .frame(height: space.pinned.isEmpty ? 2 : 6)
                    .contentShape(Rectangle())
                    .onDrop(of: [.arrowSidebarItem, .url], delegate: SidebarDropDelegate(
                        store: store, location: SidebarLocation(spaceID: space.id, section: .pinned)))

                TodayDivider(space: space, controller: controller)
                NewTabRow(controller: controller)

                ForEach(space.today) { node in
                    SidebarNodeView(node: node, section: .today, spaceID: space.id, controller: controller, depth: 0)
                }
                Color.clear
                    .frame(minHeight: 80)
                    .contentShape(Rectangle())
                    .onDrop(of: [.arrowSidebarItem, .url], delegate: SidebarDropDelegate(
                        store: store, location: SidebarLocation(spaceID: space.id, section: .today, index: space.today.count)))
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.never)
        .onChange(of: state.revealRequest) {
            guard let id = state.selectedTabID else { return }
            withAnimation { reader.scrollTo(id, anchor: .center) }
        }
        }
    }
}

private struct SpaceHeader: View {
    let space: Space
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state
    @Environment(\.palette) private var palette
    @State private var title = ""

    var body: some View {
        HStack(spacing: 6) {
            // Arc shows no icon next to the name of a space without one.
            if space.icon != nil {
                SpaceIconView(icon: space.icon, size: 12)
                    .foregroundStyle(palette.subtitle)
            }
            if state.renamingNodeID == space.id {
                TextField("Space name", text: $title)
                    .textFieldStyle(.plain)
                    .onAppear { title = space.title }
                    .onSubmit {
                        store.update { $0.updateSpace(space.id) { $0.title = title } }
                        state.renamingNodeID = nil
                    }
                    .onExitCommand { state.renamingNodeID = nil }
            } else {
                Text(space.title)
                    .lineLimit(1)
            }
            Spacer()
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(palette.subtitle)
        .padding(.leading, 8)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.renamingNodeID = space.id }
        .contextMenu {
            Button("Rename Space") { state.renamingNodeID = space.id }
            Button("Edit Theme…") { state.sheet = .spaceEditor(spaceID: space.id) }
            Button("Share Space…") { controller.share(kind: "space", title: space.title, tabs: space.pinned.allTabs) }
            Divider()
            Button("New Folder") {
                controller.selectSpace(space.id)
                controller.newFolder(nil)
            }
            Divider()
            Button("Delete Space", role: .destructive) {
                store.update { $0.deleteSpace(space.id) }
                if state.selectedSpaceID == space.id, let first = store.state.spaces.first {
                    controller.selectSpace(first.id)
                }
            }
            .disabled(store.state.spaces.count <= 1)
        }
    }
}

/// Separator between pinned and today tabs, with Arc's "Clear" button.
private struct TodayDivider: View {
    let space: Space
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var palette
    @State private var isHovered = false
    @State private var isTidying = false

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(palette.subtitle.opacity(space.pinned.isEmpty ? 0 : 0.25))
                .frame(height: 1)
            if AIFeatures.canTidy(space, store: store) {
                // Max ▸ Tidy Tabs.
                Button {
                    isTidying = true
                    Task {
                        await AIFeatures.tidyToday(in: space, store: store)
                        isTidying = false
                    }
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.subtitle)
                        .symbolEffect(.pulse, isActive: isTidying)
                }
                .buttonStyle(.plain)
                .disabled(isTidying)
                .help("Tidy Tabs")
            }
            if isHovered, !space.today.isEmpty {
                Button {
                    controller.selectSpace(space.id)
                    controller.clearUnpinnedTabs(nil)
                } label: {
                    Label("Clear", systemImage: "arrow.down")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.subtitle)
                }
                .buttonStyle(.plain)
                .help("Archive all unpinned tabs (⇧⌘K)")
            }
        }
        .frame(height: space.pinned.isEmpty ? 0 : 20)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

private struct NewTabRow: View {
    let controller: BrowserWindowController
    @Environment(WindowState.self) private var state
    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        let isActive = state.commandBar?.mode == .newTab
        HStack(spacing: 9.5) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 18)
            Text("New Tab")
            Spacer()
        }
        .font(.system(size: 13.5, weight: .medium))
        .foregroundStyle(palette.title)
        .padding(.horizontal, 8.5)
        .frame(height: 35)
        .background(
            // While the command bar is open Arc shows a faint placeholder row.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? Color.white.opacity(palette.isDark ? 0.1 : 0.35) : (isHovered ? palette.hover : .clear))
                .shadow(color: .black.opacity(isActive ? 0.08 : 0), radius: 1.5, y: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { controller.newTab(nil) }
    }
}

// MARK: - Bottom bar

/// Shown once a verified update is ready, like Arc's "Restart to update".
private struct UpdateReadyButton: View {
    @State private var updater = Updater.shared
    @Environment(\.palette) private var palette

    var body: some View {
        if case let .ready(version) = updater.phase {
            Button { updater.installAndRelaunch() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Restart to Update")
                    Spacer()
                    Text(version).foregroundStyle(palette.subtitle)
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(palette.title)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(SidebarControlBackground(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
    }
}

struct SidebarBottomBar: View {
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            ChromeButton(symbol: store.downloads.activeCount > 0 ? "arrow.down.circle" : "archivebox", help: "Library (⇧⌘L)",
                         size: 15) {
                state.sheet = .library(store.downloads.activeCount > 0 ? .downloads : .archive)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(store.state.spaces) { space in
                    SpaceSwitcherButton(space: space, isSelected: space.id == state.selectedSpaceID) {
                        controller.selectSpace(space.id)
                    }
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button("New Space…") { controller.newSpace(nil) }
                Button("New Folder") { controller.newFolder(nil) }
                Button("New Split View") { controller.addSplitView(nil) }
                Divider()
                Button("New Note") { controller.newNote(nil) }
                Button("New Easel") { controller.newEasel(nil) }
                Button("New Boost") { controller.newBoost(nil) }
                Divider()
                Button("New Profile…") { (NSApp.delegate as? AppDelegate)?.newProfile(nil) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.icon)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(controller.isIncognito)
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
    }
}

private struct SpaceSwitcherButton: View {
    let space: Space
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if space.icon == nil {
                    Circle()
                        .frame(width: 7, height: 7)
                } else {
                    SpaceIconView(icon: space.icon, size: 13)
                }
            }
            .foregroundStyle(palette.icon.opacity(isSelected ? 1 : (isHovered ? 0.8 : 0.45)))
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(space.title)
        .onHover { isHovered = $0 }
    }
}

struct SpaceIconView: View {
    let icon: SpaceIcon?
    var size: CGFloat

    var body: some View {
        switch icon {
        case let .emoji(emoji):
            Text(emoji).font(.system(size: size))
        case let .symbol(name):
            Image(systemName: name).font(.system(size: size, weight: .semibold))
        case nil:
            Image(systemName: "circle.fill").font(.system(size: size * 0.6))
        }
    }
}

// MARK: - Favicons

/// Favicon of a page, with a monogram fallback while it is fetched.
struct FaviconView: View {
    let url: String
    var image: NSImage?
    var size: CGFloat = 16
    @State private var fetched: NSImage?

    var body: some View {
        if let image = image ?? fetched ?? FaviconCache.shared.image(for: url)?.nsImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        } else if let page = InternalPage(url: url) {
            Image(systemName: Self.symbol(for: page))
                .font(.system(size: size * 0.8, weight: .medium))
                .frame(width: size, height: size)
        } else {
            let letter = URLDisplay.host(of: url)?.first.map { String($0).uppercased() } ?? "•"
            Text(letter)
                .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(Color.gray.opacity(0.55)))
                .task(id: url) {
                    guard url.hasPrefix("http") else { return }
                    fetched = await FaviconCache.shared.fetch(for: url)?.nsImage
                }
        }
    }

    private static func symbol(for page: InternalPage) -> String {
        switch page {
        case .note: "note.text"
        case .easel: "scribble.variable"
        case .newTab: "plus"
        case .settings: "gearshape"
        case .library: "books.vertical"
        case .shortcuts: "keyboard"
        }
    }
}
