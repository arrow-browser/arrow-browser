import AppKit
import ArrowCore
import Observation

/// Downloads of the session, shown in the sidebar and the Library.
@MainActor
@Observable
final class DownloadManager: DownloadCenterDelegate {
    struct Item: Identifiable, Equatable {
        var id: UInt32
        var fileName: String
        var url: String
        var destination: URL
        var receivedBytes: Int64
        var totalBytes: Int64
        var state: Download.State
        var startedAt: Date

        var fraction: Double {
            totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 0
        }
    }

    private(set) var items: [Item] = []
    /// Last download that finished, for the sidebar notification.
    private(set) var recentlyCompleted: Item?
    @ObservationIgnored weak var store: BrowserStore?
    @ObservationIgnored private let center: any DownloadCenter
    @ObservationIgnored private var tabsToClose: [UInt32: UUID] = [:]

    init(center: any DownloadCenter) {
        self.center = center
    }

    /// Receives every download of the application.
    func activate() {
        center.delegate = self
    }

    var activeCount: Int { items.filter { $0.state == .inProgress || $0.state == .paused }.count }

    func downloadCenter(destinationFor suggestedName: String) -> (url: URL, ask: Bool) {
        // Preferences ▸ Profiles ▸ Download location.
        var directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        if let settings = store?.settings, settings.downloadLocation == .folder, !settings.downloadFolder.isEmpty {
            directory = URL(fileURLWithPath: settings.downloadFolder, isDirectory: true)
        }
        let name = suggestedName.isEmpty ? "download" : suggestedName
        var candidate = directory.appendingPathComponent(name)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)")
            index += 1
        }
        return (candidate, store?.settings.downloadLocation == .ask)
    }

    /// Like Chrome, a Today tab opened only for a download is closed. Chromium
    /// stops reporting a download once its browser is gone, so the tab is
    /// closed when the download ends.
    func downloadCenter(didStart downloadID: UInt32, inBrowser browserID: Int32) {
        guard let tab = store?.tabs.values.first(where: { $0.engine?.identifier == browserID }),
              isBlankTodayTab(tab) else { return }
        tabsToClose[downloadID] = tab.id
    }

    private func isBlankTodayTab(_ tab: WebTab) -> Bool {
        guard let store, let engine = tab.engine, !engine.canGoBack,
              store.state.location(of: tab.id)?.section == .today else { return false }
        let committedURL = engine.currentURL ?? ""
        return committedURL.isEmpty || committedURL == "about:blank"
    }

    func downloadCenter(didUpdate download: Download) {
        let destination = download.fullPath.isEmpty ? nil : URL(fileURLWithPath: download.fullPath)
        let index: Int
        let wasComplete: Bool
        if let existing = items.firstIndex(where: { $0.id == download.id }) {
            index = existing
            wasComplete = items[index].state == .complete
            items[index].receivedBytes = download.receivedBytes
            items[index].totalBytes = download.totalBytes
            items[index].state = download.state
            if let destination {
                items[index].destination = destination
                items[index].fileName = destination.lastPathComponent
            }
        } else if let destination {
            items.insert(Item(id: download.id, fileName: destination.lastPathComponent, url: download.url,
                              destination: destination, receivedBytes: download.receivedBytes,
                              totalBytes: download.totalBytes, state: download.state, startedAt: Date()), at: 0)
            index = 0
            // Small or cached files can be complete in their first update.
            wasComplete = false
        } else {
            return
        }
        if download.state != .inProgress, download.state != .paused,
           let tabID = tabsToClose.removeValue(forKey: download.id),
           let tab = store?.tabs[tabID], isBlankTodayTab(tab) {
            tab.host?.tabDidRequestClose(tab)
        }
        if download.state == .complete, !wasComplete {
            recentlyCompleted = items[index]
            NSWorkspace.shared.noteFileSystemChanged(items[index].destination.path)
            if let store {
                let id = items[index].id
                AIFeatures.tidyDownload(items[index], in: store) { [weak self] renamed in
                    guard let self, let position = items.firstIndex(where: { $0.id == id }) else { return }
                    items[position].destination = renamed
                    items[position].fileName = renamed.lastPathComponent
                }
            }
        }
    }

    func cancel(_ item: Item) { center.cancel(item.id) }
    func pause(_ item: Item) { center.pause(item.id) }
    func resume(_ item: Item) { center.resume(item.id) }

    func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.destination])
    }

    func open(_ item: Item) {
        NSWorkspace.shared.open(item.destination)
    }

    func clearFinished() {
        items.removeAll { $0.state != .inProgress && $0.state != .paused }
        recentlyCompleted = nil
    }

    func dismissRecent() {
        recentlyCompleted = nil
    }
}
