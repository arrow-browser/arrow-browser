import AppKit
import ArrowCore
import ArrowKit
import SwiftUI

/// Little Arrow: a small floating window for quick lookups and links opened
/// from other apps. Like Little Arc, ⌥⌘N first shows a compact command bar;
/// the window grows to the page once something is opened, with "Open in
/// <space>" to move the page to the main window.
@MainActor
final class LittleArrowWindowController: NSWindowController, NSWindowDelegate {
    let tab: WebTab
    private let store: BrowserStore
    private var isDetached = false
    /// When the window was last in use (Archive Little Arcs after).
    private(set) var lastActiveAt = Date()
    /// The command bar shown before a page is opened.
    private(set) var launcher: CommandBarModel?

    /// Sizes measured on Little Arc.
    static let launcherWidth: CGFloat = 490
    static let pageSize = NSSize(width: 1185, height: 832)
    /// Gap to the top-right corner of the screen.
    private static let screenMargin: CGFloat = 20

    init(store: BrowserStore, url: String?) {
        self.store = store
        tab = WebTab(model: Tab(url: url ?? ""), profileID: store.state.defaultProfile.id, store: store)
        let window = ArrowWindow(contentRect: NSRect(origin: .zero, size: url == nil ? NSSize(width: Self.launcherWidth, height: 70)
                                                         : Self.fittedPageSize()))
        window.minSize = NSSize(width: 360, height: 60)
        window.isMovableByWindowBackground = true
        super.init(window: window)
        window.delegate = self
        window.trafficLightCenter.x = 17
        window.trafficLightsHidden = url == nil
        if url == nil {
            launcher = Self.makeLauncher(store: store)
        }
        window.contentView = NSHostingView(rootView: LittleArrowView(controller: self).environment(store))
        positionWindow()
        if url != nil {
            tab.ensureEngine(context: store.requestContext(for: tab.profileID))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func makeLauncher(store: BrowserStore) -> CommandBarModel {
        let sources = CommandBarModel.Sources(
            openTabs: {
                store.state.spaces.flatMap { space in space.allTabs.map { CommandBarTab(tab: $0, spaceTitle: nil) } }
                    + store.state.favorites.values.flatMap { $0.map { CommandBarTab(tab: $0, spaceTitle: nil) } }
            },
            history: { store.history },
            commands: [],
            engine: { store.settings.searchEngine },
            settings: { store.settings },
            currentTabID: nil
        )
        return CommandBarModel(mode: .newTab, anchor: .center, sources: sources)
    }

    private static func fittedPageSize() -> NSSize {
        let screen = NSScreen.main?.visibleFrame.size ?? pageSize
        return NSSize(width: min(pageSize.width, screen.width - 2 * screenMargin),
                      height: min(pageSize.height, screen.height - 2 * screenMargin))
    }

    /// Top-right corner of the screen, cascading over other Little Arrows.
    private func positionWindow() {
        guard let window, let screen = NSScreen.main?.visibleFrame else { return }
        let offset = CGFloat(NSApp.windows.filter { $0.windowController is LittleArrowWindowController && $0 !== window }.count) * 24
        window.setFrameOrigin(NSPoint(x: screen.maxX - window.frame.width - Self.screenMargin - offset,
                                      y: screen.maxY - window.frame.height - Self.screenMargin - offset))
    }

    /// The launcher sizes the window to its content.
    func fitLauncher(height: CGFloat) {
        guard launcher != nil, let window else { return }
        var frame = window.frame
        guard abs(frame.height - height) > 0.5 || frame.width != Self.launcherWidth else { return }
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: Self.launcherWidth, height: height)
        window.setFrame(frame, display: true)
    }

    func load(_ text: String) {
        open(URLInput.resolve(text, engine: store.settings.searchEngine))
    }

    /// Opens a page: the launcher grows into the page window, keeping its
    /// top-right corner.
    func open(_ url: String) {
        tab.load(url)
        tab.ensureEngine(context: store.requestContext(for: tab.profileID))
        guard launcher != nil, let window = window as? ArrowWindow else { return }
        let size = Self.fittedPageSize()
        let frame = window.frame
        var origin = NSPoint(x: frame.maxX - size.width, y: frame.maxY - size.height)
        if let screen = window.screen?.visibleFrame {
            origin.x = max(origin.x, screen.minX)
            origin.y = max(origin.y, screen.minY)
        }
        pageFrame = NSRect(origin: origin, size: size)
        window.minSize = NSSize(width: 360, height: 300)
        window.trafficLightsHidden = false
        launcher = nil
    }

    /// Frame the launcher grows to, applied once the page view is shown (the
    /// launcher's fixed size would otherwise hold the window back).
    private var pageFrame: NSRect?

    func pageDidAppear() {
        guard let pageFrame, let window else { return }
        self.pageFrame = nil
        window.setFrame(pageFrame, display: true, animate: true)
    }

    func perform(_ item: CommandBarItem) {
        guard let launcher else { return }
        switch item.kind {
        case let .navigate(url), let .open(url):
            open(url)
        case let .search(query):
            open(store.settings.searchEngine.searchURL(for: query))
        case let .siteSearch(site, query):
            if query.isEmpty {
                launcher.activeSiteSearch = site
                launcher.text = ""
            } else {
                open(site.searchURL(for: query))
            }
        case let .switchToTab(tabID):
            // Little Arc opens the tab's page rather than switching to it.
            let tabs = store.state.spaces.flatMap(\.allTabs) + store.state.favorites.values.flatMap { $0 }
            if let url = tabs.first(where: { $0.id == tabID })?.url { open(url) }
        case .command:
            break
        }
    }

    func submitLauncher() {
        guard let launcher else { return }
        if let item = launcher.selectedItem {
            perform(item)
        } else if !launcher.text.isEmpty {
            let url = launcher.activeSiteSearch.map { $0.searchURL(for: launcher.text) }
                ?? URLInput.resolve(launcher.text, engine: store.settings.searchEngine)
            open(url)
        }
    }

    /// Where "Open in" moves the page: the front window's current space.
    var targetSpace: Space? {
        guard let target = (NSApp.delegate as? AppDelegate)?.littleArrowTarget else { return store.state.spaces.first }
        return store.state.space(target.state.selectedSpaceID)
    }

    func openInArrow(spaceID: UUID? = nil) {
        (NSApp.delegate as? AppDelegate)?.promoteLittleArrow(self, to: spaceID)
    }

    /// The tab now belongs to a browser window.
    func detachTab() {
        isDetached = true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Give the keyboard to SwiftUI so the launcher field can take focus.
        if launcher != nil, let window, let content = window.contentView, window.firstResponder !== content {
            window.makeFirstResponder(content)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        lastActiveAt = Date()
    }

    func windowWillClose(_ notification: Notification) {
        if !isDetached { tab.closeEngine() }
        (NSApp.delegate as? AppDelegate)?.littleArrowDidClose(self)
    }
}

extension LittleArrowWindowController {
    func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tab.url, forType: .string)
    }
}

private struct LittleArrowView: View {
    let controller: LittleArrowWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme

    /// Little Arc wears the theme of the space "Open in" points to.
    private var palette: ThemePalette {
        let theme = controller.targetSpace?.theme ?? .lavender
        return theme.palette(isDark: theme.isDark(systemIsDark: colorScheme == .dark))
    }

    var body: some View {
        Group {
            // `tab` is observed: its engine appears when a page is opened.
            if let launcher = controller.launcher, controller.tab.engine == nil {
                LittleArrowLauncher(controller: controller, model: launcher)
            } else {
                LittleArrowPage(controller: controller, palette: palette)
            }
        }
        .environment(\.palette, Palette(theme: palette))
        .ignoresSafeArea()
    }
}

// MARK: - Launcher

/// ⌥⌘N: Arc's command bar in its own small window.
private struct LittleArrowLauncher: View {
    let controller: LittleArrowWindowController
    @Bindable var model: CommandBarModel
    @Environment(\.palette) private var palette
    @FocusState private var isFocused: Bool

    private var launcherPalette: ThemePalette {
        var theme = palette.theme
        if !theme.isDark { theme.accent = RGBColor(hex: 0x8F95FF) }
        return theme
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .bold))
                    .frame(width: 24)
                TextField(model.placeholder, text: $model.text, selection: $model.textSelection)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .medium))
                    .focused($isFocused)
                    .onSubmit { controller.submitLauncher() }
                    .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                    .onKeyPress(.tab) { model.acceptSiteSearchHint() ? .handled : .ignored }
                    .onKeyPress(.escape) { controller.close(); return .handled }
                Button { controller.close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.leading, 20)
            .padding(.trailing, 22)
            .frame(height: 64)

            if !model.items.isEmpty {
                Divider().padding(.horizontal, 12)
                VStack(spacing: 4) {
                    ForEach(Array(model.items.prefix(6).enumerated()), id: \.element.id) { index, item in
                        CommandBarRow(item: item, isSelected: index == model.selectedIndex, showsAction: false)
                            .contentShape(Rectangle())
                            .onTapGesture { controller.perform(item) }
                            .onHover { if $0 { model.selectedIndex = index } }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            DefaultBrowserBanner()
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: LittleArrowWindowController.launcherWidth)
        .background(palette.isDark ? Color(white: 0.16) : Color(red: 0.973, green: 0.969, blue: 0.973))
        // Little Arc's launcher selects in its own periwinkle (#8F95FF).
        .environment(\.palette, Palette(theme: launcherPalette))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controller.fitLauncher(height: $0) }
        .onAppear {
            isFocused = true
            DispatchQueue.main.async { isFocused = true }
        }
    }
}

// MARK: - Page

private struct LittleArrowPage: View {
    let controller: LittleArrowWindowController
    let palette: ThemePalette

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9.5) {
                LittleArrowAddressField(controller: controller)
                LittleArrowOpenInButton(controller: controller)
            }
            .padding(.leading, 83)
            .padding(.trailing, 8)
            .frame(height: ArrowWindow.trafficLightCenterY * 2)
            .background(WindowDragArea())

            WebContentView(tab: controller.tab)
                .overlay(alignment: .top) {
                    // The toolbar's soft shadow on the page.
                    LinearGradient(colors: [.black.opacity(0.06), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 6)
                        .allowsHitTesting(false)
                }
        }
        .background(ThemeBackground(palette: palette))
        .onAppear { controller.pageDidAppear() }
    }
}

/// The page address; click it to type another one.
private struct LittleArrowAddressField: View {
    let controller: LittleArrowWindowController
    @Environment(\.palette) private var palette
    @State private var editedText: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        let tab = controller.tab
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.subtitle)
                .frame(width: 14)
            if let editedText {
                TextField("Search or Enter URL…", text: Binding(get: { editedText }, set: { self.editedText = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isFocused)
                    .onSubmit {
                        controller.load(editedText)
                        self.editedText = nil
                    }
                    .onKeyPress(.escape) { self.editedText = nil; return .handled }
                    .onAppear { isFocused = true }
            } else {
                Text(tab.url.isEmpty ? "Search or Enter URL…" : tab.url)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { editedText = tab.url }
            }
            Button { controller.copyURL() } label: {
                Image(systemName: "link").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.subtitle)
            .help("Copy URL")
            .disabled(tab.url.isEmpty)
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .frame(height: 30)
        .background(SidebarControlBackground(cornerRadius: 8))
    }
}

/// "Open in <space> ⌘O ⌄", as in Little Arc.
private struct LittleArrowOpenInButton: View {
    let controller: LittleArrowWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var palette

    var body: some View {
        let space = controller.targetSpace
        HStack(spacing: 0) {
            Button { controller.openInArrow(spaceID: space?.id) } label: {
                HStack(spacing: 5) {
                    Text("Open in").foregroundStyle(Color(white: 0.5))
                    Text(space?.title ?? "Arrow")
                        .fontWeight(.medium)
                        .foregroundStyle(Color(palette.theme.accent.withHSB(saturation: 0.87, brightness: 1)))
                    KeyCap(label: "⌘O")
                }
                .font(.system(size: 13))
                .lineLimit(1)
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: .command)
            .disabled(controller.tab.url.isEmpty)

            Divider().frame(height: 16)

            Menu {
                ForEach(store.state.spaces) { other in
                    Button(other.title) { controller.openInArrow(spaceID: other.id) }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(white: 0.5))
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open in Another Space")
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.isDark ? Color(white: 0.22) : Color(white: 0.995))
                .shadow(color: .black.opacity(0.1), radius: 1, y: 0.5)
        )
    }
}
