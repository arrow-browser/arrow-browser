import ArrowKit
import Foundation
import Observation

/// A transient notification shown at the bottom of the content ("Copied URL").
public struct Toast: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var message: String
    public var symbol: String
}

/// Sheets and panels presented over a browser window.
public enum WindowSheet: Identifiable, Equatable, Sendable {
    case spaceEditor(spaceID: UUID?)
    case boostEditor(boostID: UUID?, url: String?)
    case library(LibrarySection)
    case profileEditor
    case welcome

    public var id: String {
        switch self {
        case let .spaceEditor(spaceID): "space-\(spaceID?.uuidString ?? "new")"
        case let .boostEditor(boostID, url): "boost-\(boostID?.uuidString ?? url ?? "new")"
        case let .library(section): "library-\(section.rawValue)"
        case .profileEditor: "profile"
        case .welcome: "welcome"
        }
    }
}

public enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
    case archive = "Archive"
    case history = "History"
    case downloads = "Downloads"
    case media = "Media"
    case easelsAndNotes = "Easels & Notes"
    case boosts = "Boosts"
    case spaces = "Spaces"

    public var id: String { rawValue }

    /// The sections of the Library's rail, in Arc's order. History is not
    /// one of them: it opens from Archive ▸ View History (⌘Y).
    public static let rail: [LibrarySection] = [.media, .downloads, .easelsAndNotes, .spaces, .boosts, .archive]

    public var symbol: String {
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
    public var railTitle: String {
        switch self {
        case .archive: "Archived Tabs"
        case .easelsAndNotes: "Easels"
        default: rawValue
        }
    }

    public var searchPrompt: String {
        switch self {
        case .easelsAndNotes: "Search Easels…"
        default: "Search \(rawValue)…"
        }
    }
}

/// A page previewed in a floating panel over the current tab (Peek).
public struct PeekState: Identifiable {
    public var id: UUID { tab.id }
    public let tab: WebTab

    public init(tab: WebTab) {
        self.tab = tab
    }
}

/// Per-window UI state: selected space and tab, sidebar, overlays.
@MainActor
@Observable
public final class WindowState {
    public var selectedSpaceID: UUID
    public var selectedTabID: UUID?
    public var isSidebarVisible = true
    /// Sidebar temporarily shown over the content while hidden.
    public var isSidebarRevealed = false
    public var commandBar: CommandBarModel?
    public var peek: PeekState?
    public var isFindBarVisible = false
    public var toast: Toast?
    public var sheet: WindowSheet?
    /// Space whose theme is being edited (Spaces ▸ Edit Theme…).
    public var themePickerSpaceID: UUID?
    /// Node being renamed inline in the sidebar.
    public var renamingNodeID: UUID?
    /// Pane of a split view that has focus.
    public var focusedPaneID: UUID?
    /// View ▸ Expand Current Split: the pane shown alone.
    public var expandedPaneID: UUID?
    /// View ▸ Collapse Pinned Tabs.
    public var isPinnedCollapsed = false
    /// Tabs ▸ Reveal Tab in Sidebar: each change scrolls the sidebar to the selected tab.
    public var revealRequest = 0
    public var isFullscreenContent = false
    /// Capture (⇧⌘2): the user is selecting an area of the page.
    public var isCapturing = false
    /// ⌃Tab switcher: recent tabs and the highlighted one.
    public var tabSwitcher: (tabIDs: [UUID], index: Int)?

    /// Last selected tab of each space.
    @ObservationIgnored public var lastSelection: [UUID: UUID] = [:]
    /// Most recently used tabs, newest first (Ctrl+Tab).
    @ObservationIgnored public var recentTabIDs: [UUID] = []
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    public init(selectedSpaceID: UUID) {
        self.selectedSpaceID = selectedSpaceID
    }

    public func showToast(_ message: String, symbol: String = "checkmark.circle.fill") {
        toast = Toast(message: message, symbol: symbol)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Selection restored at the next launch (normal windows only).
    public struct Snapshot: Codable {
        public var selectedSpaceID: UUID
        public var lastSelection: [UUID: UUID]
        public var isSidebarVisible: Bool
    }

    private static let snapshotKey = "ArrowWindowSnapshot"

    public static func restoredSnapshot() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    public func saveSnapshot() {
        let snapshot = Snapshot(selectedSpaceID: selectedSpaceID, lastSelection: lastSelection, isSidebarVisible: isSidebarVisible)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.snapshotKey)
        }
    }

    public func noteSelection(_ tabID: UUID, in spaceID: UUID) {
        lastSelection[spaceID] = tabID
        recentTabIDs.removeAll { $0 == tabID }
        recentTabIDs.insert(tabID, at: 0)
        if recentTabIDs.count > 50 { recentTabIDs.removeLast() }
    }
}
