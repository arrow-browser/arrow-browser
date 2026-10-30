import AppKit
import ArrowCEF
import ArrowCore
import ArrowKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = BrowserStore(engine: CEFRuntime.shared, platform: MacPlatform())
    private(set) var windowControllers: [BrowserWindowController] = []
    private var incognitoStores: [ObjectIdentifier: BrowserStore] = [:]
    private var littleArrowWindows: [LittleArrowWindowController] = []
    private var settingsWindow: SettingsWindowController?
    var taskManagerWindow: NSWindow?
    private var extensionsWindow: NSWindow?
    private var littleArrowArchiver: Timer?
    private var pendingURLs: [String] = []
    private var didFinishLaunching = false
    private var isShuttingDown = false
    weak var lastActiveBrowserWindow: BrowserWindowController?

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        MainMenu.applyShortcuts(store.settings.customShortcuts)
        for delay in [0.0, 1.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainMenu.removeSystemItems() }
        }
        AppIcons.apply()
        #if DEBUG
        DebugAutomation.install(appDelegate: self)
        #endif
        CEFRuntime.shared.onRelaunch = { [weak self] arguments in
            guard let self else { return }
            let window = frontBrowserWindow()
            for argument in arguments {
                window.openNewTab(URLInput.resolve(argument, engine: store.settings.searchEngine))
            }
            window.showWindow(nil)
            NSApp.activate()
        }
        store.adBlocker.start()
        Updater.shared.start(store: store)
        store.visibleTabIDs = { [weak self] in
            Set(self?.windowControllers.flatMap(\.displayedTabIDs) ?? [])
        }
        // Preferences ▸ Advanced ▸ restore windows from previous session.
        let window = makeWindow(store: store, restoring: store.settings.restoreWindows ? WindowState.restoredSnapshot() : nil)
        GlobalShortcut.littleArrow.action = { [weak self] in self?.openLittleArrow(url: nil) }
        GlobalShortcut.littleArrow.setEnabled(store.settings.littleArrowShortcut)
        littleArrowArchiver = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.archiveIdleLittleArrows() }
        }
        didFinishLaunching = true
        // URLs passed on the command line open as tabs (`Arrow https://…`).
        for argument in URLInput.commandLineAddresses(CommandLine.arguments.dropFirst()) {
            window.openNewTab(URLInput.resolve(argument, engine: store.settings.searchEngine))
        }
        for url in pendingURLs { openExternal(url) }
        pendingURLs.removeAll()
        if WelcomeView.shouldShow {
            window.state.sheet = .welcome
        } else if window.state.selectedTabID == nil, window.state.commandBar == nil {
            // Like Arc, an empty window starts with the command bar.
            window.showCommandBar(mode: .newTab)
        }
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openExternal(url.absoluteString) }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let address = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { return }
        openExternal(address)
    }

    /// Links opened from other apps: Air Traffic Control rules first, then
    /// Little Arrow (Arc's default) or a new tab.
    func openExternal(_ address: String) {
        guard didFinishLaunching else {
            pendingURLs.append(address)
            return
        }
        if let components = URLComponents(string: address), components.scheme?.lowercased() == "arrowbrowser" {
            // arrowBrowser://share/<id> from a share page.
            if components.host == "share", let id = components.path.split(separator: "/").first {
                frontBrowserWindow().importShare(String(id))
            }
            return
        }
        if let spaceID = store.settings.route(address) {
            let controller = windowControllers.first { $0.state.selectedSpaceID == spaceID } ?? frontBrowserWindow()
            controller.selectSpace(spaceID)
            controller.openNewTab(address)
            controller.showWindow(nil)
            return
        }
        switch store.settings.externalLinks {
        case .littleArrow:
            openLittleArrow(url: address)
        case .activeSpace:
            let controller = frontBrowserWindow()
            controller.openNewTab(address)
            controller.showWindow(nil)
        }
        NSApp.activate()
    }

    func frontBrowserWindow() -> BrowserWindowController {
        if let last = lastActiveBrowserWindow, last.window?.isVisible == true, !last.isIncognito { return last }
        if let first = windowControllers.first(where: { !$0.isIncognito }) { return first }
        return makeWindow(store: store)
    }

    // MARK: - Windows

    @discardableResult
    private func makeWindow(store: BrowserStore, spaceID: UUID? = nil,
                            restoring snapshot: WindowState.Snapshot? = nil) -> BrowserWindowController {
        var frame: NSRect?
        if let last = lastActiveBrowserWindow?.window?.frame {
            frame = last.offsetBy(dx: 24, dy: -24)
        }
        let controller = BrowserWindowController(store: store, spaceID: spaceID, frame: frame, restoring: snapshot)
        windowControllers.append(controller)
        controller.showWindow(nil)
        lastActiveBrowserWindow = controller
        return controller
    }

    func windowControllerDidClose(_ controller: BrowserWindowController) {
        windowControllers.removeAll { $0 === controller }
        if controller.isIncognito, let key = incognitoStores.first(where: { $0.value === controller.store })?.key {
            let incognito = controller.store
            incognitoStores[key] = nil
            for id in incognito.tabs.keys { incognito.discardRuntime(id) }
        }
    }

    /// Preferences ▸ Links ▸ Archive Little Arcs after: closes the ones left aside.
    private func archiveIdleLittleArrows() {
        guard let interval = store.settings.littleArrowArchive.seconds else { return }
        for controller in littleArrowWindows where controller.window?.isKeyWindow == false
            && Date().timeIntervalSince(controller.lastActiveAt) > interval {
            controller.close()
        }
    }

    func littleArrowDidClose(_ controller: LittleArrowWindowController) {
        littleArrowWindows.removeAll { $0 === controller }
    }

    @objc func newWindow(_ sender: Any?) {
        makeWindow(store: store, spaceID: lastActiveBrowserWindow?.state.selectedSpaceID)
    }

    @objc func newBlankWindow(_ sender: Any?) {
        let controller = makeWindow(store: store, spaceID: lastActiveBrowserWindow?.state.selectedSpaceID)
        controller.state.selectedTabID = nil
    }

    @objc func newIncognitoWindow(_ sender: Any?) {
        let incognito = BrowserStore(incognitoWith: store.settings, downloads: store.downloads, engine: store.engine,
                                     platform: store.platform)
        incognitoStores[ObjectIdentifier(incognito)] = incognito
        let controller = makeWindow(store: incognito)
        controller.showCommandBar(mode: .newTab)
    }

    @objc func newLittleArrowWindow(_ sender: Any?) {
        openLittleArrow(url: nil)
    }

    func openLittleArrow(url: String?) {
        let controller = LittleArrowWindowController(store: store, url: url)
        littleArrowWindows.append(controller)
        controller.showWindow(nil)
        NSApp.activate()
    }

    /// Window a Little Arrow page would move to ("Open in <space>"), without
    /// opening one.
    var littleArrowTarget: BrowserWindowController? {
        if let last = lastActiveBrowserWindow, last.window?.isVisible == true, !last.isIncognito { return last }
        return windowControllers.first { !$0.isIncognito }
    }

    /// Moves a Little Arrow page into a space of the main window as a tab.
    func promoteLittleArrow(_ controller: LittleArrowWindowController, to spaceID: UUID? = nil) {
        let target = frontBrowserWindow()
        let tab = controller.tab
        let spaceID = spaceID ?? target.state.selectedSpaceID
        target.store.update { state in
            guard let index = state.spaceIndex(spaceID) else { return }
            state.spaces[index].today.insert(.tab(Tab(id: tab.id, url: tab.url, title: tab.title, faviconURL: tab.faviconURL)), at: 0)
        }
        target.store.register(tab)
        controller.detachTab()
        controller.close()
        if spaceID != target.state.selectedSpaceID { target.selectSpace(spaceID) }
        target.select(tab.id)
        target.showWindow(nil)
    }

    // MARK: - App menu

    @objc func showAbout(_ sender: Any?) {
        let chromium = "Chromium \(CEFVersion.chromium)"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Arrow",
            .credits: NSAttributedString(string: "A native SwiftUI browser powered by \(chromium) (CEF \(CEFVersion.cef))."),
        ])
    }

    @objc func showSettings(_ sender: Any?) {
        showSettings(pane: nil)
    }

    /// Preferences (⌘,), on `pane` when given. Named after its pane, as in Arc.
    func showSettings(pane: SettingsPane?) {
        let navigation = SettingsNavigation.shared
        if let pane { navigation.pane = pane }
        if let settingsWindow {
            settingsWindow.showWindow(nil)
            return
        }
        let controller = SettingsWindowController(store: store)
        controller.window?.center()
        controller.showWindow(nil)
        settingsWindow = controller
    }

    /// Extensions ▸ Add Extension…: the Chrome Web Store, as in Arc.
    @objc func addExtension(_ sender: Any?) {
        _ = frontBrowserWindow().openNewTab("https://chromewebstore.google.com")
    }

    /// Extensions ▸ Manage Extensions…
    @objc func manageExtensions(_ sender: Any?) {
        if let extensionsWindow {
            extensionsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: ExtensionsSettings().environment(store)))
        window.title = "Extensions"
        window.setContentSize(NSSize(width: 560, height: 480))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        extensionsWindow = window
    }

    @objc func setAsDefaultBrowser(_ sender: Any?) {
        DefaultBrowser.setDefault(Bundle.main.bundleURL)
    }

    @objc func importFromBrowser(_ sender: Any?) {
        let sources = BrowserImporter.availableSources()
        let chooser = NSAlert()
        chooser.messageText = "Import from Another Browser"
        chooser.informativeText = "Arc imports spaces, themes, pinned tabs and favorites; other browsers import bookmarks as pinned folders."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        popup.addItems(withTitles: sources.map(\.name))
        chooser.accessoryView = popup
        chooser.addButton(withTitle: "Import")
        chooser.addButton(withTitle: "Cancel")
        guard chooser.runModal() == .alertFirstButtonReturn, sources.indices.contains(popup.indexOfSelectedItem) else { return }
        let source = sources[popup.indexOfSelectedItem]
        let summary = BrowserImporter(store: store).importData(from: source)
        let result = NSAlert()
        result.messageText = summary == nil ? "Nothing to import" : "Import complete"
        result.informativeText = summary ?? (source == .safari
            ? "Safari bookmarks could not be read. Give Arrow Full Disk Access in System Settings ▸ Privacy & Security."
            : "No data was found for \(source.name).")
        result.runModal()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Task { await Updater.shared.check(interactive: true) }
    }

    @objc func newProfile(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "New Profile"
        alert.informativeText = "Profiles keep logins, cookies and history separate. Assign it to a space from the space settings."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Profile name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.update { $0.createProfile(name: name) }
    }

    @objc func showKeyboardShortcuts(_ sender: Any?) {
        frontBrowserWindow().openNewTab("arrow://shortcuts")
    }

    @objc func revealData(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([store.dataDirectory])
    }

    @objc func copyInfo(_ sender: Any?) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let info = """
        Arrow \(version)
        Chromium \(CEFVersion.chromium) (CEF \(CEFVersion.cef))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
    }

    // MARK: - Shutdown

    /// Closes every browser before quitting the Chromium message loop.
    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        for controller in littleArrowWindows { controller.tab.closeEngine() }
        let stores = [store] + incognitoStores.values
        let pending = PendingCount(stores.count)
        for store in stores {
            store.closeAllBrowsers {
                if pending.decrement() { CEFRuntime.shared.quitMessageLoop() }
            }
        }
        // Never hang on quit if a renderer does not answer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            CEFRuntime.shared.quitMessageLoop()
        }
    }

    func didExitMessageLoop() {
        store.saveNow()
    }
}

/// Counts outstanding asynchronous completions on the main actor.
@MainActor
private final class PendingCount {
    private var remaining: Int

    init(_ count: Int) {
        remaining = count
    }

    /// Returns true when the last completion arrived.
    func decrement() -> Bool {
        remaining -= 1
        return remaining == 0
    }
}
