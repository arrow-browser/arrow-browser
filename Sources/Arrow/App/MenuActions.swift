import AppKit
import ArrowCEF
import ArrowCore
import ArrowKit
import SwiftUI

/// Menu commands of Arc's menu bar that are not tied to a page: sharing,
/// help, data restore, troubleshooting.
extension AppDelegate: NSMenuItemValidation {
    static let projectURL = URL(string: "https://github.com/arrow-browser/arrow-browser")!

    @objc func shareArrow(_ sender: Any?) {
        let controller = frontBrowserWindow()
        guard let view = controller.window?.contentView else { return }
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1)
        NSSharingServicePicker(items: [Self.projectURL]).show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    /// Arrow ▸ Quit Arrow. Not `terminate:` itself, so AppKit does not add
    /// "Quit and Keep Windows" (Arc has no such item).
    @objc func quitArrow(_ sender: Any?) {
        if store.settings.warnBeforeQuitting {
            switch QuitWarning.confirm() {
            case .cancel: return
            case .quitAndStopAsking:
                store.settings.warnBeforeQuitting = false
                store.saveNow()
            case .quit: break
            }
        }
        NSApp.terminate(sender)
    }

    /// Preferences ▸ Advanced ▸ Export Data: Arrow's state as a zip archive.
    @objc func exportData(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Arrow Data.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", store.dataDirectory.path, destination.path]
        ditto.terminationHandler = { process in
            Task { @MainActor in
                if process.terminationStatus == 0 { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            }
        }
        try? ditto.run()
    }

    @objc func showPrivacyPolicy(_ sender: Any?) {
        _ = frontBrowserWindow().openNewTab(Self.projectURL.absoluteString + "/blob/main/docs/PRIVACY.md")
    }

    @objc func visitHelpCenter(_ sender: Any?) {
        _ = frontBrowserWindow().openNewTab(Self.projectURL.absoluteString + "#readme")
    }

    @objc func showGettingStarted(_ sender: Any?) {
        frontBrowserWindow().state.sheet = .welcome
    }

    @objc func signOutOfCloud(_ sender: Any?) {
        Task { await store.cloud.signOut() }
    }

    /// Help ▸ Contact the Team: feedback sent through Arrow Cloud.
    @objc func contactTheTeam(_ sender: Any?) {
        guard store.cloud.isSignedIn else {
            let alert = NSAlert()
            alert.messageText = "Sign in to Arrow Cloud to contact the team"
            alert.informativeText = "Feedback is sent to the Arrow Cloud server set in Settings ▸ Arrow Cloud."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Contact the Team"
        alert.informativeText = "Tell us what works, what doesn’t, or what you miss from Arc."
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 360, height: 140)
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView // swiftlint:disable:this force_cast
        text.font = .systemFont(ofSize: 13)
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = text
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let message = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        Task {
            do {
                try await store.cloud.sendFeedback(message, email: store.cloud.user?.email)
                frontBrowserWindow().state.showToast("Thanks! Your message was sent", symbol: "paperplane")
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Help ▸ Restore Data: puts back a dated copy of the sidebar.
    @objc func restoreData(_ sender: Any?) {
        let backups = store.sidebarBackups()
        let alert = NSAlert()
        guard !backups.isEmpty else {
            alert.messageText = "No Backup Yet"
            alert.informativeText = "Arrow keeps dated copies of your spaces, pinned tabs and folders as you use it."
            alert.runModal()
            return
        }
        alert.messageText = "Restore Data"
        alert.informativeText = "Your spaces, pinned tabs and folders go back to how they were at that time. "
            + "The current state is kept as a backup."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        popup.addItems(withTitles: backups.map(Self.backupTitle))
        alert.accessoryView = popup
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = store.restoreSidebar(from: backups[popup.indexOfSelectedItem])
    }

    private static func backupTitle(_ url: URL) -> String {
        // Sidebar.yyyy-MM-dd-HH-mm-ss-SSS.json
        let stamp = url.deletingPathExtension().pathExtension
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd-HH-mm-ss-SSS"
        guard let date = parser.date(from: stamp) else { return url.lastPathComponent }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    /// Help ▸ Export Arrow Notes: one RTF file per note.
    @objc func exportNotes(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to export your notes."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var used = Set<String>()
        for note in store.notes {
            var name = note.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            if name.isEmpty { name = "Untitled" }
            var candidate = name
            var index = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(name) \(index)"
                index += 1
            }
            used.insert(candidate.lowercased())
            try? note.body.write(to: folder.appendingPathComponent(candidate).appendingPathExtension("rtf"))
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Help ▸ Troubleshooting ▸ Record Trace / Stop Recording Trace.
    @objc func toggleTraceRecording(_ sender: Any?) {
        let tracing = CEFTracing.shared
        guard tracing.isRecording else {
            tracing.start()
            return
        }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let file = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Arrow Trace \(stamp).json")
        tracing.stop(writingTo: file) { written in
            NSWorkspace.shared.activateFileViewerSelecting([written])
        }
    }

    @objc func openTaskManager(_ sender: Any?) {
        if let window = taskManagerWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: TaskManagerView()))
        window.title = "Task Manager"
        window.setContentSize(NSSize(width: 600, height: 380))
        window.isReleasedWhenClosed = false
        window.center()
        taskManagerWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// View ▸ Appearance (tag: 0 automatic, 1 light, 2 dark).
    @objc func setContentAppearance(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        store.settings.contentAppearance = ContentAppearance.allCases[item.tag]
    }

    @objc func toggleJavaScriptFromAppleEvents(_ sender: Any?) {
        store.settings.allowJavaScriptFromAppleEvents.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(signOutOfCloud(_:)):
            return store.cloud.isSignedIn
        case #selector(toggleTraceRecording(_:)):
            menuItem.title = CEFTracing.shared.isRecording ? "Stop Recording Trace" : "Record Trace"
            return true
        case #selector(setContentAppearance(_:)):
            menuItem.state = ContentAppearance.allCases[menuItem.tag] == store.settings.contentAppearance ? .on : .off
            return true
        case #selector(toggleJavaScriptFromAppleEvents(_:)):
            menuItem.state = store.settings.allowJavaScriptFromAppleEvents ? .on : .off
            return true
        case #selector(exportNotes(_:)):
            return !store.notes.isEmpty
        default:
            return true
        }
    }
}

/// Window commands added to match Arc's menus.
extension BrowserWindowController {
    /// File ▸ Capture in Portrait Mode: the page as a phone shows it.
    @objc func captureInPortraitMode(_ sender: Any?) {
        guard let tab = selectedTab, let engine = tab.engine else { return }
        Task {
            _ = await engine.devToolsMethod("Emulation.setDeviceMetricsOverride", params: [
                "width": 430, "height": 932, "deviceScaleFactor": 0, "mobile": true,
            ])
            try? await Task.sleep(for: .milliseconds(600))
            let data = await engine.captureScreenshot(clip: nil)
            _ = await engine.devToolsMethod("Emulation.clearDeviceMetricsOverride")
            guard let data, let image = NSImage(data: data) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            if !isIncognito { MediaLibrary.saveCapture(image, from: tab, in: store) }
            store.playSound(.capture)
            state.showToast("Capture copied to clipboard", symbol: "camera.viewfinder")
        }
    }

    @objc func toggleCollapsePinnedTabs(_ sender: Any?) {
        withAnimation(.easeInOut(duration: 0.2)) { state.isPinnedCollapsed.toggle() }
    }

    @objc func toggleExpandCurrentSplit(_ sender: Any?) {
        state.expandedPaneID = state.expandedPaneID == nil ? (state.focusedPaneID ?? state.selectedTabID) : nil
    }

    @objc func revealTabInSidebar(_ sender: Any?) {
        guard let id = state.selectedTabID else { return }
        if !state.isSidebarVisible { setSidebarVisible(true) }
        state.isPinnedCollapsed = false
        store.update { $0.expandFolders(containing: id) }
        state.revealRequest += 1
    }

    @objc func collapseAllFolders(_ sender: Any?) {
        store.update { $0.setFoldersExpanded(false, in: state.selectedSpaceID) }
    }

    @objc func expandAllFolders(_ sender: Any?) {
        store.update { $0.setFoldersExpanded(true, in: state.selectedSpaceID) }
    }

    @objc func toggleStayOnTop(_ sender: Any?) {
        guard let window else { return }
        window.level = window.level == .floating ? .normal : .floating
    }

    @objc func viewMedia(_ sender: Any?) {
        state.sheet = .library(.media)
    }

    /// View ▸ Cast: the page's video or audio on a Cast device.
    @objc func castMedia(_ sender: Any?) {
        CastPopoverController.show(from: self)
    }

    /// View ▸ Developer ▸ Network Inspector: Developer Tools on the Network panel.
    @objc func showNetworkInspector(_ sender: Any?) {
        selectedTab?.engine?.showDevTools(panel: "network")
    }

    /// File ▸ New Document (command bar): the app chosen in Preferences ▸ Profiles.
    @objc func newDocument(_ sender: Any?) {
        guard let url = store.settings.documentApp.newDocumentURL else {
            (NSApp.delegate as? AppDelegate)?.showSettings(pane: .profiles)
            return
        }
        _ = openNewTab(url)
    }

    /// Extensions ▸ <extension>: its popup, or its options page.
    @objc func runExtension(_ sender: Any?) {
        let manager = ExtensionManager.shared
        guard let id = (sender as? NSMenuItem)?.representedObject as? String,
              let item = manager.extensions.first(where: { $0.id == id }) else { return }
        if let popup = manager.popupURL(for: item) {
            ExtensionPopupController.show(url: popup, from: self)
        } else if let options = manager.optionsURL(for: item) {
            _ = openNewTab(options)
        }
    }
}
