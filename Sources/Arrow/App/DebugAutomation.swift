#if DEBUG
import AppKit
import ArrowCore
import ArrowKit

/// Debug-only remote control used to exercise the UI from scripts:
/// `xcrun swift scripts/arrowctl.swift <action> [argument]` posts a
/// distributed notification handled here. Not compiled in release builds.
@MainActor
enum DebugAutomation {
    static let notificationName = Notification.Name("com.euskadi31.arrow.debug")

    static func install(appDelegate: AppDelegate) {
        DistributedNotificationCenter.default().addObserver(forName: notificationName, object: nil, queue: .main) { note in
            let action = note.userInfo?["action"] as? String ?? ""
            let argument = note.userInfo?["argument"] as? String ?? ""
            MainActor.assumeIsolated { perform(action, argument, appDelegate) }
        }
    }

    private static func perform(_ action: String, _ argument: String, _ app: AppDelegate) {
        guard let window = app.lastActiveBrowserWindow ?? app.windowControllers.first else { return }
        switch action {
        case "open": window.openNewTab(URLInput.resolve(argument, engine: window.store.settings.searchEngine))
        case "commandBar":
            window.showCommandBar(mode: .newTab)
            window.state.commandBar?.text = argument
        case "editURL": window.openCommandBar(nil)
        case "dismiss": window.state.commandBar = nil
        case "select": if let index = Int(argument) {
            let ids = window.orderedSidebarTabIDs
            if ids.indices.contains(index) { window.select(ids[index]) }
        }
        case "pin": window.togglePinTab(nil)
        case "favorite": if let id = window.state.selectedTabID { window.store.update { $0.move(id, to: .favorites()) } }
        case "split": if let id = window.state.selectedTabID, let other = window.orderedSidebarTabIDs.first(where: { $0 != id }) {
            window.store.update { $0.addToSplit(other, with: id) }
            window.select(id)
        }
        case "peek": window.openPeek(argument)
        case "closePeek": window.closePeek()
        case "toggleSidebar": window.toggleArrowSidebar(nil)
        case "newSpace": window.store.update { state in
            let space = state.createSpace(title: argument.isEmpty ? "Work" : argument, icon: .symbol("briefcase.fill"),
                                          theme: SpaceTheme.presets[1])
            _ = state.openTab(url: "https://news.ycombinator.com", in: space.id)
        }
        case "nextSpace": window.nextSpace(nil)
        case "previousSpace": window.previousSpace(nil)
        case "library": window.viewLibrary(nil)
        case "spaceEditor": window.editSpaceTheme(nil)
        case "closeSheet":
            window.state.sheet = nil
            window.state.themePickerSpaceID = nil
        case "find":
            window.findInPage(nil)
            window.selectedTab?.find(argument)
        case "settings": app.showSettings(nil)
        case "littleArrow": app.openLittleArrow(url: argument.isEmpty ? nil : argument)
        case "incognito": app.newIncognitoWindow(nil)
        case "folder": window.newFolder(nil)
        case "close": if let id = window.state.selectedTabID { window.closeTab(id) }
        case "reopen": window.reopenLastClosedTab()
        case "installExtension":
            Task {
                do {
                    let item = try await ExtensionManager.shared.install(argument, using: window.store)
                    NSLog("Arrow debug: installed \(item.name) \(item.version)")
                } catch {
                    NSLog("Arrow debug: install failed: \(error.localizedDescription)")
                }
            }
        case "extensionPopup":
            if let item = ExtensionManager.shared.extensions.first, let url = ExtensionManager.shared.popupURL(for: item) {
                ExtensionPopupController.show(url: url, from: window)
            }
        case "adblockStats":
            NSLog("Arrow debug: adblock rules=\(window.store.adBlocker.ruleCount) blocked=\(window.store.adBlocker.blockedRequests)")
        case "cloudRegister":
            let parts = argument.split(separator: " ").map(String.init)
            guard parts.count == 3 else { return }
            window.store.settings.cloudServerURL = parts[0]
            Task {
                do {
                    try await window.store.cloud.register(email: parts[1], password: parts[2], displayName: "Arrow Test")
                } catch {
                    try? await window.store.cloud.signIn(email: parts[1], password: parts[2])
                }
                window.store.settings.syncEnabled = true
                await window.store.cloud.syncNow()
                log("cloud user=\(window.store.cloud.user?.email ?? "-") error=\(window.store.cloud.lastSyncError ?? "none")")
            }
        case "shareSpace":
            if let space = window.selectedSpace {
                window.share(kind: "space", title: space.title, tabs: space.allTabs)
            }
        case "importArc":
            let summary = BrowserImporter(store: window.store).importData(from: .arc) ?? "nothing"
            NSLog("Arrow debug: import \(summary)")
        case "capture": window.capturePage(nil)
        case "showSwitcher":
            let recent = Array(window.state.recentTabIDs.prefix(5))
            NSLog("Arrow debug: switcher recent=\(recent.count)")
            if recent.count > 1 { window.state.tabSwitcher = (recent, 1) }
        case "hideSwitcher": window.state.tabSwitcher = nil
        case "toolbar": window.toggleToolbar(nil)
        case "snapshotStats":
            let count = window.store.tabs.values.filter { $0.snapshot != nil }.count
            NSLog("Arrow debug: snapshots=\(count)")
        case "activate":
            NSApp.activate(ignoringOtherApps: true)
            window.window?.makeKeyAndOrderFront(nil)
        case "newEasel": window.newEasel(nil)
        case "captureFull": window.capture(fullPage: true)
        case "media": window.state.sheet = .library(.media)
        case "librarySection": window.state.sheet = .library(LibrarySection(rawValue: argument) ?? .media)
        case "appIcon": AppIcons.select(argument)
        case "updateServer":
            // "<server URL> [public key]": without a key, the one in Info.plist is used.
            let parts = argument.split(separator: " ").map(String.init)
            guard let server = parts.first else { return }
            window.store.settings.cloudServerURL = server
            if parts.count > 1 {
                UserDefaults.standard.set(parts[1], forKey: "ArrowUpdatePublicKeyOverride")
            } else {
                UserDefaults.standard.removeObject(forKey: "ArrowUpdatePublicKeyOverride")
            }
            Task {
                await Updater.shared.check(interactive: false)
                log("updater phase=\(Updater.shared.phase)")
            }
        case "enableAI":
            window.store.settings.aiEnabled = true
            window.store.settings.tidyTabTitles = true
            window.store.settings.tidyDownloads = true
        case "eval":
            // Runs JavaScript in the selected tab as a user gesture would.
            guard let id = window.state.selectedTabID, let engine = window.store.webTab(id)?.engine else { return }
            Task {
                let reply = await engine.devToolsMethod("Runtime.evaluate", params: [
                    "expression": argument, "userGesture": true, "awaitPromise": true, "returnByValue": true,
                ])
                let value = (reply?["result"] as? [String: Any])?["value"]
                log("eval \(argument) -> \(value.map { String(describing: $0) } ?? String(describing: reply))")
            }
        case "installUpdate": Updater.shared.installAndRelaunch()
        case "action":
            // Sends a menu action (e.g. "toggleCollapsePinnedTabs:") to the window, as the menu does.
            NSApp.sendAction(NSSelectorFromString(argument), to: window, from: nil)
        case "restoreOldest":
            let backups = window.store.sidebarBackups()
            let before = window.store.state.spaces.flatMap(\.allTabs).count
            let restored = backups.last.map { window.store.restoreSidebar(from: $0) } ?? false
            log("restore backups=\(backups.count) restored=\(restored) tabs \(before) -> \(window.store.state.spaces.flatMap(\.allTabs).count)")
        case "offer":
            // "show", "accept", "never", "never-language", "dismiss": the banner over the page.
            guard let tab = window.selectedTab else { return }
            switch argument {
            case "accept": tab.acceptOffer()
            case "never": tab.neverOffer()
            case "never-language": tab.neverOffer(forSite: false)
            case "dismiss": tab.offer = nil
            default: break
            }
            log("offer \(tab.offerDescription)")
        case "autofillState":
            guard let tab = window.selectedTab, let engine = tab.engine, let host = URLDisplay.host(of: tab.url) else { return }
            let logins = PasswordStore.logins(for: host)
            Task {
                let field = await engine.evaluateJavaScript(AutofillScripts.hasPasswordField)
                let password = logins.first.flatMap { PasswordStore.password(host: $0.host, username: $0.username) }
                log("autofill host=\(host) logins=\(logins.count) field=\(String(describing: field)) (\(type(of: field))) "
                    + "password=\(password == nil ? "nil" : "\(password!.count) chars")")
            }
        case "autofillNow":
            guard let tab = window.selectedTab, let engine = tab.engine, let host = URLDisplay.host(of: tab.url),
                  let login = PasswordStore.logins(for: host).first,
                  let password = PasswordStore.password(host: host, username: login.username) else { return }
            Task {
                let reply = await engine.devToolsMethod("Runtime.evaluate", params: [
                    "expression": AutofillScripts.fillLogin(username: login.username, password: password), "returnByValue": true,
                ])
                log("autofillNow \(String(describing: reply).prefix(400))")
            }
        case "state":
            log("state sidebar=\(window.state.isSidebarVisible) toolbar=\(window.store.settings.showToolbar) "
                + "sheet=\(window.state.sheet.map { "\($0.id)" } ?? "none") commandBar=\(window.state.commandBar != nil) "
                + "littleArrows=\(NSApp.windows.filter { $0.windowController is LittleArrowWindowController && $0.isVisible }.count) "
                + "hotkey=\(GlobalShortcut.littleArrow.status.map(String.init) ?? "unregistered")")
        case "playSound": window.store.playSound(argument == "capture" ? .capture : .event)
        case "soundInfo":
            log("sounds " + [SoundEffect.event, .capture].map { "\($0.rawValue)=\(SoundEffects.info($0))" }.joined(separator: " "))
        case "castState":
            let cast = CastController.shared
            Task {
                let media = await window.selectedTab?.castableMedia()
                log("cast discovering=\(cast.isDiscovering) sinksReported=\(cast.sinkReports) sinks=\(cast.sinks.map(\.name)) "
                    + "status=\(cast.status) media=\(media.map { String(describing: $0) } ?? "no tab")")
            }
        case "devtools": window.selectedTab?.engine?.showDevTools(panel: argument.isEmpty ? nil : argument)
        case "traceStart": CEFTracing.shared.start(); log("trace recording=\(CEFTracing.shared.isRecording)")
        case "traceStop":
            CEFTracing.shared.stop(writingTo: URL(fileURLWithPath: argument)) { log("trace written \($0.path)") }
        case "menuDump":
            log("shortcut commands: \(MainMenu.commands().count)")
            NSApp.mainMenu?.update()
            for top in NSApp.mainMenu?.items ?? [] { top.submenu?.update() }
            for top in NSApp.mainMenu?.items ?? [] where ["Arrow", "Edit", "View"].contains(top.submenu?.title ?? "") {
                top.submenu?.items.compactMap(\.submenu).forEach { $0.update() }
                for item in top.submenu?.items ?? [] where !item.isSeparatorItem {
                    let sub = (item.submenu?.items ?? []).compactMap(\.action).map(NSStringFromSelector).joined(separator: ",")
                    log("menu \(top.submenu?.title ?? "") > \(item.title) action=\(item.action.map(NSStringFromSelector) ?? "-") "
                        + "key=\(item.keyEquivalent.unicodeScalars.map { String($0.value, radix: 16) }) "
                        + "mods=\(item.keyEquivalentModifierMask.rawValue) alt=\(item.isAlternate) hidden=\(item.isHidden) sub=[\(sub)]")
                }
            }
        case "toast": window.state.showToast(argument.isEmpty ? "Copied URL to clipboard" : argument, symbol: "link")
        default: NSLog("Arrow debug: unknown action \(action)")
        }
    }

    /// Appends to ~/Library/Logs/Arrow/debug.log, read back by scripts.
    private static func log(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Arrow/debug.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = Data("\(Date()) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}
#endif
