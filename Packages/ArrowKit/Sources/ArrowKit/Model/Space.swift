import Foundation

/// Browsing profile: cookies, logins and storage are isolated per profile.
public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isDefault: Bool

    public init(id: UUID = UUID(), name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// Icon of a space in the space switcher.
public enum SpaceIcon: Codable, Hashable, Sendable {
    case emoji(String)
    /// SF Symbol name.
    case symbol(String)
}

/// A distinct browsing area with its own pinned and today tabs and theme.
public struct Space: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var icon: SpaceIcon?
    public var theme: SpaceTheme
    public var profileID: UUID
    public var pinned: [SidebarNode]
    /// Unpinned tabs ("Today"), newest first.
    public var today: [SidebarNode]

    public init(id: UUID = UUID(), title: String, icon: SpaceIcon? = nil, theme: SpaceTheme = .lavender,
                profileID: UUID, pinned: [SidebarNode] = [], today: [SidebarNode] = []) {
        self.id = id
        self.title = title
        self.icon = icon
        self.theme = theme
        self.profileID = profileID
        self.pinned = pinned
        self.today = today
    }

    public var allTabs: [Tab] { pinned.allTabs + today.allTabs }

    public func section(of nodeID: UUID) -> SidebarSection? {
        if pinned.containsNode(nodeID) { return .pinned }
        if today.containsNode(nodeID) { return .today }
        return nil
    }
}

/// Why a tab went to the archive.
public enum ArchiveReason: String, Codable, Sendable {
    case closed
    case autoArchived
    case cleared
}

/// A closed tab kept for "Reopen Closed Tab" and the Archive library.
public struct ArchivedTab: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID { tab.id }
    public var tab: Tab
    public var spaceID: UUID?
    public var archivedAt: Date
    public var reason: ArchiveReason

    public init(tab: Tab, spaceID: UUID?, archivedAt: Date = Date(), reason: ArchiveReason) {
        self.tab = tab
        self.spaceID = spaceID
        self.archivedAt = archivedAt
        self.reason = reason
    }
}

/// Delay after which unused today tabs are archived.
public enum ArchiveInterval: String, Codable, CaseIterable, Sendable, Identifiable {
    case twelveHours
    case day
    case week
    case month

    public var id: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .twelveHours: 12 * 3600
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        case .month: 30 * 24 * 3600
        }
    }

    public var title: String {
        switch self {
        case .twelveHours: "12 hours"
        case .day: "24 hours"
        case .week: "7 days"
        case .month: "30 days"
        }
    }
}
