import Foundation

/// Position of a node in the sidebar.
public struct SidebarLocation: Hashable, Sendable {
    public var spaceID: UUID?
    public var section: SidebarSection
    public var folderID: UUID?
    public var index: Int?

    public init(spaceID: UUID?, section: SidebarSection, folderID: UUID? = nil, index: Int? = nil) {
        self.spaceID = spaceID
        self.section = section
        self.folderID = folderID
        self.index = index
    }

    public static func favorites(index: Int? = nil) -> SidebarLocation {
        SidebarLocation(spaceID: nil, section: .favorites, index: index)
    }
}

/// Everything shown in the sidebar of every window: profiles, spaces,
/// favorites and the archive. Persisted as JSON and synced.
public struct BrowserState: Codable, Sendable {
    public static let currentVersion = 1
    public static let archiveLimit = 2000

    public var version: Int
    public var profiles: [Profile]
    public var spaces: [Space]
    /// Favorites ("top apps") per profile ID.
    public var favorites: [String: [Tab]]
    /// Most recent first.
    public var archive: [ArchivedTab]

    public init(profiles: [Profile], spaces: [Space], favorites: [String: [Tab]] = [:], archive: [ArchivedTab] = []) {
        version = Self.currentVersion
        self.profiles = profiles
        self.spaces = spaces
        self.favorites = favorites
        self.archive = archive
    }

    /// First launch state: one default profile and space.
    public static func initial() -> BrowserState {
        let profile = Profile(name: "Default", isDefault: true)
        let space = Space(title: "Personal", icon: .symbol("person.fill"), theme: .lavender, profileID: profile.id)
        return BrowserState(profiles: [profile], spaces: [space])
    }

    public var defaultProfile: Profile {
        profiles.first(where: \.isDefault) ?? profiles[0]
    }

    // MARK: Lookup

    public func space(_ id: UUID) -> Space? {
        spaces.first { $0.id == id }
    }

    public func spaceIndex(_ id: UUID) -> Int? {
        spaces.firstIndex { $0.id == id }
    }

    public func favorites(for profileID: UUID) -> [Tab] {
        favorites[profileID.uuidString] ?? []
    }

    public func profile(_ id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }

    /// Tab `id` wherever it is (favorites, pinned, today).
    public func tab(_ id: UUID) -> Tab? {
        for list in favorites.values {
            if let tab = list.first(where: { $0.id == id }) { return tab }
        }
        for space in spaces {
            if let tab = space.pinned.findTab(id) ?? space.today.findTab(id) { return tab }
        }
        return nil
    }

    /// Section and space holding the node `id`.
    public func location(of id: UUID) -> SidebarLocation? {
        for (profileID, list) in favorites {
            if let index = list.firstIndex(where: { $0.id == id }) {
                _ = profileID
                return .favorites(index: index)
            }
        }
        for space in spaces {
            if let section = space.section(of: id) {
                return SidebarLocation(spaceID: space.id, section: section)
            }
        }
        return nil
    }

    /// Space containing the node `id` (nil for favorites).
    public func spaceID(containing id: UUID) -> UUID? {
        spaces.first { $0.section(of: id) != nil }?.id
    }

    public func isFavorite(_ id: UUID) -> Bool {
        favorites.values.contains { $0.contains { $0.id == id } }
    }

    public func isPinned(_ id: UUID) -> Bool {
        spaces.contains { $0.pinned.containsNode(id) }
    }

    // MARK: Tabs

    /// Applies `transform` to tab `id` wherever it is.
    @discardableResult
    public mutating func updateTab(_ id: UUID, _ transform: (inout Tab) -> Void) -> Bool {
        for key in favorites.keys {
            if let index = favorites[key]?.firstIndex(where: { $0.id == id }) {
                transform(&favorites[key]![index])
                return true
            }
        }
        for index in spaces.indices {
            if spaces[index].pinned.updateTab(id, transform) || spaces[index].today.updateTab(id, transform) {
                return true
            }
        }
        return false
    }

    /// Opens a new today tab at the top of `spaceID`.
    @discardableResult
    public mutating func openTab(url: String, title: String = "", in spaceID: UUID, now: Date = Date()) -> Tab? {
        guard let index = spaceIndex(spaceID) else { return nil }
        let tab = Tab(url: url, title: title, createdAt: now, lastActiveAt: now)
        spaces[index].today.insert(.tab(tab), at: 0)
        return tab
    }

    /// Removes the node `id` from wherever it is.
    @discardableResult
    public mutating func removeNode(_ id: UUID) -> SidebarNode? {
        for key in favorites.keys {
            if let index = favorites[key]?.firstIndex(where: { $0.id == id }) {
                return .tab(favorites[key]!.remove(at: index))
            }
        }
        for index in spaces.indices {
            if let node = spaces[index].pinned.removeNode(id) ?? spaces[index].today.removeNode(id) {
                return node
            }
        }
        return nil
    }

    /// Moves the node `id` to `destination`. Moving into favorites only
    /// accepts tabs; pinned/favorite tabs remember their address.
    @discardableResult
    public mutating func move(_ id: UUID, to destination: SidebarLocation) -> Bool {
        let source = location(of: id)
        guard let node = removeNode(id) else { return false }
        var moved = node
        if destination.section == .favorites || destination.section == .pinned {
            moved = Self.pinning(node)
        } else if destination.section == .today {
            moved = Self.unpinning(node)
        }

        switch destination.section {
        case .favorites:
            guard case let .tab(tab) = moved else {
                restore(node, at: source)
                return false
            }
            let profileID = destination.spaceID.flatMap { space($0)?.profileID } ?? source?.spaceID.flatMap { space($0)?.profileID }
                ?? defaultProfile.id
            var list = favorites(for: profileID)
            let position = destination.index.map { min(max($0, 0), list.count) } ?? list.count
            list.insert(tab, at: position)
            favorites[profileID.uuidString] = list
            return true
        case .pinned, .today:
            guard let spaceID = destination.spaceID, let index = spaceIndex(spaceID) else {
                restore(node, at: source)
                return false
            }
            let inserted = destination.section == .pinned
                ? spaces[index].pinned.insertNode(moved, inFolder: destination.folderID, at: destination.index)
                : spaces[index].today.insertNode(moved, inFolder: nil, at: destination.index ?? 0)
            if !inserted { restore(node, at: source) }
            return inserted
        }
    }

    private mutating func restore(_ node: SidebarNode, at location: SidebarLocation?) {
        guard let location else { return }
        switch location.section {
        case .favorites:
            if case let .tab(tab) = node {
                favorites[defaultProfile.id.uuidString, default: []].append(tab)
            }
        case .pinned:
            if let spaceID = location.spaceID, let index = spaceIndex(spaceID) { spaces[index].pinned.append(node) }
        case .today:
            if let spaceID = location.spaceID, let index = spaceIndex(spaceID) { spaces[index].today.insert(node, at: 0) }
        }
    }

    private static func pinning(_ node: SidebarNode) -> SidebarNode {
        switch node {
        case var .tab(tab):
            if tab.pinnedURL == nil { tab.pinnedURL = tab.url }
            return .tab(tab)
        case var .folder(folder):
            folder.children = folder.children.map(pinning)
            return .folder(folder)
        case var .split(split):
            split.tabs = split.tabs.map { tab in
                var tab = tab
                if tab.pinnedURL == nil { tab.pinnedURL = tab.url }
                return tab
            }
            return .split(split)
        }
    }

    private static func unpinning(_ node: SidebarNode) -> SidebarNode {
        switch node {
        case var .tab(tab):
            tab.pinnedURL = nil
            return .tab(tab)
        case let .folder(folder):
            // Folders only live in the pinned section: unpinning keeps their tabs.
            return .folder(folder)
        case var .split(split):
            split.tabs = split.tabs.map { tab in
                var tab = tab
                tab.pinnedURL = nil
                return tab
            }
            return .split(split)
        }
    }

    /// Pins a today tab (appended to the pinned list) or unpins a pinned one
    /// (moved to the top of today).
    public mutating func togglePin(_ id: UUID) {
        guard let location = location(of: id), let spaceID = location.spaceID else { return }
        switch location.section {
        case .today: move(id, to: SidebarLocation(spaceID: spaceID, section: .pinned))
        case .pinned: move(id, to: SidebarLocation(spaceID: spaceID, section: .today, index: 0))
        case .favorites: break
        }
    }

    // MARK: Archive

    /// Closes a today tab (or split/folder) and archives its tabs. Pinned
    /// tabs and favorites are never removed by closing.
    @discardableResult
    public mutating func close(_ id: UUID, reason: ArchiveReason = .closed, now: Date = Date()) -> [Tab] {
        guard let location = location(of: id), location.section == .today, let node = removeNode(id) else { return [] }
        let tabs = node.tabs
        archive(tabs, from: location.spaceID, reason: reason, now: now)
        return tabs
    }

    /// Deletes a pinned node or favorite, archiving its tabs.
    @discardableResult
    public mutating func delete(_ id: UUID, now: Date = Date()) -> [Tab] {
        let spaceID = spaceID(containing: id)
        guard let node = removeNode(id) else { return [] }
        let tabs = node.tabs
        archive(tabs, from: spaceID, reason: .closed, now: now)
        return tabs
    }

    public mutating func archive(_ tabs: [Tab], from spaceID: UUID?, reason: ArchiveReason, now: Date = Date()) {
        let entries = tabs
            .filter { !$0.url.isEmpty && $0.url != "about:blank" }
            .map { tab in
                var tab = tab
                tab.pinnedURL = nil
                return ArchivedTab(tab: tab, spaceID: spaceID, archivedAt: now, reason: reason)
            }
        archive.insert(contentsOf: entries.reversed(), at: 0)
        if archive.count > Self.archiveLimit {
            archive.removeLast(archive.count - Self.archiveLimit)
        }
    }

    /// Max ▸ Tidy Tabs: puts today's items in `order`; items not listed keep
    /// their relative order after them.
    public mutating func reorderToday(in spaceID: UUID, order: [UUID]) {
        guard let index = spaceIndex(spaceID) else { return }
        let today = spaces[index].today
        let ranked = order.compactMap { id in today.first { $0.id == id } }
        let rankedIDs = Set(ranked.map(\.id))
        spaces[index].today = ranked + today.filter { !rankedIDs.contains($0.id) }
    }

    /// "Clear" button of the today section.
    @discardableResult
    public mutating func clearToday(in spaceID: UUID, keeping keptIDs: Set<UUID> = [], now: Date = Date()) -> [Tab] {
        guard let index = spaceIndex(spaceID) else { return [] }
        let removed = spaces[index].today.filter { !keptIDs.contains($0.id) }
        spaces[index].today.removeAll { !keptIDs.contains($0.id) }
        let tabs = removed.allTabs
        archive(tabs, from: spaceID, reason: .cleared, now: now)
        return tabs
    }

    /// Archives today tabs not used for `interval` (auto-archive).
    @discardableResult
    public mutating func archiveStaleTabs(olderThan interval: TimeInterval, now: Date = Date(),
                                          excluding activeIDs: Set<UUID> = []) -> [Tab] {
        var archived: [Tab] = []
        for index in spaces.indices {
            let spaceID = spaces[index].id
            let stale = spaces[index].today.filter { node in
                !node.tabs.contains { activeIDs.contains($0.id) }
                    && node.tabs.allSatisfy { now.timeIntervalSince($0.lastActiveAt) > interval }
            }
            guard !stale.isEmpty else { continue }
            let staleIDs = Set(stale.map(\.id))
            spaces[index].today.removeAll { staleIDs.contains($0.id) }
            let tabs = stale.allTabs
            archive(tabs, from: spaceID, reason: .autoArchived, now: now)
            archived += tabs
        }
        return archived
    }

    /// Restores the most recently archived tab (Cmd+Shift+T).
    public mutating func reopenLastArchived(now: Date = Date()) -> (tab: Tab, spaceID: UUID)? {
        guard !archive.isEmpty else { return nil }
        return restoreArchived(archive[0].id, now: now)
    }

    /// Moves an archived tab back to the top of its space's today list.
    @discardableResult
    public mutating func restoreArchived(_ id: UUID, into preferredSpaceID: UUID? = nil, now: Date = Date()) -> (tab: Tab, spaceID: UUID)? {
        guard let index = archive.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = archive.remove(at: index)
        let targetID = preferredSpaceID.flatMap { space($0)?.id } ?? entry.spaceID.flatMap { space($0)?.id } ?? spaces.first?.id
        guard let targetID, let spaceIndex = spaceIndex(targetID) else { return nil }
        var tab = entry.tab
        tab.lastActiveAt = now
        spaces[spaceIndex].today.insert(.tab(tab), at: 0)
        return (tab, targetID)
    }

    // MARK: Folders

    @discardableResult
    public mutating func createFolder(in spaceID: UUID, title: String = "New Folder", containing ids: [UUID] = []) -> Folder? {
        guard let index = spaceIndex(spaceID) else { return nil }
        var folder = Folder(title: title)
        for id in ids {
            if let node = removeNode(id) { folder.children.append(Self.pinning(node)) }
        }
        spaces[index].pinned.append(.folder(folder))
        folder = spaces[index].pinned.findFolder(folder.id) ?? folder
        return folder
    }

    public mutating func renameFolder(_ id: UUID, to title: String) {
        for index in spaces.indices where spaces[index].pinned.updateFolder(id, { $0.title = title }) { return }
    }

    public mutating func setFoldersExpanded(_ expanded: Bool, in spaceID: UUID) {
        guard let index = spaceIndex(spaceID) else { return }
        spaces[index].pinned.setFoldersExpanded(expanded)
    }

    /// Reveal Tab in Sidebar: opens the folders around tab `id`.
    public mutating func expandFolders(containing id: UUID) {
        for index in spaces.indices where spaces[index].pinned.expandFolders(containing: id) { return }
    }

    public mutating func toggleFolder(_ id: UUID) {
        for index in spaces.indices where spaces[index].pinned.updateFolder(id, { $0.isExpanded.toggle() }) { return }
    }

    // MARK: Split View

    /// Groups tabs into a split view placed where the first tab was.
    @discardableResult
    public mutating func createSplit(tabIDs: [UUID], axis: SplitAxis = .horizontal) -> SplitView? {
        let ids = Array(tabIDs.prefix(SplitView.maximumTabs))
        guard ids.count >= 2, let first = ids.first, let location = location(of: first),
              let spaceID = location.spaceID, let spaceIndex = spaceIndex(spaceID) else { return nil }
        let section = location.section == .pinned ? SidebarSection.pinned : .today
        let list = section == .pinned ? spaces[spaceIndex].pinned : spaces[spaceIndex].today
        let position = list.firstIndex { $0.id == first } ?? 0
        var tabs: [Tab] = []
        for id in ids {
            if let node = removeNode(id) { tabs += node.tabs }
        }
        let split = SplitView(tabs: tabs, axis: axis)
        if section == .pinned {
            spaces[spaceIndex].pinned.insert(.split(split), at: min(position, spaces[spaceIndex].pinned.count))
        } else {
            spaces[spaceIndex].today.insert(.split(split), at: min(position, spaces[spaceIndex].today.count))
        }
        return split
    }

    /// Adds `tab` to the split containing `existingTabID` (or creates one).
    @discardableResult
    public mutating func addToSplit(_ tabID: UUID, with existingTabID: UUID) -> SplitView? {
        for space in spaces {
            if let split = space.pinned.findSplit(containing: existingTabID) ?? space.today.findSplit(containing: existingTabID) {
                guard split.tabs.count < SplitView.maximumTabs, let node = removeNode(tabID) else { return nil }
                var result: SplitView?
                for index in spaces.indices {
                    let transform: (inout SplitView) -> Void = { split in
                        split.tabs += node.tabs
                        split.fractions = []
                        result = split
                    }
                    if spaces[index].pinned.updateSplit(split.id, transform) || spaces[index].today.updateSplit(split.id, transform) {
                        return result
                    }
                }
                return nil
            }
        }
        return createSplit(tabIDs: [existingTabID, tabID])
    }

    /// Splits a split view back into separate tabs.
    public mutating func dissolveSplit(_ id: UUID) {
        for index in spaces.indices {
            for keyPath in [\Space.pinned, \Space.today] {
                if let position = spaces[index][keyPath: keyPath].firstIndex(where: { $0.id == id }),
                   case let .split(split) = spaces[index][keyPath: keyPath][position] {
                    spaces[index][keyPath: keyPath].replaceSubrange(position...position, with: split.tabs.map(SidebarNode.tab))
                    return
                }
            }
        }
    }

    public mutating func updateSplit(_ id: UUID, _ transform: (inout SplitView) -> Void) {
        for index in spaces.indices {
            if spaces[index].pinned.updateSplit(id, transform) || spaces[index].today.updateSplit(id, transform) { return }
        }
    }

    // MARK: Spaces

    @discardableResult
    public mutating func createSpace(title: String, icon: SpaceIcon? = nil, theme: SpaceTheme, profileID: UUID? = nil) -> Space {
        let space = Space(title: title, icon: icon, theme: theme, profileID: profileID ?? defaultProfile.id)
        spaces.append(space)
        return space
    }

    /// Deletes a space and archives its tabs. The last space cannot be deleted.
    public mutating func deleteSpace(_ id: UUID, now: Date = Date()) {
        guard spaces.count > 1, let index = spaceIndex(id) else { return }
        let space = spaces.remove(at: index)
        archive(space.allTabs, from: nil, reason: .closed, now: now)
    }

    public mutating func updateSpace(_ id: UUID, _ transform: (inout Space) -> Void) {
        guard let index = spaceIndex(id) else { return }
        transform(&spaces[index])
    }

    public mutating func moveSpace(from source: Int, to destination: Int) {
        guard spaces.indices.contains(source) else { return }
        let space = spaces.remove(at: source)
        spaces.insert(space, at: min(max(destination, 0), spaces.count))
    }

    // MARK: Profiles

    @discardableResult
    public mutating func createProfile(name: String) -> Profile {
        let profile = Profile(name: name)
        profiles.append(profile)
        return profile
    }

    public mutating func renameProfile(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
    }

    /// Deletes a non-default profile; its spaces move to the default profile.
    public mutating func deleteProfile(_ id: UUID) {
        guard let profile = profile(id), !profile.isDefault else { return }
        profiles.removeAll { $0.id == id }
        let fallback = defaultProfile.id
        for index in spaces.indices where spaces[index].profileID == id {
            spaces[index].profileID = fallback
        }
        if let removed = favorites.removeValue(forKey: id.uuidString) {
            favorites[fallback.uuidString, default: []] += removed
        }
    }
}
