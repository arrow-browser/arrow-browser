import AppKit
import ArrowKit
import Observation

/// A transient notification shown at the bottom of the content ("Copied URL").
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var symbol: String
}

/// Sheets and panels presented over a browser window.
enum WindowSheet: Identifiable, Equatable {
    case spaceEditor(spaceID: UUID?)
    case boostEditor(boostID: UUID?, url: String?)
    case library(LibrarySection)
    case profileEditor
    case welcome

    var id: String {
        switch self {
        case let .spaceEditor(spaceID): "space-\(spaceID?.uuidString ?? "new")"
        case let .boostEditor(boostID, url): "boost-\(boostID?.uuidString ?? url ?? "new")"
        case let .library(section): "library-\(section.rawValue)"
        case .profileEditor: "profile"
        case .welcome: "welcome"
        }
    }
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case archive = "Archive"
    case history = "History"
    case downloads = "Downloads"
    case media = "Media"
    case easelsAndNotes = "Easels & Notes"
    case boosts = "Boosts"
    case spaces = "Spaces"

    var id: String { rawValue }

    /// The sections of the Library's rail, in Arc's order. History is not
    /// one of them: it opens from Archive ▸ View History (⌘Y).
    static let rail: [LibrarySection] = [.media, .downloads, .easelsAndNotes, .spaces, .boosts, .archive]

    var symbol: String {
        switch self {
        case .archive: "archivebox"
        case .history: "clock"
        case .downloads: "arrow.down.circle"
        case .media: "photo.on.rectangle.angled"
        case .easelsAndNotes: "macwindow"
        case .boosts: "paintbrush.pointed"
        case .spaces: "rectangle.on.rectangle.angled"
        }
    }

    /// Label under the icon in the rail.
    var railTitle: String {
        switch self {
        case .archive: "Archived Tabs"
        case .easelsAndNotes: "Easels"
        default: rawValue
        }
    }

    var searchPrompt: String {
        switch self {
        case .easelsAndNotes: "Search Easels…"
        default: "Search \(rawValue)…"
        }
    }
}

/// A page previewed in a floating panel over the current tab (Peek).
struct PeekState: Identifiable {
    var id: UUID { tab.id }
    let tab: WebTab
}

/// Per-window UI state: selected space and tab, sidebar, overlays.
@MainActor
@Observable
final class WindowState {
    var selectedSpaceID: UUID
    var selectedTabID: UUID?
    var isSidebarVisible = true
    /// Sidebar temporarily shown over the content while hidden.
    var isSidebarRevealed = false
    var commandBar: CommandBarModel?
    var peek: PeekState?
    var isFindBarVisible = false
    var toast: Toast?
    var sheet: WindowSheet?
    /// Space whose theme is being edited (Spaces ▸ Edit Theme…).
    var themePickerSpaceID: UUID?
    /// Node being renamed inline in the sidebar.
    var renamingNodeID: UUID?
    /// Pane of a split view that has focus.
    var focusedPaneID: UUID?
    /// View ▸ Expand Current Split: the pane shown alone.
    var expandedPaneID: UUID?
    /// View ▸ Collapse Pinned Tabs.
    var isPinnedCollapsed = false
    /// Tabs ▸ Reveal Tab in Sidebar: each change scrolls the sidebar to the selected tab.
    var revealRequest = 0
    var isFullscreenContent = false
    /// Capture (⇧⌘2): the user is selecting an area of the page.
    var isCapturing = false
    /// ⌃Tab switcher: recent tabs and the highlighted one.
    var tabSwitcher: (tabIDs: [UUID], index: Int)?

    /// Last selected tab of each space.
    @ObservationIgnored var lastSelection: [UUID: UUID] = [:]
    /// Most recently used tabs, newest first (Ctrl+Tab).
    @ObservationIgnored var recentTabIDs: [UUID] = []
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(selectedSpaceID: UUID) {
        self.selectedSpaceID = selectedSpaceID
    }

    func showToast(_ message: String, symbol: String = "checkmark.circle.fill") {
        toast = Toast(message: message, symbol: symbol)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Selection restored at the next launch (normal windows only).
    struct Snapshot: Codable {
        var selectedSpaceID: UUID
        var lastSelection: [UUID: UUID]
        var isSidebarVisible: Bool
    }

    private static let snapshotKey = "ArrowWindowSnapshot"

    static func restoredSnapshot() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func saveSnapshot() {
        let snapshot = Snapshot(selectedSpaceID: selectedSpaceID, lastSelection: lastSelection, isSidebarVisible: isSidebarVisible)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.snapshotKey)
        }
    }

    func noteSelection(_ tabID: UUID, in spaceID: UUID) {
        lastSelection[spaceID] = tabID
        recentTabIDs.removeAll { $0 == tabID }
        recentTabIDs.insert(tabID, at: 0)
        if recentTabIDs.count > 50 { recentTabIDs.removeLast() }
    }
}
