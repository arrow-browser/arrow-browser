import AppKit
import ArrowCore
import ArrowKit

/// Menu and keyboard commands of a browser window (see MainMenu.swift).
extension BrowserWindowController: NSMenuItemValidation {
    // MARK: File

    @objc func newTab(_ sender: Any?) {
        showCommandBar(mode: .newTab)
    }

    @objc func restoreLastClosedTab(_ sender: Any?) {
        reopenLastClosedTab()
    }

    @objc func openCommandBar(_ sender: Any?) {
        guard let tab = selectedTab else {
            showCommandBar(mode: .newTab)
            return
        }
        let text = tab.internalPage == nil ? tab.url : ""
        showCommandBar(mode: .editCurrent(tabID: tab.id), anchor: store.settings.showURLBar && state.isSidebarVisible ? .sidebar : .center,
                       text: text)
    }

    @objc func newNote(_ sender: Any?) {
        let note = Note()
        store.saveNote(note)
        openNewTab(note.url)
    }

    @objc func newEasel(_ sender: Any?) {
        let easel = Easel()
        store.saveEasel(easel)
        openNewTab(easel.url)
    }

    @objc func newBoost(_ sender: Any?) {
        state.sheet = .boostEditor(boostID: nil, url: selectedTab?.url)
    }

    @objc func archiveTab(_ sender: Any?) {
        if state.peek != nil {
            closePeek()
            return
        }
        if state.commandBar != nil {
            dismissCommandBar()
            return
        }
        guard let id = state.focusedPaneID ?? state.selectedTabID else {
            window?.performClose(sender)
            return
        }
        closeTab(id)
    }

    /// Capture (⇧⌘2): select an area of the page to copy.
    @objc func capturePage(_ sender: Any?) {
        guard selectedTab?.engine != nil else { return }
        state.isCapturing = true
    }

    /// Translates the page into the user's language.
    @objc func translatePage(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        let language = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        guard let translated = PageTranslation.url(for: tab.url, to: language) else { return }
        tab.load(translated)
    }

    @objc func zapElements(_ sender: Any?) {
        guard let tab = selectedTab, tab.engine != nil else { return }
        tab.startZapping()
        state.showToast("Click elements to hide them — Esc when done", symbol: "bolt.fill")
    }

    @objc func captureFullPage(_ sender: Any?) {
        capture(fullPage: true)
    }

    @objc func savePageAs(_ sender: Any?) {
        guard let tab = selectedTab, let engine = tab.engine else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (tab.displayTitle.isEmpty ? "page" : tab.displayTitle) + ".pdf"
        panel.allowedContentTypes = [.pdf]
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                Task {
                    guard let base64 = await engine.devToolsMethod("Page.printToPDF", params: ["printBackground": true])?["data"] as? String,
                          let data = Data(base64Encoded: base64) else { return }
                    try? data.write(to: url)
                }
            }
        }
    }

    @objc func printPage(_ sender: Any?) {
        selectedTab?.engine?.print()
    }

    @objc func sharePage(_ sender: Any?) {
        guard let tab = selectedTab, let url = URL(string: tab.url), let contentView = window?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: NSRect(x: contentView.bounds.midX, y: contentView.bounds.maxY - 40, width: 1, height: 1),
                    of: contentView, preferredEdge: .minY)
    }

    // MARK: Edit

    @objc func copyURL(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        copyToPasteboard(tab.url, toast: "Copied URL to clipboard")
        store.playSound(.event)
    }

    @objc func copyURLAsMarkdown(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        copyToPasteboard("[\(tab.displayTitle)](\(tab.url))", toast: "Copied URL as Markdown")
        store.playSound(.event)
    }

    @objc func copyURLAsQuote(_ sender: Any?) {
        guard let tab = selectedTab, let engine = tab.engine else { return }
        Task {
            let selection = await engine.evaluateJavaScript("window.getSelection().toString()") as? String ?? ""
            let quote = selection.isEmpty ? tab.displayTitle : selection
            copyToPasteboard("> \(quote)\n\n— [\(tab.displayTitle)](\(tab.url))", toast: "Copied quote to clipboard")
        }
    }

    @objc func findInPage(_ sender: Any?) {
        guard selectedTab?.engine != nil else { return }
        state.isFindBarVisible = true
    }

    @objc func findNextMatch(_ sender: Any?) {
        guard let tab = selectedTab, let text = tab.find?.text, !text.isEmpty else {
            findInPage(sender)
            return
        }
        tab.find(text, forward: true)
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        guard let tab = selectedTab, let text = tab.find?.text, !text.isEmpty else { return }
        tab.find(text, forward: false)
    }

    @objc func useSelectionToFind(_ sender: Any?) {
        guard let tab = selectedTab, let engine = tab.engine else { return }
        Task {
            guard let selection = await engine.evaluateJavaScript("window.getSelection().toString()") as? String,
                  !selection.isEmpty else { return }
            state.isFindBarVisible = true
            tab.find(selection)
        }
    }

    // MARK: View

    @objc func toggleArrowSidebar(_ sender: Any?) {
        setSidebarVisible(!state.isSidebarVisible)
    }

    /// Arc's hidden "Show/Hide Toolbar" (⇧⌘D).
    @objc func toggleToolbar(_ sender: Any?) {
        store.settings.showToolbar.toggle()
    }

    @objc func stopLoadingPage(_ sender: Any?) {
        selectedTab?.stopLoading()
    }

    @objc func reloadPage(_ sender: Any?) {
        selectedTab?.reload()
    }

    @objc func forceReloadPage(_ sender: Any?) {
        selectedTab?.reload(ignoringCache: true)
    }

    @objc func clearCookiesAndReload(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        store.requestContext(for: tab.profileID).deleteCookies(url: tab.url)
        tab.reload(ignoringCache: true)
        state.showToast("Cleared cookies for \(URLDisplay.short(tab.url))", symbol: "trash")
    }

    @objc func clearCacheAndReload(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        store.requestContext(for: tab.profileID).clearHTTPCache()
        tab.reload(ignoringCache: true)
        state.showToast("Cleared cache", symbol: "trash")
    }

    @objc func addSplitView(_ sender: Any?) {
        guard let tab = selectedTab else {
            showCommandBar(mode: .newTab)
            return
        }
        if let split = selectedSplit, split.tabs.count >= SplitView.maximumTabs {
            NSSound.beep()
            return
        }
        showCommandBar(mode: .splitPane(besideTabID: tab.id))
    }

    @objc func closeSplitPane(_ sender: Any?) {
        guard selectedSplit != nil, let id = state.focusedPaneID ?? state.selectedTabID else { return }
        closeTab(id)
    }

    @objc func separateFromSplit(_ sender: Any?) {
        guard let split = selectedSplit else { return }
        store.update { $0.dissolveSplit(split.id) }
    }

    @objc func zoomActualSize(_ sender: Any?) {
        selectedTab?.resetZoom()
    }

    @objc func zoomInPage(_ sender: Any?) {
        selectedTab?.zoomIn()
    }

    @objc func zoomOutPage(_ sender: Any?) {
        selectedTab?.zoomOut()
    }

    @objc func viewPageSource(_ sender: Any?) {
        guard let tab = selectedTab, tab.engine != nil else { return }
        openNewTab("view-source:\(tab.url)")
    }

    @objc func showDeveloperTools(_ sender: Any?) {
        selectedTab?.engine?.showDevTools()
    }

    @objc func inspectElements(_ sender: Any?) {
        guard let engine = selectedTab?.engine else { return }
        engine.showDevTools()
        Task { _ = await engine.devToolsMethod("Overlay.setInspectMode", params: ["mode": "searchForNode", "highlightConfig": [:]]) }
    }

    @objc func showJavaScriptConsole(_ sender: Any?) {
        selectedTab?.engine?.showDevTools(panel: "console")
    }

    @objc func toggleDeveloperMode(_ sender: Any?) {
        store.settings.developerMode.toggle()
        state.showToast(store.settings.developerMode ? "Developer Mode on" : "Developer Mode off",
                        symbol: "hammer")
    }

    @objc func toggleContentFullScreen(_ sender: Any?) {
        window?.toggleFullScreen(sender)
    }

    @objc func exitContentFullScreen(_ sender: Any?) {
        if state.isCapturing {
            state.isCapturing = false
        } else if selectedTab?.isZapping == true {
            selectedTab?.stopZapping()
        } else if state.peek != nil {
            closePeek()
        } else if state.commandBar != nil {
            dismissCommandBar()
        } else if state.isFindBarVisible {
            state.isFindBarVisible = false
            selectedTab?.endFind()
        } else if selectedTab?.isFullscreen == true {
            selectedTab?.engine?.exitFullscreen()
        } else if selectedTab?.isLoading == true {
            selectedTab?.stopLoading()
        }
    }

    // MARK: Spaces

    @objc func newSpace(_ sender: Any?) {
        state.sheet = .spaceEditor(spaceID: nil)
    }

    @objc func editSpaceTheme(_ sender: Any?) {
        state.themePickerSpaceID = state.selectedSpaceID
    }

    @objc func renameSpace(_ sender: Any?) {
        state.renamingNodeID = state.selectedSpaceID
    }

    @objc func changeSpaceProfile(_ sender: Any?) {
        state.sheet = .spaceEditor(spaceID: state.selectedSpaceID)
    }

    @objc func nextSpace(_ sender: Any?) {
        selectSpace(offset: 1)
    }

    @objc func previousSpace(_ sender: Any?) {
        selectSpace(offset: -1)
    }

    @objc func manageSpaces(_ sender: Any?) {
        state.sheet = .library(.spaces)
    }

    @objc func selectSpaceAtIndex(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let spaces = store.state.spaces
        guard spaces.indices.contains(item.tag) else { return }
        selectSpace(spaces[item.tag].id)
    }

    // MARK: Tabs

    @objc func togglePinTab(_ sender: Any?) {
        guard let id = state.selectedTabID else { return }
        let wasPinned = store.state.isPinned(id)
        store.update { $0.togglePin(id) }
        store.playSound(.event)
        if !wasPinned { AIFeatures.tidyTitle(of: id, in: store) }
        state.showToast(wasPinned ? "Unpinned Tab" : "Pinned Tab", symbol: wasPinned ? "pin.slash" : "pin")
    }

    @objc func openLittleArrowOrPeek(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.newLittleArrowWindow(sender)
    }

    @objc func newFolder(_ sender: Any?) {
        var folder: Folder?
        store.update { folder = $0.createFolder(in: state.selectedSpaceID) }
        state.renamingNodeID = folder?.id
    }

    @objc func duplicateTab(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        openNewTab(tab.url)
    }

    @objc func renameCurrentItem(_ sender: Any?) {
        state.renamingNodeID = state.selectedTabID
    }

    @objc func nextTab(_ sender: Any?) {
        selectTab(offset: 1)
    }

    @objc func previousTab(_ sender: Any?) {
        selectTab(offset: -1)
    }

    /// ⌃Tab: shows recent tabs; releasing ⌃ opens the highlighted one.
    @objc func tabSwitcherForward(_ sender: Any?) {
        advanceTabSwitcher(by: 1)
    }

    @objc func tabSwitcherBackward(_ sender: Any?) {
        advanceTabSwitcher(by: -1)
    }

    private func advanceTabSwitcher(by delta: Int) {
        if let switcher = state.tabSwitcher {
            let count = switcher.tabIDs.count
            state.tabSwitcher?.index = (switcher.index + delta + count) % count
            return
        }
        let recent = Array(state.recentTabIDs.filter { store.state.tab($0) != nil }.prefix(9))
        guard recent.count > 1 else { return }
        state.tabSwitcher = (recent, delta > 0 ? 1 : recent.count - 1)
        guard NSEvent.modifierFlags.contains(.control) else {
            commitTabSwitcher()
            return
        }
        tabSwitcherMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if !event.modifierFlags.contains(.control) { self?.commitTabSwitcher() }
            return event
        }
    }

    func commitTabSwitcher() {
        if let monitor = tabSwitcherMonitor {
            NSEvent.removeMonitor(monitor)
            tabSwitcherMonitor = nil
        }
        guard let switcher = state.tabSwitcher else { return }
        state.tabSwitcher = nil
        select(switcher.tabIDs[switcher.index])
    }

    @objc func selectTabAtIndex(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let ids = orderedSidebarTabIDs
        guard !ids.isEmpty else { return }
        // Cmd+9 always selects the last tab, as in Chrome and Arc.
        let index = item.tag == 8 ? ids.count - 1 : item.tag
        guard ids.indices.contains(index) else { return }
        select(ids[index])
    }

    @objc func clearUnpinnedTabs(_ sender: Any?) {
        let kept: Set<UUID> = []
        var cleared: [Tab] = []
        store.update { cleared = $0.clearToday(in: state.selectedSpaceID, keeping: kept) }
        if !cleared.isEmpty { store.playSound(.event) }
        for tab in cleared { store.discardRuntime(tab.id) }
        if let selected = state.selectedTabID, store.state.tab(selected) == nil {
            state.selectedTabID = nil
        }
    }

    @objc func resetAllTabsInSpace(_ sender: Any?) {
        guard let space = selectedSpace else { return }
        for tab in space.pinned.allTabs where tab.hasNavigatedAwayFromPinnedURL {
            store.close(tab.id)
        }
    }

    @objc func resetTabToOriginalURL(_ sender: Any?) {
        guard let id = state.selectedTabID, let pinnedURL = store.state.tab(id)?.pinnedURL else { return }
        store.webTab(id)?.load(pinnedURL)
    }

    // MARK: Archive (history navigation)

    @objc func goBackInHistory(_ sender: Any?) {
        selectedTab?.goBack()
    }

    @objc func goForwardInHistory(_ sender: Any?) {
        selectedTab?.goForward()
    }

    @objc func viewHistory(_ sender: Any?) {
        state.sheet = .library(.history)
    }

    @objc func viewArchive(_ sender: Any?) {
        state.sheet = .library(.archive)
    }

    @objc func clearArchive(_ sender: Any?) {
        store.update { $0.archive.removeAll() }
    }

    // MARK: Window

    /// Window ▸ Open Library…: opens on Media, like Arc.
    @objc func viewLibrary(_ sender: Any?) {
        state.sheet = .library(.media)
    }

    @objc func viewDownloads(_ sender: Any?) {
        state.sheet = .library(.downloads)
    }

    @objc func viewEaselsAndNotes(_ sender: Any?) {
        state.sheet = .library(.easelsAndNotes)
    }

    @objc func viewBoosts(_ sender: Any?) {
        state.sheet = .library(.boosts)
    }

    @objc func closeBrowserWindow(_ sender: Any?) {
        window?.performClose(sender)
    }

    // MARK: Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let tab = selectedTab
        switch menuItem.action {
        case #selector(goBackInHistory(_:)): return tab?.canGoBack ?? false
        case #selector(goForwardInHistory(_:)): return tab?.canGoForward ?? false
        case #selector(copyURL(_:)), #selector(copyURLAsMarkdown(_:)), #selector(copyURLAsQuote(_:)),
             #selector(reloadPage(_:)), #selector(forceReloadPage(_:)), #selector(findInPage(_:)),
             #selector(capturePage(_:)), #selector(captureFullPage(_:)), #selector(savePageAs(_:)), #selector(printPage(_:)),
             #selector(viewPageSource(_:)), #selector(showDeveloperTools(_:)), #selector(inspectElements(_:)),
             #selector(showJavaScriptConsole(_:)), #selector(zoomInPage(_:)), #selector(zoomOutPage(_:)),
             #selector(zoomActualSize(_:)), #selector(clearCookiesAndReload(_:)), #selector(clearCacheAndReload(_:)),
             #selector(duplicateTab(_:)), #selector(sharePage(_:)):
            return tab?.engine != nil
        case #selector(stopLoadingPage(_:)): return tab?.isLoading ?? false
        case #selector(zapElements(_:)): return tab?.engine != nil && !isIncognito
        case #selector(translatePage(_:)): return tab?.url.hasPrefix("http") ?? false
        case #selector(togglePinTab(_:)):
            guard let id = state.selectedTabID else { return false }
            menuItem.title = store.state.isPinned(id) ? "Unpin Tab" : "Pin Tab"
            return !store.state.isFavorite(id)
        case #selector(closeSplitPane(_:)), #selector(separateFromSplit(_:)): return selectedSplit != nil
        case #selector(toggleExpandCurrentSplit(_:)):
            menuItem.state = state.expandedPaneID != nil ? .on : .off
            return selectedSplit != nil
        case #selector(toggleStayOnTop(_:)):
            menuItem.state = window?.level == .floating ? .on : .off
            return true
        case #selector(toggleCollapsePinnedTabs(_:)):
            menuItem.title = state.isPinnedCollapsed ? "Expand Pinned Tabs" : "Collapse Pinned Tabs"
            return true
        case #selector(revealTabInSidebar(_:)): return state.selectedTabID != nil
        case #selector(captureInPortraitMode(_:)), #selector(showNetworkInspector(_:)): return tab?.engine != nil
        case #selector(resetTabToOriginalURL(_:)):
            return state.selectedTabID.flatMap { store.state.tab($0)?.hasNavigatedAwayFromPinnedURL } ?? false
        case #selector(toggleToolbar(_:)):
            menuItem.title = store.settings.showToolbar ? "Hide Toolbar" : "Show Toolbar"
            return true
        case #selector(toggleArrowSidebar(_:)):
            menuItem.title = state.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
            return true
        case #selector(toggleDeveloperMode(_:)):
            menuItem.state = store.settings.developerMode ? .on : .off
            return true
        case #selector(newSpace(_:)), #selector(editSpaceTheme(_:)), #selector(renameSpace(_:)), #selector(changeSpaceProfile(_:)),
             #selector(newNote(_:)), #selector(newEasel(_:)), #selector(newBoost(_:)), #selector(newFolder(_:)):
            return !isIncognito
        default: return true
        }
    }
}
