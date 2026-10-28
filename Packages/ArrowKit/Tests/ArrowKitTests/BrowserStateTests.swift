import Foundation
import Testing
@testable import ArrowKit

/// Unwraps outside of `#require`, which cannot capture mutating calls.
private func unwrap<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, sourceLocation: sourceLocation)
}

struct BrowserStateTests {
    private func makeState() -> (BrowserState, UUID) {
        let state = BrowserState.initial()
        return (state, state.spaces[0].id)
    }

    @Test func opensTabsAtTopOfToday() throws {
        var (state, spaceID) = makeState()
        let first = try unwrap(state.openTab(url: "https://a.com", in: spaceID))
        let second = try unwrap(state.openTab(url: "https://b.com", in: spaceID))
        #expect(state.spaces[0].today.map(\.id) == [second.id, first.id])
        #expect(state.location(of: first.id)?.section == .today)
    }

    @Test func pinningRemembersAddressAndUnpinningForgetsIt() throws {
        var (state, spaceID) = makeState()
        let tab = try unwrap(state.openTab(url: "https://a.com", in: spaceID))
        state.togglePin(tab.id)
        #expect(state.isPinned(tab.id))
        #expect(state.tab(tab.id)?.pinnedURL == "https://a.com")

        state.updateTab(tab.id) { $0.url = "https://a.com/other" }
        #expect(state.tab(tab.id)?.hasNavigatedAwayFromPinnedURL == true)

        state.togglePin(tab.id)
        #expect(!state.isPinned(tab.id))
        #expect(state.tab(tab.id)?.pinnedURL == nil)
        #expect(state.spaces[0].today.first?.id == tab.id)
    }

    @Test func movesTabsToFavoritesAndFolders() throws {
        var (state, spaceID) = makeState()
        let tab = try unwrap(state.openTab(url: "https://mail.example.com", in: spaceID))
        let movedToFavorites = state.move(tab.id, to: .favorites())
        #expect(movedToFavorites)
        #expect(state.isFavorite(tab.id))
        #expect(state.favorites(for: state.defaultProfile.id).first?.pinnedURL == "https://mail.example.com")

        let other = try unwrap(state.openTab(url: "https://b.com", in: spaceID))
        let folder = try unwrap(state.createFolder(in: spaceID, title: "Work"))
        let movedToFolder = state.move(other.id, to: SidebarLocation(spaceID: spaceID, section: .pinned, folderID: folder.id))
        #expect(movedToFolder)
        #expect(state.spaces[0].pinned.findFolder(folder.id)?.children.first?.id == other.id)
    }

    @Test func tidyingReordersTodayKeepingUnlistedTabs() throws {
        var (state, spaceID) = makeState()
        let a = try unwrap(state.openTab(url: "https://a.com", in: spaceID))
        let b = try unwrap(state.openTab(url: "https://b.com", in: spaceID))
        let c = try unwrap(state.openTab(url: "https://c.com", in: spaceID))
        // Newest first: c, b, a.
        state.reorderToday(in: spaceID, order: [a.id, c.id, UUID()])
        #expect(state.spaces[0].today.map(\.id) == [a.id, c.id, b.id])
    }

    @Test func revealingATabExpandsTheFoldersAroundIt() throws {
        var (state, spaceID) = makeState()
        let tab = try unwrap(state.openTab(url: "https://b.com", in: spaceID))
        let outer = try unwrap(state.createFolder(in: spaceID, title: "Outer"))
        let inner = try unwrap(state.createFolder(in: spaceID, title: "Inner"))
        _ = state.move(inner.id, to: SidebarLocation(spaceID: spaceID, section: .pinned, folderID: outer.id))
        _ = state.move(tab.id, to: SidebarLocation(spaceID: spaceID, section: .pinned, folderID: inner.id))
        state.toggleFolder(outer.id)
        state.toggleFolder(inner.id)
        #expect(state.spaces[0].pinned.findFolder(outer.id)?.isExpanded == false)

        state.expandFolders(containing: tab.id)
        #expect(state.spaces[0].pinned.findFolder(outer.id)?.isExpanded == true)
        #expect(state.spaces[0].pinned.findFolder(inner.id)?.isExpanded == true)

        state.setFoldersExpanded(false, in: spaceID)
        #expect(state.spaces[0].pinned.findFolder(outer.id)?.isExpanded == false)
        #expect(state.spaces[0].pinned.findFolder(inner.id)?.isExpanded == false)
    }

    @Test func movingFolderToFavoritesIsRejected() throws {
        var (state, spaceID) = makeState()
        let folder = try unwrap(state.createFolder(in: spaceID))
        let movedFolder = state.move(folder.id, to: .favorites())
        #expect(!movedFolder)
        #expect(state.spaces[0].pinned.findFolder(folder.id) != nil)
    }

    @Test func closingArchivesTodayTabsButNeverPinnedOnes() throws {
        var (state, spaceID) = makeState()
        let today = try unwrap(state.openTab(url: "https://a.com", in: spaceID))
        let pinned = try unwrap(state.openTab(url: "https://b.com", in: spaceID))
        state.togglePin(pinned.id)

        let closedToday = state.close(today.id)
        #expect(closedToday.map(\.id) == [today.id])
        #expect(state.archive.first?.tab.id == today.id)
        let closedPinned = state.close(pinned.id)
        #expect(closedPinned.isEmpty)
        #expect(state.isPinned(pinned.id))
    }

    @Test func reopensLastArchivedTab() throws {
        var (state, spaceID) = makeState()
        let tab = try unwrap(state.openTab(url: "https://a.com", in: spaceID))
        state.close(tab.id)
        let restored = try unwrap(state.reopenLastArchived())
        #expect(restored.tab.id == tab.id)
        #expect(restored.spaceID == spaceID)
        #expect(state.archive.isEmpty)
    }

    @Test func autoArchivesStaleTabsOnly() throws {
        var (state, spaceID) = makeState()
        let now = Date()
        let stale = try unwrap(state.openTab(url: "https://old.com", in: spaceID, now: now.addingTimeInterval(-13 * 3600)))
        let fresh = try unwrap(state.openTab(url: "https://new.com", in: spaceID, now: now))
        let active = try unwrap(state.openTab(url: "https://active.com", in: spaceID, now: now.addingTimeInterval(-20 * 3600)))

        let archived = state.archiveStaleTabs(olderThan: ArchiveInterval.twelveHours.seconds, now: now, excluding: [active.id])
        #expect(archived.map(\.id) == [stale.id])
        #expect(state.tab(fresh.id) != nil)
        #expect(state.tab(active.id) != nil)
        #expect(state.archive.first?.reason == .autoArchived)
    }

    @Test func clearTodayKeepsRequestedTabs() throws {
        var (state, spaceID) = makeState()
        let kept = try unwrap(state.openTab(url: "https://keep.com", in: spaceID))
        _ = state.openTab(url: "https://drop.com", in: spaceID)
        state.clearToday(in: spaceID, keeping: [kept.id])
        #expect(state.spaces[0].today.map(\.id) == [kept.id])
    }

    @Test func createsAndDissolvesSplitViews() throws {
        var (state, spaceID) = makeState()
        let a = try unwrap(state.openTab(url: "https://a.com", in: spaceID))
        let b = try unwrap(state.openTab(url: "https://b.com", in: spaceID))
        let c = try unwrap(state.openTab(url: "https://c.com", in: spaceID))

        let split = try unwrap(state.createSplit(tabIDs: [a.id, b.id]))
        #expect(state.spaces[0].today.count == 2)
        #expect(split.fractions == [0.5, 0.5])

        let grown = try unwrap(state.addToSplit(c.id, with: a.id))
        #expect(grown.tabs.count == 3)

        // Removing tabs dissolves the split when one remains.
        state.removeNode(b.id)
        state.removeNode(c.id)
        #expect(state.spaces[0].today.first?.asTab?.id == a.id)
    }

    @Test func deletingSpaceArchivesItsTabsButKeepsLastSpace() throws {
        var (state, firstSpace) = makeState()
        state.deleteSpace(firstSpace)
        #expect(state.spaces.count == 1)

        let second = state.createSpace(title: "Work", theme: .lavender)
        let tab = try unwrap(state.openTab(url: "https://work.com", in: second.id))
        state.deleteSpace(second.id)
        #expect(state.spaces.map(\.id) == [firstSpace])
        #expect(state.archive.first?.tab.id == tab.id)
        _ = firstSpace
    }

    @Test func deletingProfileMovesSpacesToDefault() {
        var (state, spaceID) = makeState()
        let work = state.createProfile(name: "Work")
        state.updateSpace(spaceID) { $0.profileID = work.id }
        state.renameProfile(work.id, to: "  Work stuff ")
        #expect(state.profile(work.id)?.name == "Work stuff")
        state.renameProfile(work.id, to: "   ")
        #expect(state.profile(work.id)?.name == "Work stuff")
        state.deleteProfile(work.id)
        #expect(state.space(spaceID)?.profileID == state.defaultProfile.id)
        state.deleteProfile(state.defaultProfile.id)
        #expect(state.profiles.count == 1)
    }

    @Test func roundTripsThroughJSONStore() throws {
        var (state, spaceID) = makeState()
        _ = state.openTab(url: "https://a.com", in: spaceID)
        _ = state.createFolder(in: spaceID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONStore<BrowserState>(url: directory.appendingPathComponent("State.json"), backupCount: 2)
        try store.save(state)
        for _ in 0..<4 { try store.save(state, backup: true) }
        #expect(store.backups().count == 2)
        let loaded = try #require(store.load())
        #expect(loaded.spaces == state.spaces)
        let backup = try #require(store.backups().last)
        #expect(store.value(inBackup: backup)?.spaces == state.spaces)
    }
}
