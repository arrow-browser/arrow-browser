import Foundation

/// A web page entry of the sidebar (favorite, pinned or today tab).
public struct Tab: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Current address.
    public var url: String
    public var title: String
    /// Title set by the user (rename) or by "Tidy Tab Titles".
    public var customTitle: String?
    /// Address a pinned tab or favorite returns to ("Back to Pinned URL").
    public var pinnedURL: String?
    public var faviconURL: String?
    public var isMuted: Bool
    public var createdAt: Date
    public var lastActiveAt: Date

    public init(id: UUID = UUID(), url: String, title: String = "", customTitle: String? = nil,
                pinnedURL: String? = nil, faviconURL: String? = nil, isMuted: Bool = false,
                createdAt: Date = Date(), lastActiveAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.customTitle = customTitle
        self.pinnedURL = pinnedURL
        self.faviconURL = faviconURL
        self.isMuted = isMuted
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }

    /// Title shown in the sidebar.
    public var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if !title.isEmpty { return title }
        return URLDisplay.host(of: url) ?? url
    }

    /// True when a pinned tab navigated away from its pinned address.
    public var hasNavigatedAwayFromPinnedURL: Bool {
        guard let pinnedURL else { return false }
        return URLDisplay.normalized(pinnedURL) != URLDisplay.normalized(url)
    }
}

/// A sidebar folder of pinned items.
public struct Folder: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var isExpanded: Bool
    public var children: [SidebarNode]

    public init(id: UUID = UUID(), title: String = "New Folder", isExpanded: Bool = true, children: [SidebarNode] = []) {
        self.id = id
        self.title = title
        self.isExpanded = isExpanded
        self.children = children
    }
}

public enum SplitAxis: String, Codable, Sendable {
    /// Side by side.
    case horizontal
    /// Stacked.
    case vertical
}

/// Two to four tabs shown together (Split View).
public struct SplitView: Codable, Identifiable, Hashable, Sendable {
    public static let maximumTabs = 4

    public var id: UUID
    public var tabs: [Tab]
    public var axis: SplitAxis
    /// Relative size of each pane (sums to 1).
    public var fractions: [Double]

    public init(id: UUID = UUID(), tabs: [Tab], axis: SplitAxis = .horizontal, fractions: [Double]? = nil) {
        self.id = id
        self.tabs = Array(tabs.prefix(Self.maximumTabs))
        self.axis = axis
        self.fractions = fractions ?? Array(repeating: 1.0 / Double(max(self.tabs.count, 1)), count: self.tabs.count)
    }

    public var title: String {
        tabs.map(\.displayTitle).joined(separator: " | ")
    }

    mutating func normalizeFractions() {
        guard !tabs.isEmpty else {
            fractions = []
            return
        }
        if fractions.count != tabs.count || fractions.contains(where: { $0 <= 0 }) {
            fractions = Array(repeating: 1.0 / Double(tabs.count), count: tabs.count)
            return
        }
        let total = fractions.reduce(0, +)
        fractions = fractions.map { $0 / total }
    }
}

/// An entry of a sidebar list.
public enum SidebarNode: Codable, Identifiable, Hashable, Sendable {
    case tab(Tab)
    case folder(Folder)
    case split(SplitView)

    public var id: UUID {
        switch self {
        case let .tab(tab): tab.id
        case let .folder(folder): folder.id
        case let .split(split): split.id
        }
    }

    /// Every tab contained in this node (recursively).
    public var tabs: [Tab] {
        switch self {
        case let .tab(tab): [tab]
        case let .folder(folder): folder.children.flatMap(\.tabs)
        case let .split(split): split.tabs
        }
    }

    public var asTab: Tab? {
        if case let .tab(tab) = self { return tab }
        return nil
    }
}

/// Section of a space's sidebar.
public enum SidebarSection: String, Codable, Sendable {
    case favorites
    case pinned
    case today
}

// MARK: - Tree helpers

extension Array where Element == SidebarNode {
    /// Every tab in the list (recursively).
    public var allTabs: [Tab] { flatMap(\.tabs) }

    public func containsNode(_ id: UUID) -> Bool {
        contains { node in
            if node.id == id { return true }
            switch node {
            case let .folder(folder): return folder.children.containsNode(id)
            case let .split(split): return split.tabs.contains { $0.id == id }
            case .tab: return false
            }
        }
    }

    public func findTab(_ id: UUID) -> Tab? {
        for node in self {
            switch node {
            case let .tab(tab) where tab.id == id: return tab
            case let .folder(folder):
                if let tab = folder.children.findTab(id) { return tab }
            case let .split(split):
                if let tab = split.tabs.first(where: { $0.id == id }) { return tab }
            default: continue
            }
        }
        return nil
    }

    public func findFolder(_ id: UUID) -> Folder? {
        for node in self {
            if case let .folder(folder) = node {
                if folder.id == id { return folder }
                if let found = folder.children.findFolder(id) { return found }
            }
        }
        return nil
    }

    public func findSplit(containing tabID: UUID) -> SplitView? {
        for node in self {
            switch node {
            case let .split(split) where split.tabs.contains(where: { $0.id == tabID }): return split
            case let .folder(folder):
                if let split = folder.children.findSplit(containing: tabID) { return split }
            default: continue
            }
        }
        return nil
    }

    /// Applies `transform` to the tab `id`. Returns true when found.
    @discardableResult
    public mutating func updateTab(_ id: UUID, _ transform: (inout Tab) -> Void) -> Bool {
        for index in indices {
            switch self[index] {
            case var .tab(tab) where tab.id == id:
                transform(&tab)
                self[index] = .tab(tab)
                return true
            case var .folder(folder):
                if folder.children.updateTab(id, transform) {
                    self[index] = .folder(folder)
                    return true
                }
            case var .split(split):
                if let tabIndex = split.tabs.firstIndex(where: { $0.id == id }) {
                    transform(&split.tabs[tabIndex])
                    self[index] = .split(split)
                    return true
                }
            default: continue
            }
        }
        return false
    }

    /// Collapse All Folders / Expand All Folders.
    public mutating func setFoldersExpanded(_ expanded: Bool) {
        for index in indices {
            guard case var .folder(folder) = self[index] else { continue }
            folder.isExpanded = expanded
            folder.children.setFoldersExpanded(expanded)
            self[index] = .folder(folder)
        }
    }

    /// Expands the folders that contain tab `id`. True when the tab is in the list.
    @discardableResult
    public mutating func expandFolders(containing id: UUID) -> Bool {
        var found = false
        for index in indices {
            if case var .folder(folder) = self[index] {
                if folder.children.expandFolders(containing: id) {
                    folder.isExpanded = true
                    self[index] = .folder(folder)
                    found = true
                }
            } else if self[index].tabs.contains(where: { $0.id == id }) {
                found = true
            }
        }
        return found
    }

    @discardableResult
    public mutating func updateFolder(_ id: UUID, _ transform: (inout Folder) -> Void) -> Bool {
        for index in indices {
            guard case var .folder(folder) = self[index] else { continue }
            if folder.id == id {
                transform(&folder)
                self[index] = .folder(folder)
                return true
            }
            if folder.children.updateFolder(id, transform) {
                self[index] = .folder(folder)
                return true
            }
        }
        return false
    }

    @discardableResult
    public mutating func updateSplit(_ id: UUID, _ transform: (inout SplitView) -> Void) -> Bool {
        for index in indices {
            switch self[index] {
            case var .split(split) where split.id == id:
                transform(&split)
                split.normalizeFractions()
                if split.tabs.count >= 2 {
                    self[index] = .split(split)
                } else if let remaining = split.tabs.first {
                    self[index] = .tab(remaining)
                } else {
                    remove(at: index)
                }
                return true
            case var .folder(folder):
                if folder.children.updateSplit(id, transform) {
                    self[index] = .folder(folder)
                    return true
                }
            default: continue
            }
        }
        return false
    }

    /// Removes the node `id` (a tab inside a split is extracted from it and
    /// the split dissolves when a single tab remains).
    public mutating func removeNode(_ id: UUID) -> SidebarNode? {
        for index in indices {
            let node = self[index]
            if node.id == id {
                remove(at: index)
                return node
            }
            switch node {
            case var .folder(folder):
                if let removed = folder.children.removeNode(id) {
                    self[index] = .folder(folder)
                    return removed
                }
            case var .split(split):
                if let tabIndex = split.tabs.firstIndex(where: { $0.id == id }) {
                    let tab = split.tabs.remove(at: tabIndex)
                    split.normalizeFractions()
                    if split.tabs.count >= 2 {
                        self[index] = .split(split)
                    } else if let remaining = split.tabs.first {
                        self[index] = .tab(remaining)
                    } else {
                        remove(at: index)
                    }
                    return .tab(tab)
                }
            case .tab:
                continue
            }
        }
        return nil
    }

    /// Inserts `node` into folder `folderID` (or at the root when nil).
    /// Returns false when the folder does not exist.
    @discardableResult
    public mutating func insertNode(_ node: SidebarNode, inFolder folderID: UUID?, at index: Int?) -> Bool {
        guard let folderID else {
            let position = index.map { Swift.min(Swift.max($0, 0), count) } ?? count
            insert(node, at: position)
            return true
        }
        return updateFolder(folderID) { folder in
            let position = index.map { Swift.min(Swift.max($0, 0), folder.children.count) } ?? folder.children.count
            folder.children.insert(node, at: position)
        }
    }
}
