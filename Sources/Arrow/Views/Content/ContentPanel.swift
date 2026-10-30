import ArrowCore
import ArrowKit
import SwiftUI
import UniformTypeIdentifiers

/// Rounded card(s) showing the selected tab or split view.
struct ContentPanel: View {
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state
    @Environment(\.palette) private var palette

    static let cornerRadius: CGFloat = 6
    static let splitGap: CGFloat = 6

    var body: some View {
        let ids = controller.displayedTabIDs
        ZStack {
            Group {
                if ids.isEmpty {
                    card { EmptyContentView(controller: controller) }
                } else if let split = controller.selectedSplit {
                    SplitContentView(split: split, controller: controller)
                } else if let id = ids.first, let tab = store.webTab(id) {
                    card { TabContentView(tab: tab, controller: controller) }
                }
            }
            // Arc steps the page back a little behind Peek.
            .scaleEffect(state.peek == nil ? 1 : 0.985)

            if let peek = state.peek {
                PeekOverlay(tab: peek.tab, controller: controller)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: state.peek?.id)
        .onDrop(of: [.arrowSidebarItem], delegate: SplitDropDelegate(controller: controller))
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.contentBackground)
            .clipShape(RoundedRectangle(cornerRadius: state.isFullscreenContent ? 0 : Self.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(palette.isDark ? 0.35 : 0.1), radius: 1.5, x: 0, y: 0.5)
    }
}

/// Dropping a sidebar tab on the content opens it in Split View (Arc).
private struct SplitDropDelegate: DropDelegate {
    let controller: BrowserWindowController

    func validateDrop(info: DropInfo) -> Bool {
        controller.state.selectedTabID != nil && info.hasItemsConforming(to: [.arrowSidebarItem])
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.arrowSidebarItem]).first,
              let selected = controller.state.selectedTabID else { return false }
        let controller = controller
        provider.loadSidebarItem { id in
            guard let id else { return }
            Task { @MainActor in
                guard id != selected, controller.store.state.tab(id) != nil else { return }
                controller.store.update { $0.addToSplit(id, with: selected) }
                controller.select(id)
            }
        }
        return true
    }
}

/// Two to four panes side by side or stacked.
private struct SplitContentView: View {
    let split: SplitView
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state
    @Environment(\.palette) private var palette

    var body: some View {
        let layout = split.axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: ContentPanel.splitGap))
            : AnyLayout(VStackLayout(spacing: ContentPanel.splitGap))
        layout {
            // View ▸ Expand Current Split shows one pane alone.
            let expanded = split.tabs.contains { $0.id == state.expandedPaneID } ? state.expandedPaneID : nil
            ForEach(split.tabs.filter { expanded == nil || $0.id == expanded }) { model in
                if let tab = store.webTab(model.id) {
                    TabContentView(tab: tab, controller: controller)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(palette.contentBackground)
                        .clipShape(RoundedRectangle(cornerRadius: ContentPanel.cornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: ContentPanel.cornerRadius, style: .continuous)
                                .strokeBorder(palette.accent.opacity(state.focusedPaneID == model.id ? 0.55 : 0), lineWidth: 1.5)
                        )
                        .shadow(color: .black.opacity(0.1), radius: 1.5, y: 0.5)
                        .simultaneousGesture(TapGesture().onEnded {
                            state.focusedPaneID = model.id
                            state.selectedTabID = model.id
                        })
                }
            }
        }
    }
}

/// Page of one tab and its overlays.
struct TabContentView: View {
    let tab: WebTab
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state

    var body: some View {
        ZStack {
            switch tab.internalPage {
            case let .note(id):
                NoteEditorView(noteID: id, tab: tab)
                    .contentAppearance(store.settings.contentAppearance)
            case let .easel(id):
                EaselView(easelID: id, controller: controller)
                    .contentAppearance(store.settings.contentAppearance)
            case .shortcuts:
                ShortcutsPageView()
            case .newTab, .settings, .library:
                EmptyContentView(controller: controller)
            case nil:
                WebContentView(tab: tab)
                if let crash = tab.crash {
                    CrashView(status: crash) { tab.reload() }
                } else if let failure = tab.loadFailure {
                    LoadFailureView(failure: failure) { tab.reload() }
                }
            }
        }
        .overlay(alignment: .bottom) {
            WebStoreBanner(url: tab.url)
        }
        .overlay(alignment: .top) {
            if store.settings.dragWindowFromPageTop, tab.internalPage == nil {
                WindowDragArea().frame(height: 8)
            }
        }
        .overlay {
            if state.isCapturing, controller.selectedTab?.id == tab.id {
                CaptureOverlay(controller: controller)
            }
        }
        .overlay(alignment: .top) {
            if let request = tab.permissionRequest {
                PermissionPrompt(pending: request)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let offer = tab.offer {
                PageOfferBanner(offer: offer, tab: tab)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if state.isFindBarVisible, controller.state.focusedPaneID == tab.id || controller.selectedSplit == nil {
                FindBar(tab: tab) {
                    state.isFindBarVisible = false
                    tab.endFind()
                    controller.focusWebContent()
                }
                .padding(10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let status = tab.statusMessage {
                Text(status)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(8)
                    .frame(maxWidth: 520, alignment: .leading)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.isFindBarVisible)
        .animation(.spring(response: 0.3), value: tab.permissionRequest?.id)
        .animation(.spring(response: 0.3), value: tab.offer?.id)
    }
}

/// Save a password or a card, fill one, or translate the page.
private struct PageOfferBanner: View {
    let offer: PageOffer
    let tab: WebTab
    @Environment(BrowserStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    private var symbol: String {
        switch offer.kind {
        case .savePassword, .fillPassword: "key.fill"
        case .saveCard, .fillCard: "creditcard.fill"
        case .translate: "character.bubble"
        }
    }

    private var title: String {
        switch offer.kind {
        case let .savePassword(host, _, _): "Save password for \(host)?"
        case .saveCard: "Save card?"
        case let .fillPassword(host, _): "Saved passwords for \(host)"
        case .fillCard: "Fill a saved card"
        case let .translate(language):
            "Translate this page from \(Locale.current.localizedString(forLanguageCode: language) ?? language)?"
        }
    }

    private var subtitle: String? {
        switch offer.kind {
        case let .savePassword(_, username, _): username.isEmpty ? "No username" : username
        case let .saveCard(card): "\(card.label) · \(card.expiry)"
        default: nil
        }
    }

    @ViewBuilder private var actions: some View {
        switch offer.kind {
        case .savePassword:
            Button("Never") { tab.neverOffer() }
            Button("Not Now") { tab.offer = nil }
            Button("Save") { tab.acceptOffer() }
                .keyboardShortcut(.defaultAction)
        case .saveCard:
            Button("Not Now") { tab.offer = nil }
            Button("Save") { tab.acceptOffer() }
                .keyboardShortcut(.defaultAction)
        case let .fillPassword(host, usernames):
            ForEach(usernames.prefix(3), id: \.self) { username in
                Button(username.isEmpty ? "No username" : username) {
                    tab.fill(login: PasswordStore.Login(host: host, username: username, modified: nil))
                    tab.offer = nil
                }
            }
            dismiss
        case let .fillCard(cards):
            ForEach(cards.prefix(3)) { card in
                Button(card.label) {
                    tab.fill(card: card)
                    tab.offer = nil
                }
            }
            dismiss
        case let .translate(language):
            Menu("Never") {
                Button("Never translate \(Locale.current.localizedString(forLanguageCode: language) ?? language)") {
                    tab.neverOffer(forSite: false)
                }
                Button("Never translate this site") { tab.neverOffer(forSite: true) }
            }
            .fixedSize()
            Button("Not Now") { tab.offer = nil }
            Button("Translate") { tab.acceptOffer() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var dismiss: some View {
        Button { tab.offer = nil } label: { Image(systemName: "xmark") }
            .buttonStyle(.borderless)
    }
}

/// Hosts the Chromium view of a tab.
struct WebContentView: NSViewRepresentable {
    let tab: WebTab

    func makeNSView(context: Context) -> WebContainerView {
        WebContainerView()
    }

    func updateNSView(_ view: WebContainerView, context: Context) {
        view.attach((tab.engine as? CEFBrowser)?.hostView)
    }

    static func dismantleNSView(_ view: WebContainerView, coordinator: ()) {
        view.attach(nil)
    }
}

final class WebContainerView: NSView {
    private weak var hosted: NSView?

    override var isFlipped: Bool { true }

    func attach(_ view: NSView?) {
        guard view !== hosted else { return }
        if let hosted, hosted.superview === self {
            // Keep the browser in a window so it stays alive and renders.
            CEFParkingLot.park(hosted)
        }
        hosted = view
        guard let view else { return }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    override func layout() {
        super.layout()
        hosted?.frame = bounds
    }
}

// MARK: - Overlays

private struct EmptyContentView: View {
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state
    @Environment(\.palette) private var palette

    var body: some View {
        // Arc leaves the content empty; a click opens the command bar.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { controller.newTab(nil) }
    }
}

struct FindBar: View {
    let tab: WebTab
    let onClose: () -> Void
    @Environment(BrowserStore.self) private var store
    @State private var text = ""
    @State private var answer: String?
    @State private var isAsking = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find on page", text: $text)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($isFocused)
                .onSubmit { tab.find(text, forward: !NSEvent.modifierFlags.contains(.shift)) }
                .onChange(of: text) { _, value in tab.find(value) }
                .onExitCommand(perform: onClose)
            if let find = tab.find, !find.text.isEmpty {
                Text(find.matchCount == 0 ? "No results" : "\(find.activeMatch)/\(find.matchCount)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button { tab.find(text, forward: false) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
            Button { tab.find(text, forward: true) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
            if AIFeatures.isAvailable(store) {
                Button {
                    isAsking = true
                    Task {
                        answer = await AIFeatures.ask(text, about: tab, store: store)
                        isAsking = false
                    }
                } label: {
                    if isAsking { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                }
                .buttonStyle(.borderless)
                .help("Ask on Page")
                .disabled(text.isEmpty || isAsking)
            }
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .overlay(alignment: .topTrailing) {
            if let answer {
                ScrollView {
                    Text(answer)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(width: 380)
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                .offset(y: 48)
                .onTapGesture { self.answer = nil }
            }
        }
        .onAppear {
            text = tab.find?.text ?? ""
            isFocused = true
        }
    }
}

private struct PermissionPrompt: View {
    let pending: PendingPermission

    private var description: String {
        let names = pending.request.kinds.map { kind -> String in
            switch kind {
            case .camera: "your camera"
            case .microphone: "your microphone"
            case .screenCapture: "your screen"
            case .location: "your location"
            case .notifications: "to show notifications"
            case .clipboard: "your clipboard"
            case .midi: "MIDI devices"
            case .other: "additional permissions"
            }
        }.sorted()
        return names.joined(separator: " and ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(URLDisplay.short(pending.request.origin))
                    .font(.system(size: 13, weight: .semibold))
                Text("wants to use \(description)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Block") { pending.decide(false) }
            Button("Allow") { pending.decide(true) }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }
}

private struct LoadFailureView: View {
    let failure: LoadFailure
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("This site can’t be reached")
                .font(.title2.weight(.semibold))
            Text("\(URLDisplay.short(failure.url)) — \(failure.description.isEmpty ? "Error \(failure.code)" : failure.description)")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
                .controlSize(.large)
                .keyboardShortcut("r")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct CrashView: View {
    let status: TerminationStatus
    let reload: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text(status == .outOfMemory ? "This page ran out of memory" : "This page crashed")
                .font(.title2.weight(.semibold))
            Text("Reload to try again.")
                .foregroundStyle(.secondary)
            Button("Reload", action: reload)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A link previewed over the current page (opened from a pinned tab or a
/// favorite to another site, or Shift-clicked). As in Arc: a large card over
/// the page veiled in the space's colors, with round buttons beside it.
private struct PeekOverlay: View {
    let tab: WebTab
    let controller: BrowserWindowController
    @Environment(\.palette) private var palette
    @Environment(BrowserStore.self) private var store
    @State private var summary: String?

    var body: some View {
        GeometryReader { proxy in
            // Measured on Arc: 80% of the content width, almost its full height.
            let width = proxy.size.width * 0.8
            ZStack(alignment: .topLeading) {
                ThemeBackground(palette: palette.theme)
                    .opacity(0.72)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.closePeek() }

                WebContentView(tab: tab)
                    .overlay(alignment: .top) {
                        if let summary {
                            Text(summary)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .padding(10)
                        }
                    }
                    .background(palette.contentBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.16), radius: 14, y: 4)
                    .frame(width: width, height: proxy.size.height - 5)
                    .offset(x: (proxy.size.width - width) / 2 + 4, y: 3)

                VStack(spacing: 9) {
                    PeekButton(symbol: "xmark", help: "Close (⌘W)") { controller.closePeek() }
                    PeekButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Open as Tab") { controller.expandPeek() }
                    PeekButton(symbol: "rectangle.split.2x1", help: "Add to Split View") { controller.splitPeek() }
                    if AIFeatures.isAvailable(store) {
                        PeekButton(symbol: "sparkles", help: "Summarize") {
                            summary = "…"
                            Task { summary = await AIFeatures.summarize(tab, store: store) }
                        }
                    }
                }
                .offset(x: (proxy.size.width + width) / 2 + 4 + 13, y: 10.5)
            }
        }
    }
}

/// White round button beside the Peek card.
private struct PeekButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.isDark ? palette.title : Color(palette.theme.accent.withHSB(saturation: 0.8, brightness: 0.97)))
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(palette.isDark ? Color(white: 0.24) : .white)
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension View {
    /// View ▸ Appearance applies to easels and notes as well as websites.
    @ViewBuilder
    func contentAppearance(_ appearance: ContentAppearance) -> some View {
        switch appearance {
        case .automatic: self
        case .light: environment(\.colorScheme, .light)
        case .dark: environment(\.colorScheme, .dark)
        }
    }
}
