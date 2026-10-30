import AppKit
import ArrowCore

/// The menu bar, as Arc 1.170 shows it (File, Edit, View, Spaces, Tabs,
/// Archive, Extensions, Window, Help) with the same keyboard shortcuts.
/// Commands Arc keeps out of its menus but reachable by shortcut are hidden
/// items that still answer their key equivalent.
@MainActor
enum MainMenu {
    private typealias W = BrowserWindowController
    private typealias A = AppDelegate

    /// Keeps the spaces, extensions and Edit menus up to date.
    private static let updater = MenuUpdater()

    static func build() -> NSMenu {
        // Arc's Edit menu has no Dictation or Emoji & Symbols items.
        UserDefaults.standard.register(defaults: ["NSDisabledDictationMenuItem": true,
                                                  "NSDisabledCharacterPaletteMenuItem": true])
        let main = NSMenu(title: "Main Menu")
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(spacesMenu()))
        main.addItem(submenu(tabsMenu()))
        main.addItem(submenu(archiveMenu()))
        main.addItem(submenu(extensionsMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    // MARK: Custom shortcuts (Preferences ▸ Shortcuts)

    /// A menu command whose shortcut can be changed.
    struct Command: Identifiable {
        /// Stable key: action and tag ("selectTabAtIndex:#2").
        let id: String
        let title: String
        let item: NSMenuItem
    }

    /// Shortcuts as built, to reset them.
    private static var defaultShortcuts: [String: (key: String, modifiers: NSEvent.ModifierFlags)] = [:]

    static func commandID(_ item: NSMenuItem) -> String? {
        item.action.map { "\(NSStringFromSelector($0))#\(item.tag)" }
    }

    /// Arrow's own commands, for Preferences ▸ Shortcuts (not text editing
    /// or the commands AppKit adds).
    static func commands() -> [Command] {
        var items: [NSMenuItem] = []
        var seen = Set<String>()
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu); continue }
                guard !item.isSeparatorItem, item.identifier != MenuUpdater.dynamicItem, let action = item.action,
                      let id = commandID(item), defaultShortcuts[id] != nil, seen.insert(id).inserted,
                      BrowserWindowController.instancesRespond(to: action) || AppDelegate.instancesRespond(to: action),
                      ![#selector(A.showAbout(_:)), #selector(A.quitArrow(_:)), #selector(A.setContentAppearance(_:)),
                        #selector(A.toggleJavaScriptFromAppleEvents(_:)), #selector(A.addExtension(_:)),
                        #selector(A.manageExtensions(_:))].contains(action) else { continue }
                items.append(item)
            }
        }
        if let main = NSApp.mainMenu { walk(main) }
        let visibleTitles = Set(items.filter { !$0.isHidden }.map(\.title))
        return items.compactMap { item in
            commandID(item).map { id in
                Command(id: id, title: item.isHidden && visibleTitles.contains(item.title) ? "\(item.title) (Alternate)" : item.title,
                        item: item)
            }
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Stored form of a shortcut: "<modifier flags>|<key equivalent>"; empty for none.
    static func encode(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        key.isEmpty ? "" : "\(modifiers.intersection([.command, .option, .control, .shift]).rawValue)|\(key)"
    }

    static func decode(_ spec: String) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let raw = UInt(parts[0]) else { return ("", []) }
        return (parts[1], NSEvent.ModifierFlags(rawValue: raw))
    }

    /// Applies `custom` over the shortcuts the menus were built with.
    static func applyShortcuts(_ custom: [String: String]) {
        guard let main = NSApp.mainMenu else { return }
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu); continue }
                guard item.identifier != MenuUpdater.dynamicItem, let id = commandID(item) else { continue }
                if defaultShortcuts[id] == nil {
                    defaultShortcuts[id] = (item.keyEquivalent, item.keyEquivalentModifierMask)
                }
                let shortcut = custom[id].map(decode) ?? defaultShortcuts[id]!
                item.keyEquivalent = shortcut.key
                item.keyEquivalentModifierMask = shortcut.key.isEmpty ? [] : shortcut.modifiers
            }
        }
        walk(main)
    }

    /// AppKit adds its Edit items once the menu bar is installed.
    static func removeSystemItems() {
        guard let edit = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Edit" })?.submenu else { return }
        MenuUpdater.removeSystemItems(edit)
    }

    // MARK: Builders

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0,
                             alternate: Bool = false, hidden: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        item.isAlternate = alternate
        item.isHidden = hidden
        if hidden { item.allowsKeyEquivalentWhenHidden = true }
        return item
    }

    /// Title as AppKit translates it (Arc shows these few in the user's language).
    private static func system(_ title: String) -> String {
        Bundle(for: NSApplication.self).localizedString(forKey: title, value: title, table: "MenuCommands")
    }

    private static func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(key)!))
    }

    // MARK: Menus

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Arrow")
        menu.addItem(item("About Arrow", #selector(A.showAbout(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Preferences…", #selector(A.showSettings(_:)), ","))
        menu.addItem(item("Share Arrow", #selector(A.shareArrow(_:))))
        menu.addItem(item("Set as Default Browser", #selector(A.setAsDefaultBrowser(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Import from Another Browser…", #selector(A.importFromBrowser(_:))))
        menu.addItem(item("Check for Updates…", #selector(A.checkForUpdates(_:))))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        menu.addItem(submenu(services))
        menu.addItem(.separator())
        menu.addItem(item("Privacy Policy", #selector(A.showPrivacyPolicy(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Hide Arrow", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Other Windows", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Sign Out", #selector(A.signOutOfCloud(_:))))
        menu.addItem(item("Quit Arrow", #selector(A.quitArrow(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Tab…", #selector(W.newTab(_:)), "t"))
        menu.addItem(item("New Window", #selector(A.newWindow(_:)), "n"))
        menu.addItem(item("Blank Window", #selector(A.newBlankWindow(_:)), "n", [.command, .control]))
        menu.addItem(item("New Incognito Window", #selector(A.newIncognitoWindow(_:)), "n", [.command, .shift]))
        menu.addItem(item("New Little Arrow Window", #selector(A.newLittleArrowWindow(_:)), "n", [.command, .option]))
        menu.addItem(item("Restore Last Closed Tab", #selector(W.restoreLastClosedTab(_:)), "t", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Open Command Bar", #selector(W.openCommandBar(_:)), "l"))
        menu.addItem(.separator())
        menu.addItem(item("New Profile", #selector(A.newProfile(_:))))
        menu.addItem(item("New Easel", #selector(W.newEasel(_:)), "e", [.control, .shift]))
        menu.addItem(item("New Note", #selector(W.newNote(_:)), "n", [.control, .shift], hidden: true))
        menu.addItem(.separator())
        menu.addItem(item("Close Window", #selector(W.closeBrowserWindow(_:)), "w", [.command, .shift]))
        menu.addItem(item("Archive Tab", #selector(W.archiveTab(_:)), "w", hidden: true))
        menu.addItem(.separator())
        menu.addItem(item("Share…", #selector(W.sharePage(_:))))
        menu.addItem(item("Capture…", #selector(W.capturePage(_:)), "2", [.command, .shift]))
        menu.addItem(item("Capture Full Page", #selector(W.captureFullPage(_:))))
        menu.addItem(item("Capture in Portrait Mode", #selector(W.captureInPortraitMode(_:))))
        menu.addItem(item("Save Page As", #selector(W.savePageAs(_:)), "s", [.command, .shift]))
        menu.addItem(item("Print", #selector(W.printPage(_:)), "p"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.delegate = updater
        menu.addItem(item(UndoManager().undoMenuItemTitle, Selector(("undo:")), "z"))
        menu.addItem(item(UndoManager().redoMenuItemTitle, Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Copy URL", #selector(W.copyURL(_:)), "c", [.command, .shift]))
        menu.addItem(item("Copy URL as Markdown", #selector(W.copyURLAsMarkdown(_:)), "c", [.command, .option, .shift]))
        menu.addItem(item("Copy URL as Quote", #selector(W.copyURLAsQuote(_:)), "c", [.command, .control, .shift]))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .shift]))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())

        let find = NSMenu(title: "Find")
        find.addItem(item("Find…", #selector(W.findInPage(_:)), "f"))
        find.addItem(item("Find and Replace", #selector(NSResponder.performTextFinderAction(_:)), "f", [.command, .option],
                          tag: NSTextFinder.Action.showReplaceInterface.rawValue))
        find.addItem(item("Find Next", #selector(W.findNextMatch(_:)), "g"))
        find.addItem(item("Find Previous", #selector(W.findPreviousMatch(_:)), "g", [.command, .shift]))
        find.addItem(item("Use Selection to Find", #selector(W.useSelectionToFind(_:))))
        find.addItem(item("Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j"))
        menu.addItem(submenu(find))

        let spelling = NSMenu(title: "Spelling and Grammar")
        spelling.addItem(item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"))
        spelling.addItem(item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"))
        spelling.addItem(.separator())
        spelling.addItem(item(system("Check Spelling While Typing"), #selector(NSTextView.toggleContinuousSpellChecking(_:))))
        spelling.addItem(item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:))))
        spelling.addItem(item("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))))
        menu.addItem(submenu(spelling))

        let substitutions = NSMenu(title: "Substitutions")
        substitutions.addItem(item(system("Show Substitutions"), #selector(NSTextView.orderFrontSubstitutionsPanel(_:))))
        substitutions.addItem(.separator())
        substitutions.addItem(item("Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:))))
        substitutions.addItem(item("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))))
        substitutions.addItem(item("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))))
        substitutions.addItem(item("Smart Links", #selector(NSTextView.toggleAutomaticLinkDetection(_:))))
        substitutions.addItem(item("Data Detectors", #selector(NSTextView.toggleAutomaticDataDetection(_:))))
        substitutions.addItem(item("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:))))
        menu.addItem(submenu(substitutions))

        let transformations = NSMenu(title: "Transformations")
        transformations.addItem(item("Make Upper Case", #selector(NSResponder.uppercaseWord(_:))))
        transformations.addItem(item("Make Lower Case", #selector(NSResponder.lowercaseWord(_:))))
        transformations.addItem(item("Capitalize", #selector(NSResponder.capitalizeWord(_:))))
        menu.addItem(submenu(transformations))

        let speech = NSMenu(title: "Speech")
        speech.addItem(item("Start Speaking", #selector(NSTextView.startSpeaking(_:))))
        speech.addItem(item("Stop Speaking", #selector(NSTextView.stopSpeaking(_:))))
        menu.addItem(submenu(speech))

        // Format ▸ Font, for notes.
        let font = NSMenu(title: "Font")
        let bold = item("Bold", #selector(NSFontManager.addFontTrait(_:)), "b", tag: Int(NSFontTraitMask.boldFontMask.rawValue))
        let italic = item("Italic", #selector(NSFontManager.addFontTrait(_:)), "i", tag: Int(NSFontTraitMask.italicFontMask.rawValue))
        bold.target = NSFontManager.shared
        italic.target = NSFontManager.shared
        font.addItem(bold)
        font.addItem(italic)
        font.addItem(item("Underline", #selector(NSText.underline(_:)), "u"))
        let format = NSMenu(title: "Format")
        format.addItem(submenu(font))
        menu.addItem(submenu(format))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        let appearance = NSMenu(title: "Appearance")
        let header = NSMenuItem(title: "Websites, Easels, and Notes will use:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        appearance.autoenablesItems = false
        appearance.addItem(header)
        for (index, title) in ["Automatic", "Light", "Dark"].enumerated() {
            appearance.addItem(item(title, #selector(A.setContentAppearance(_:)), tag: index))
        }
        menu.addItem(submenu(appearance))
        menu.addItem(.separator())
        menu.addItem(item("Hide Sidebar", #selector(W.toggleArrowSidebar(_:)), "s"))
        menu.addItem(item("Show Toolbar", #selector(W.toggleToolbar(_:)), "d", [.command, .shift]))
        menu.addItem(item("Collapse Pinned Tabs", #selector(W.toggleCollapsePinnedTabs(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Stop Loading", #selector(W.stopLoadingPage(_:)), "."))
        menu.addItem(item("Refresh the Page", #selector(W.reloadPage(_:)), "r"))
        menu.addItem(item("Force Refresh the Page", #selector(W.forceReloadPage(_:)), "r", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Add Split View", #selector(W.addSplitView(_:)), "=", [.control, .shift]))
        menu.addItem(item("Close this Split Pane", #selector(W.closeSplitPane(_:)), "-", [.control, .shift]))
        menu.addItem(item("Separate Page from Split View", #selector(W.separateFromSplit(_:))))
        // Commands without a menu item in Arc, listed in Preferences ▸ Shortcuts.
        menu.addItem(item("Clear Cookies and Refresh", #selector(W.clearCookiesAndReload(_:)), hidden: true))
        menu.addItem(item("Clear Cache and Refresh", #selector(W.clearCacheAndReload(_:)), hidden: true))
        menu.addItem(item("Translate Page", #selector(W.translatePage(_:)), hidden: true))
        menu.addItem(item("Expand Current Split", #selector(W.toggleExpandCurrentSplit(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Zoom to Actual Size", #selector(W.zoomActualSize(_:)), "0"))
        menu.addItem(item("Zoom In", #selector(W.zoomInPage(_:)), "+"))
        menu.addItem(item("Zoom In", #selector(W.zoomInPage(_:)), "=", hidden: true))
        menu.addItem(item("Zoom Out", #selector(W.zoomOutPage(_:)), "-"))
        menu.addItem(.separator())
        menu.addItem(item("Cast", #selector(W.castMedia(_:))))
        menu.addItem(.separator())

        let developer = NSMenu(title: "Developer")
        developer.addItem(item("View Source", #selector(W.viewPageSource(_:)), "u", [.command, .option]))
        developer.addItem(item("Developer Tools", #selector(W.showDeveloperTools(_:)), "i", [.command, .option]))
        developer.addItem(item("Developer Tools", #selector(W.showDeveloperTools(_:)), arrow(NSF12FunctionKey), [], tag: 1,
                               hidden: true))
        developer.addItem(item("Inspect Elements", #selector(W.inspectElements(_:)), "c", [.command, .option]))
        developer.addItem(item("JavaScript Console", #selector(W.showJavaScriptConsole(_:)), "j", [.command, .option]))
        developer.addItem(item("Network Inspector", #selector(W.showNetworkInspector(_:))))
        developer.addItem(.separator())
        developer.addItem(item("Allow JavaScript from Apple Events", #selector(A.toggleJavaScriptFromAppleEvents(_:))))
        developer.addItem(item("Toggle Developer Mode", #selector(W.toggleDeveloperMode(_:)), "d", [.control, .shift], hidden: true))
        menu.addItem(submenu(developer))
        menu.addItem(item(system("Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        menu.addItem(item("Exit", #selector(W.exitContentFullScreen(_:)), "\u{1b}", [], hidden: true))
        return menu
    }

    private static func spacesMenu() -> NSMenu {
        let menu = NSMenu(title: "Spaces")
        menu.delegate = updater
        menu.addItem(item("New Space…", #selector(W.newSpace(_:))))
        menu.addItem(item("Edit Theme…", #selector(W.editSpaceTheme(_:))))
        menu.addItem(item("Rename Space", #selector(W.renameSpace(_:))))
        menu.addItem(item("Change Profile", #selector(W.changeSpaceProfile(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Next Space", #selector(W.nextSpace(_:)), arrow(NSRightArrowFunctionKey), [.command, .option]))
        menu.addItem(item("Previous Space", #selector(W.previousSpace(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option]))
        // The spaces of the window are listed here by MenuUpdater; these keep
        // ⌃1–9 working before the menu is first opened.
        for index in 0..<9 {
            menu.addItem(item("Go to Space \(index + 1)", #selector(W.selectSpaceAtIndex(_:)), "\(index + 1)", [.control],
                              tag: index, hidden: true))
        }
        menu.addItem(.separator())
        menu.addItem(item("Manage Spaces…", #selector(W.manageSpaces(_:))))
        return menu
    }

    private static func tabsMenu() -> NSMenu {
        let menu = NSMenu(title: "Tabs")
        menu.addItem(item("New Tab…", #selector(W.newTab(_:)), "t"))
        menu.addItem(item("Pin/Unpin Tab", #selector(W.togglePinTab(_:)), "d"))
        menu.addItem(item("New Folder…", #selector(W.newFolder(_:))))
        menu.addItem(item("Open Little Arrow or Peek in…", #selector(W.openLittleArrowOrPeek(_:)), "o", hidden: true))
        menu.addItem(item("Duplicate", #selector(W.duplicateTab(_:)), hidden: true))
        menu.addItem(item("Rename Current Item", #selector(W.renameCurrentItem(_:)), hidden: true))
        menu.addItem(item("Reset Tab to Original URL", #selector(W.resetTabToOriginalURL(_:)), hidden: true))
        menu.addItem(item("Collapse All Folders", #selector(W.collapseAllFolders(_:)), hidden: true))
        menu.addItem(item("Expand All Folders", #selector(W.expandAllFolders(_:)), hidden: true))
        menu.addItem(item("New Boost", #selector(W.newBoost(_:)), hidden: true))
        menu.addItem(item("Zap Elements", #selector(W.zapElements(_:)), hidden: true))
        menu.addItem(.separator())
        menu.addItem(item("Next Tab", #selector(W.nextTab(_:)), arrow(NSDownArrowFunctionKey), [.command, .option]))
        menu.addItem(item("Previous Tab", #selector(W.previousTab(_:)), arrow(NSUpArrowFunctionKey), [.command, .option]))
        menu.addItem(item("Tab Switcher (forward)", #selector(W.tabSwitcherForward(_:)), "\t", [.control], hidden: true))
        menu.addItem(item("Tab Switcher (backward)", #selector(W.tabSwitcherBackward(_:)), "\t", [.control, .shift], hidden: true))
        menu.addItem(item("Cycle Tab Forward", #selector(W.nextTab(_:)), arrow(NSRightArrowFunctionKey), [.command, .control],
                          hidden: true))
        menu.addItem(item("Cycle Tab Backward", #selector(W.previousTab(_:)), arrow(NSLeftArrowFunctionKey), [.command, .control],
                          hidden: true))
        for index in 0..<9 {
            menu.addItem(item("Go to Sidebar Item \(index + 1)", #selector(W.selectTabAtIndex(_:)), "\(index + 1)", [.command], tag: index,
                              hidden: true))
        }
        menu.addItem(item("Reveal Tab in Sidebar", #selector(W.revealTabInSidebar(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Clear Today", #selector(W.clearUnpinnedTabs(_:)), "k", [.command, .shift]))
        menu.addItem(item("Reset all tabs in this Space", #selector(W.resetAllTabsInSpace(_:))))
        return menu
    }

    private static func archiveMenu() -> NSMenu {
        let menu = NSMenu(title: "Archive")
        menu.addItem(item("Go Back", #selector(W.goBackInHistory(_:)), "["))
        menu.addItem(item("Go Back", #selector(W.goBackInHistory(_:)), arrow(NSLeftArrowFunctionKey), hidden: true))
        menu.addItem(item("Go Forward", #selector(W.goForwardInHistory(_:)), "]"))
        menu.addItem(item("Go Forward", #selector(W.goForwardInHistory(_:)), arrow(NSRightArrowFunctionKey), hidden: true))
        menu.addItem(.separator())
        menu.addItem(item("View History", #selector(W.viewHistory(_:)), "y"))
        menu.addItem(item("View Archive…", #selector(W.viewArchive(_:))))
        menu.addItem(item("Clear Archive", #selector(W.clearArchive(_:))))
        return menu
    }

    private static func extensionsMenu() -> NSMenu {
        // Installed extensions are listed first by MenuUpdater.
        let menu = NSMenu(title: "Extensions")
        menu.delegate = updater
        menu.addItem(item("Add Extension…", #selector(A.addExtension(_:))))
        menu.addItem(item("Manage Extensions…", #selector(A.manageExtensions(_:))))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Stay On Top", #selector(W.toggleStayOnTop(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Minimize Window", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Open Library…", #selector(W.viewLibrary(_:)), "l", [.command, .shift]))
        menu.addItem(item("View Downloads…", #selector(W.viewDownloads(_:)), "j", [.command, .shift]))
        menu.addItem(item("View Easels…", #selector(W.viewEaselsAndNotes(_:))))
        menu.addItem(item("View Media…", #selector(W.viewMedia(_:))))
        menu.addItem(item("View Boosts…", #selector(W.viewBoosts(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Getting Started", #selector(A.showGettingStarted(_:))))
        menu.addItem(item("Essential Keyboard Shortcuts", #selector(A.showKeyboardShortcuts(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Contact the Team", #selector(A.contactTheTeam(_:))))
        menu.addItem(item("Visit Help Center", #selector(A.visitHelpCenter(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Restore Data", #selector(A.restoreData(_:))))
        menu.addItem(item("Export Arrow Notes", #selector(A.exportNotes(_:))))
        let troubleshooting = NSMenu(title: "Troubleshooting")
        troubleshooting.addItem(item("Record Trace", #selector(A.toggleTraceRecording(_:))))
        troubleshooting.addItem(item("Open Task Manager", #selector(A.openTaskManager(_:))))
        troubleshooting.addItem(.separator())
        troubleshooting.addItem(item("Reveal Arrow Data", #selector(A.revealData(_:))))
        troubleshooting.addItem(item("Copy Arrow Info", #selector(A.copyInfo(_:))))
        menu.addItem(submenu(troubleshooting))
        return menu
    }
}

/// Fills the menus whose content changes: the spaces of the front window,
/// the installed extensions, and the Edit menu, where AppKit adds Writing
/// Tools and AutoFill that Arc does not show.
@MainActor
final class MenuUpdater: NSObject, NSMenuDelegate {
    /// Items listed from the state (spaces, extensions), not commands.
    static let dynamicItem = NSUserInterfaceItemIdentifier("arrow.dynamic")

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.title {
        case "Spaces": updateSpaces(menu)
        case "Extensions": updateExtensions(menu)
        case "Edit": removeSystemItems(menu)
        default: break
        }
    }

    private func clearDynamicItems(_ menu: NSMenu) {
        for item in menu.items where item.identifier == Self.dynamicItem { menu.removeItem(item) }
    }

    private func dynamic(_ item: NSMenuItem) -> NSMenuItem {
        item.identifier = Self.dynamicItem
        return item
    }

    private func updateSpaces(_ menu: NSMenu) {
        clearDynamicItems(menu)
        guard let app = NSApp.delegate as? AppDelegate,
              let previous = menu.items.firstIndex(where: { $0.action == #selector(BrowserWindowController.previousSpace(_:)) })
        else { return }
        let controller = app.lastActiveBrowserWindow ?? app.windowControllers.first
        let spaces = (controller?.store ?? app.store).state.spaces
        for (index, space) in spaces.enumerated().reversed() {
            let item = dynamic(NSMenuItem(title: space.title, action: #selector(BrowserWindowController.selectSpaceAtIndex(_:)),
                                          keyEquivalent: index < 9 ? "\(index + 1)" : ""))
            item.keyEquivalentModifierMask = index < 9 ? [.control] : []
            item.tag = index
            item.state = controller?.state.selectedSpaceID == space.id ? .on : .off
            menu.insertItem(item, at: previous + 1)
        }
    }

    private func updateExtensions(_ menu: NSMenu) {
        clearDynamicItems(menu)
        let manager = ExtensionManager.shared
        let installed = manager.extensions.filter(\.isEnabled)
        guard !installed.isEmpty else { return }
        menu.insertItem(dynamic(.separator()), at: 0)
        for item in installed.reversed() {
            let entry = dynamic(NSMenuItem(title: item.name, action: #selector(BrowserWindowController.runExtension(_:)),
                                           keyEquivalent: ""))
            entry.representedObject = item.id
            if let icon = manager.iconImage(for: item) {
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
            }
            menu.insertItem(entry, at: 0)
        }
    }

    /// Writing Tools, AutoFill and Emoji & Symbols, which AppKit adds to the Edit menu.
    static func removeSystemItems(_ menu: NSMenu) {
        for item in menu.items {
            let actions = ([item] + (item.submenu?.items ?? [])).compactMap(\.action).map(NSStringFromSelector)
            if actions.contains(where: { $0 == "showWritingTools:" || $0 == "orderFrontCharacterPalette:"
                || $0.hasPrefix("_handleInsertFrom") }) {
                menu.removeItem(item)
            }
        }
    }

    private func removeSystemItems(_ menu: NSMenu) {
        Self.removeSystemItems(menu)
    }
}
