import ArrowCEF
import ArrowCore
import ArrowKit
import CRT
import Foundation
import WinSDK
import WinUI

/// The app: a browser window on ArrowCore's store. Addresses passed on the
/// command line open as tabs.
///
///   Arrow [url…]          browses
///   Arrow --smoke [url]   with a new profile, opens the page (a built-in
///                         one by default) in a tab, prints its title and
///                         quits with status 0, or 1 if it does not load (CI,
///                         with bootstrapc.exe as Arrow.exe)
@MainActor
final class ArrowApp {
    /// The version of the macOS app (its MARKETING_VERSION, in project.yml).
    static let version = "1.0.0"

    static let startPage = "data:text/html;charset=utf-8,"
        + "<title>Arrow</title><h1>Arrow</h1><p>Arrow for Windows: WinUI 3 and Chromium.</p>"
        .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!

    fileprivate static var current: ArrowApp?

    private let store: BrowserStore
    private let addresses: [String]
    private let smoke: Bool
    private let sandboxed: Bool
    private var windows: [BrowserWindow] = []
    private var succeeded = false

    private init(store: BrowserStore, arguments: [String], smoke: Bool, sandboxed: Bool) {
        self.store = store
        addresses = URLInput.commandLineAddresses(arguments)
        self.smoke = smoke
        self.sandboxed = sandboxed
    }

    /// Runs a Chromium subprocess, or the browser process until its last
    /// window closes. Returns the exit status.
    static func run(sandboxInfo: UnsafeMutableRawPointer?) -> Int32 {
        let runtime = CEFRuntime.shared
        // Chromium's subprocesses relaunch Arrow.exe.
        let status = runtime.executeProcess(sandboxInfo: sandboxInfo)
        if status >= 0 { return status }

        do {
            try WindowsAppRuntime.initialize()
        } catch {
            print("arrow: \(error)")
            return 1
        }
        // WinUI runs in a single-threaded apartment.
        RoInitialize(RO_INIT_SINGLETHREADED)

        let arguments = Array(CommandLine.arguments.dropFirst())
        let smoke = arguments.contains("--smoke")
        if smoke {
            let profile = FileManager.default.temporaryDirectory.appendingPathComponent("arrow-smoke", isDirectory: true)
            try? FileManager.default.removeItem(at: profile)
            runtime.rootCachePath = profile
        }
        // WinUI runs the message loop.
        let pump = MessagePump()
        runtime.usesExternalMessagePump = true
        runtime.onScheduleMessagePumpWork = pump.schedule
        guard runtime.initialize(sandboxInfo: sandboxInfo) else {
            print("arrow: CEF failed to initialize")
            return 1
        }
        let app = ArrowApp(store: BrowserStore(engine: runtime, platform: WindowsPlatform()), arguments: arguments,
                           smoke: smoke, sandboxed: sandboxInfo != nil)
        current = app
        do {
            try Application.start { _ in _ = ArrowApplication() }
        } catch {
            print("arrow: WinUI failed to start: \(error)")
        }
        current = nil
        // Foundation writes the defaults (window selection) only when asked on
        // Windows.
        UserDefaults.standard.synchronize()
        runtime.shutdown()
        pump.invalidate()
        return app.smoke && !app.succeeded ? 1 : 0
    }

    fileprivate func launched() {
        guard let window = open(store) else { return }
        guard smoke else {
            for address in addresses { window.openNewTab(address) }
            // Like Arc, an empty window starts with the command bar.
            if window.state.selectedTabID == nil { window.showCommandBar(mode: .newTab) }
            return
        }
        window.savesSelection = false
        guard let tab = window.openNewTab(addresses.first ?? Self.startPage) else { return }
        Task { await smokeTest(tab, in: window) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            print("arrow: the page did not load within 60 seconds")
            exit(1)
        }
    }

    /// Whether a window other than `window` shows `window`'s store.
    static func hasOtherWindow(than window: BrowserWindow) -> Bool {
        current?.windows.contains { $0 !== window && $0.store === window.store } ?? false
    }

    /// Gives every window the backdrop of the settings.
    static func applyBackdrop() {
        current?.windows.forEach { $0.applyBackdrop() }
    }

    /// The store of the app's windows (not of incognito ones).
    static var store: BrowserStore? { current?.store }

    /// Opens `address` in a new tab of the last window.
    static func openInFrontWindow(_ address: String) {
        current?.windows.last { !$0.store.isIncognito }?.openNewTab(address)
    }

    /// Moves a page from Little Arrow into the last window's today tabs.
    static func adopt(_ tab: WebTab) {
        current?.windows.last { !$0.store.isIncognito }?.adopt(tab)
    }

    /// Opens another browser window on the current space (New Window), or an
    /// incognito one, on a store of its own that keeps nothing.
    static func openWindow(incognito: Bool = false) {
        guard let app = current else { return }
        let source = app.store
        let store = incognito
            ? BrowserStore(incognitoWith: source.settings, downloads: source.downloads, engine: source.engine,
                           platform: source.platform)
            : source
        let spaceID = incognito ? store.state.spaces[0].id : app.windows.last?.state.selectedSpaceID ?? store.state.spaces[0].id
        app.open(store, spaceID: spaceID)?.showCommandBar(mode: .newTab)
    }

    private func open(_ store: BrowserStore, spaceID: Foundation.UUID? = nil) -> BrowserWindow? {
        let window: BrowserWindow
        do {
            window = try BrowserWindow(store: store, spaceID: spaceID)
        } catch {
            print("arrow: the window failed to open: \(error)")
            return nil
        }
        windows.append(window)
        window.onClose = { [weak self, weak window] in
            self?.windows.removeAll { $0 === window }
        }
        return window
    }

    private func smokeTest(_ tab: WebTab, in window: BrowserWindow) async {
        while tab.isLoading || tab.engine == nil || tab.title.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // A DevTools round trip, which also checks that main actor jobs run.
        let title = await tab.engine?.evaluateJavaScript("document.title")
        print("arrow: loaded \(tab.url.prefix(60)), title: \(title.map { "\($0)" } ?? "none"), "
            + "hosted: \(window.isBrowserHosted ? "yes" : "no"), sandbox: \(sandboxed ? "on" : "off")")
        succeeded = title != nil && window.isBrowserHosted
        window.close()
    }
}

/// WinUI's application object, which opens the first window once WinUI has
/// started.
final class ArrowApplication: XamlApplication {
    override func launched() {
        // WinUI starts on the main thread.
        MainActor.assumeIsolated { ArrowApp.current?.launched() }
    }
}
