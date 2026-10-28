import ArrowKit
import SwiftUI

/// Layout of a browser window: the space gradient, the sidebar and the
/// rounded content panel, plus the command bar and transient overlays.
struct BrowserRootView: View {
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state
    @Environment(\.colorScheme) private var colorScheme

    /// Gap between the content panel and the window edges.
    static let contentInset: CGFloat = 9

    private var theme: SpaceTheme {
        store.state.space(state.selectedSpaceID)?.theme ?? .lavender
    }

    private var palette: ThemePalette {
        theme.palette(isDark: theme.isDark(systemIsDark: colorScheme == .dark))
    }

    private var sidebarWidth: CGFloat {
        CGFloat(store.settings.sidebarWidth)
    }

    private var showsSidebar: Bool {
        state.isSidebarVisible && !state.isFullscreenContent
    }

    /// The Library takes the sidebar's place while it is open, as in Arc.
    private var librarySection: LibrarySection? {
        guard !state.isFullscreenContent, case let .library(section) = state.sheet else { return nil }
        return section
    }

    var body: some View {
        @Bindable var state = state
        ZStack(alignment: store.settings.sidebarOnRight ? .trailing : .leading) {
            VisualEffectBackground()
            // Light themes are opaque like Arc's; dark ones let the vibrancy through.
            ThemeBackground(palette: palette)
                .opacity(palette.isDark ? 0.94 : 1)

            HStack(spacing: 0) {
                if store.settings.sidebarOnRight {
                    content
                    sidebar
                } else {
                    sidebar
                    content
                }
            }

            if !state.isSidebarVisible, !state.isFullscreenContent, librarySection == nil {
                revealedSidebar
            }

            if let model = state.commandBar {
                CommandBarOverlay(model: model, controller: controller, sidebarWidth: sidebarWidth)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if let switcher = state.tabSwitcher {
                TabSwitcherOverlay(controller: controller, tabIDs: switcher.tabIDs, index: switcher.index)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }

            if let spaceID = state.themePickerSpaceID {
                themePicker(spaceID)
            }

            if let toast = state.toast {
                ToastView(toast: toast)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .environment(\.palette, Palette(theme: palette))
        .preferredColorScheme(theme.appearance == .automatic ? nil : (palette.isDark ? .dark : .light))
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.18), value: state.commandBar != nil)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.toast)
        .animation(.easeOut(duration: 0.2), value: librarySection)
        .onChange(of: librarySection != nil) { _, isOpen in
            // Arc moves the traffic lights a little in the Library.
            controller.arrowWindow?.trafficLightCenter = isOpen ? CGPoint(x: 23, y: 27.5)
                : CGPoint(x: 20, y: ArrowWindow.trafficLightCenterY)
        }
        .sheet(item: Binding(get: { librarySection == nil ? state.sheet : nil },
                             set: { if $0 != nil || librarySection == nil { state.sheet = $0 } })) { sheet in
            sheetContent(sheet)
                .environment(store)
                .environment(state)
                .environment(\.palette, Palette(theme: palette))
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if let librarySection {
            LibraryView(controller: controller, section: librarySection)
                .frame(width: librarySection == .spaces ? nil : LibraryView.railWidth + LibraryView.listWidth)
                .transition(.opacity)
        } else if showsSidebar {
            SidebarView(controller: controller)
                .frame(width: sidebarWidth)
                .overlay(alignment: store.settings.sidebarOnRight ? .leading : .trailing) {
                    SidebarResizeHandle()
                }
                .transition(.move(edge: store.settings.sidebarOnRight ? .trailing : .leading))
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if store.settings.showToolbar && !state.isFullscreenContent {
                ToolbarView(controller: controller)
            }
            ContentPanel(controller: controller)
        }
            .padding(.top, state.isFullscreenContent || store.settings.showToolbar ? 0 : Self.contentInset)
            .padding(.bottom, state.isFullscreenContent ? 0 : Self.contentInset)
            .padding(store.settings.sidebarOnRight ? .leading : .trailing, state.isFullscreenContent ? 0 : Self.contentInset)
            .padding(store.settings.sidebarOnRight ? .trailing : .leading,
                     showsSidebar || librarySection != nil || state.isFullscreenContent ? 0 : Self.contentInset)
    }

    /// When the sidebar is hidden it slides over the content while the
    /// pointer is at the window edge.
    @ViewBuilder
    private var revealedSidebar: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { if $0 { controller.revealSidebar(true) } }
        if state.isSidebarRevealed {
            SidebarView(controller: controller)
                .frame(width: sidebarWidth)
                .background(ThemeBackground(palette: palette))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 6)
                .padding(6)
                .onHover { if !$0 { controller.revealSidebar(false) } }
                .transition(.move(edge: store.settings.sidebarOnRight ? .trailing : .leading).combined(with: .opacity))
        }
    }

    /// Arc's theme picker, next to the sidebar; a click elsewhere closes it.
    private func themePicker(_ spaceID: UUID) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.0001)
                    .contentShape(Rectangle())
                    .onTapGesture { state.themePickerSpaceID = nil }
                ThemePickerPanel(spaceID: spaceID, controller: controller)
                    .offset(x: (showsSidebar && !store.settings.sidebarOnRight ? sidebarWidth : Self.contentInset) + 13,
                            y: max(50, proxy.size.height - 236 - ThemePickerPanel.size.height))
                Button("") { state.themePickerSpaceID = nil }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: WindowSheet) -> some View {
        switch sheet {
        case let .spaceEditor(spaceID):
            SpaceEditorView(controller: controller, spaceID: spaceID)
        case let .boostEditor(boostID, url):
            BoostEditorView(controller: controller, boostID: boostID, url: url)
        case .library:
            EmptyView()
        case .profileEditor:
            SpaceEditorView(controller: controller, spaceID: state.selectedSpaceID)
        case .welcome:
            WelcomeView(controller: controller)
        }
    }
}

/// Arc's toolbar mode: navigation and the address above the content.
private struct ToolbarView: View {
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state
    @Environment(\.palette) private var palette

    var body: some View {
        let tab = controller.selectedTab
        HStack(spacing: 8) {
            if !state.isSidebarVisible {
                Color.clear.frame(width: 64, height: 1)
            }
            NavigationButtons(tab: tab)
            HStack(spacing: 7) {
                Image(systemName: tab?.url.hasPrefix("https://") == true ? "lock.fill" : "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.subtitle)
                Text(tab.map { store.settings.showFullURLInToolbar ? $0.url : URLDisplay.short($0.url) }
                    .flatMap { $0.isEmpty ? nil : $0 } ?? "Search or Enter URL…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tab == nil ? palette.subtitle : palette.title.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let tab, tab.engine != nil {
                    ExtensionsMenuButton(controller: controller)
                    SiteControlsButton(tab: tab, controller: controller)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(SidebarControlBackground(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { controller.openCommandBar(nil) }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(WindowDragArea())
    }
}

/// Drag handle on the sidebar edge to resize it.
private struct SidebarResizeHandle: View {
    @Environment(BrowserStore.self) private var store
    @State private var startWidth: Double?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? store.settings.sidebarWidth
                        startWidth = start
                        let delta = store.settings.sidebarOnRight ? -value.translation.width : value.translation.width
                        store.settings.sidebarWidth = min(max(start + delta, 180), 420)
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}

/// Bottom notification ("Copied URL to clipboard").
struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol)
                .font(.system(size: 13, weight: .semibold))
            Text(toast.message)
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }
}
