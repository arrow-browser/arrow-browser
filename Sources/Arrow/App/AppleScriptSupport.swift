import AppKit
import ArrowKit

// AppleScript support, compatible with Arc's dictionary (Resources/Arrow.sdef):
//   tell application "Arrow" to get URL of active tab of front window
//   tell application "Arrow" to tell front window to make new tab with properties {URL:"https://…"}

extension AppDelegate {
    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        ["appleScriptWindows", "appleScriptTabs"].contains(key)
    }

    /// Browser windows, front to back.
    @objc var appleScriptWindows: [AppleScriptWindowWrapper] {
        NSApp.orderedWindows
            .compactMap { $0.windowController as? BrowserWindowController }
            .map(AppleScriptWindowWrapper.init)
    }

    /// Write-only: `make new tab with properties {URL:…}` at the application
    /// level opens Little Arrow, like Arc's Little Arc.
    @objc var appleScriptTabs: [AppleScriptTabWrapper] { [] }

    @objc func insertInAppleScriptTabs(_ tab: AppleScriptTabWrapper) {
        openLittleArrow(url: tab.pendingURL)
    }

    @objc func insertObject(_ tab: AppleScriptTabWrapper, inAppleScriptTabsAtIndex index: Int) {
        insertInAppleScriptTabs(tab)
    }
}

@objc(AppleScriptWindowWrapper)
@MainActor
final class AppleScriptWindowWrapper: NSObject {
    let controller: BrowserWindowController

    init(controller: BrowserWindowController) {
        self.controller = controller
    }

    private var window: NSWindow? { controller.window }

    @objc var id: String { String(window?.windowNumber ?? 0) }
    @objc var title: String { window?.title ?? "" }
    @objc var orderedIndex: Int { NSApp.orderedWindows.firstIndex { $0 === window }.map { $0 + 1 } ?? 0 }
    @objc var hasCloseBox: Bool { true }
    @objc var isMiniaturizable: Bool { true }
    @objc var isMiniaturized: Bool {
        get { window?.isMiniaturized ?? false }
        set { newValue ? window?.miniaturize(nil) : window?.deminiaturize(nil) }
    }

    @objc var isResizable: Bool { true }
    @objc var isVisible: Bool {
        get { window?.isVisible ?? false }
        set { newValue ? window?.orderFront(nil) : window?.orderOut(nil) }
    }

    @objc var isZoomable: Bool { true }
    @objc var isZoomed: Bool {
        get { window?.isZoomed ?? false }
        set { if newValue != isZoomed { window?.zoom(nil) } }
    }

    @objc var isIncognito: Bool { controller.isIncognito }
    @objc var mode: String { controller.isIncognito ? "incognito" : "normal" }

    @objc var appleScriptTabs: [AppleScriptTabWrapper] {
        guard let space = controller.selectedSpace else { return [] }
        let favorites = controller.store.state.favorites(for: space.profileID)
        return (favorites + space.allTabs).map { AppleScriptTabWrapper(window: self, tabID: $0.id) }
    }

    @objc var appleScriptSpaces: [AppleScriptSpaceWrapper] {
        controller.store.state.spaces.map { AppleScriptSpaceWrapper(window: self, spaceID: $0.id) }
    }

    @objc var activeTab: AppleScriptTabWrapper? {
        controller.state.selectedTabID.map { AppleScriptTabWrapper(window: self, tabID: $0) }
    }

    @objc var activeSpace: AppleScriptSpaceWrapper? {
        AppleScriptSpaceWrapper(window: self, spaceID: controller.state.selectedSpaceID)
    }

    /// `make new tab with properties {URL:…}` in this window.
    @objc func insertInAppleScriptTabs(_ tab: AppleScriptTabWrapper) {
        let url = tab.pendingURL ?? "about:blank"
        if let created = controller.openNewTab(url) {
            tab.attach(window: self, tabID: created.id)
        }
    }

    @objc func insertObject(_ tab: AppleScriptTabWrapper, inAppleScriptTabsAtIndex index: Int) {
        insertInAppleScriptTabs(tab)
    }

    @objc func close(_ command: NSScriptCommand) -> Any? {
        window?.performClose(nil)
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let appDescription = NSApp.classDescription as? NSScriptClassDescription else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: appDescription, containerSpecifier: nil,
                                   key: "appleScriptWindows", uniqueID: id)
    }
}

@objc(AppleScriptTabWrapper)
@MainActor
final class AppleScriptTabWrapper: NSObject {
    private(set) var window: AppleScriptWindowWrapper?
    private(set) var tabID: UUID?
    /// URL given by `make new tab with properties {URL:…}` before insertion.
    private(set) var pendingURL: String?

    /// Used by AppleScript's `make` command.
    override init() {
        super.init()
    }

    init(window: AppleScriptWindowWrapper, tabID: UUID) {
        self.window = window
        self.tabID = tabID
        super.init()
    }

    func attach(window: AppleScriptWindowWrapper, tabID: UUID) {
        self.window = window
        self.tabID = tabID
    }

    private var controller: BrowserWindowController? { window?.controller }
    private var model: Tab? { tabID.flatMap { controller?.store.state.tab($0) } }
    private var live: WebTab? { tabID.flatMap { controller?.store.webTab($0) } }

    @objc var id: String { tabID?.uuidString ?? "" }
    @objc var title: String { live?.displayTitle ?? model?.displayTitle ?? "" }

    @objc var URL: String {
        get { live?.url ?? model?.url ?? pendingURL ?? "" }
        set {
            guard let live else {
                pendingURL = newValue
                return
            }
            live.load(newValue)
        }
    }

    @objc var loading: Bool { live?.isLoading ?? false }

    @objc var location: String {
        guard let tabID, let section = controller?.store.state.location(of: tabID)?.section else { return "unpinned" }
        switch section {
        case .favorites: return "topApp"
        case .pinned: return "pinned"
        case .today: return "unpinned"
        }
    }

    @objc func select(_ command: NSScriptCommand) -> Any? {
        guard let tabID else { return nil }
        controller?.select(tabID)
        controller?.window?.makeKeyAndOrderFront(nil)
        return nil
    }

    @objc func goBack(_ command: NSScriptCommand) -> Any? {
        live?.goBack()
        return nil
    }

    @objc func goForward(_ command: NSScriptCommand) -> Any? {
        live?.goForward()
        return nil
    }

    @objc func reload(_ command: NSScriptCommand) -> Any? {
        live?.reload()
        return nil
    }

    @objc func stopLoading(_ command: NSScriptCommand) -> Any? {
        live?.stopLoading()
        return nil
    }

    /// Runs JavaScript and returns its result as text (asynchronously).
    @objc func executeJavascript(_ command: NSScriptCommand) -> Any? {
        guard let code = command.evaluatedArguments?["javascript"] as? String, let engine = live?.engine else { return nil }
        // Off by default, as in Arc and Chrome: scripts could read any page.
        guard (NSApp.delegate as? AppDelegate)?.store.settings.allowJavaScriptFromAppleEvents == true else {
            command.scriptErrorNumber = errAEEventNotPermitted
            command.scriptErrorString = "Executing JavaScript through AppleScript is turned off. To turn it on, choose "
                + "View ▸ Developer ▸ Allow JavaScript from Apple Events."
            return nil
        }
        command.suspendExecution()
        Task { @MainActor in
            let value = await engine.evaluateJavaScript(code)
            let text: String = switch value {
            case nil: ""
            case let string as String: string
            case let other?:
                (try? JSONSerialization.data(withJSONObject: other, options: [.fragmentsAllowed]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "\(other)"
            }
            command.resumeExecution(withResult: text)
        }
        return nil
    }

    @objc func close(_ command: NSScriptCommand) -> Any? {
        guard let tabID else { return nil }
        controller?.closeTab(tabID)
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let window, let container = window.objectSpecifier,
              let description = NSScriptClassDescription(for: AppleScriptWindowWrapper.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: container,
                                   key: "appleScriptTabs", uniqueID: id)
    }
}

@objc(AppleScriptSpaceWrapper)
@MainActor
final class AppleScriptSpaceWrapper: NSObject {
    let window: AppleScriptWindowWrapper
    let spaceID: UUID

    init(window: AppleScriptWindowWrapper, spaceID: UUID) {
        self.window = window
        self.spaceID = spaceID
    }

    private var space: Space? { window.controller.store.state.space(spaceID) }

    @objc var id: String { spaceID.uuidString }
    @objc var title: String { space?.title ?? "" }

    @objc var appleScriptTabs: [AppleScriptTabWrapper] {
        (space?.allTabs ?? []).map { AppleScriptTabWrapper(window: window, tabID: $0.id) }
    }

    @objc func focus(_ command: NSScriptCommand) -> Any? {
        window.controller.selectSpace(spaceID)
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let container = window.objectSpecifier,
              let description = NSScriptClassDescription(for: AppleScriptWindowWrapper.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: container,
                                   key: "appleScriptSpaces", uniqueID: id)
    }
}
