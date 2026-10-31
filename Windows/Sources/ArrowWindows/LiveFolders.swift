import ArrowCore
import ArrowKit
import Foundation
import Observation

/// Arc's GitHub Live Folder (a space's menu, Live Folders ▸ GitHub): a
/// pinned folder kept filled with the open pull requests of the user signed
/// in to GitHub in the space's profile, theirs and those awaiting their
/// review. Like Arc, it reads them from github.com's pages, in a hidden page
/// of the profile. Which folders are live is a setting of this app, in its
/// defaults.
@MainActor
@Observable
final class LiveFolders {
    struct PullRequest: Equatable {
        var title: String
        var url: String

        /// "owner/repo".
        var repository: String {
            URL(string: url)?.pathComponents.dropFirst().prefix(2).joined(separator: "/") ?? ""
        }
    }

    /// Why a folder's last refresh left it as it was.
    enum Status {
        case signedOut, unreachable
    }

    private struct Stored: Codable {
        /// Repositories unchecked in the folder's menu.
        var hiddenRepositories: [String] = []
    }

    private enum Page {
        case pullRequests([PullRequest])
        case signedOut
    }

    static let shared = LiveFolders()
    static let title = "GitHub"
    // Arc's words.
    static let emptyText = "Pull requests from you and your team will show up here automatically"
    static let signInText = "Sign back in to GitHub."
    static let unreachableText = "We’re having trouble connecting to GitHub; click here to see your Pull Requests."
    static let repositoriesText = "This list is generated based on your currently active pull requests."
    static let pullsURL = "https://github.com/pulls"
    static let signInURL = "https://github.com/login?return_to=%2Fpulls"
    /// The user's open pull requests, then those awaiting their review.
    private static let pages = [pullsURL, "https://github.com/pulls/review-requested"]
    private static let key = "GitHubLiveFolders"
    private static let refreshInterval: TimeInterval = 10 * 60

    @ObservationIgnored private weak var store: BrowserStore?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshing: Set<Foundation.UUID> = []
    @ObservationIgnored private var folders: [Foundation.UUID: Stored] = LiveFolders.load()
    /// Each folder's pull requests, before hiding repositories.
    @ObservationIgnored private var pullRequests: [Foundation.UUID: [PullRequest]] = [:]
    private(set) var status: [Foundation.UUID: Status] = [:]

    func isLive(_ folderID: Foundation.UUID) -> Bool {
        folders[folderID] != nil
    }

    /// Refreshes the live folders now, then every few minutes.
    func start(store: BrowserStore) {
        self.store = store
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated { LiveFolders.shared.refreshAll() }
        }
    }

    /// The space's GitHub Live Folder, pinned and filled; shown again when
    /// the space has one.
    func addGitHub(in spaceID: Foundation.UUID) {
        guard let store, let space = store.state.space(spaceID) else { return }
        if let existing = Self.folderIDs(in: space.pinned).first(where: isLive) {
            store.update { browser in
                for index in browser.spaces.indices {
                    browser.spaces[index].pinned.updateFolder(existing) { $0.isExpanded = true }
                }
            }
            refresh(existing)
            return
        }
        var folder: ArrowKit.Folder?
        store.update { folder = $0.createFolder(in: spaceID, title: Self.title) }
        guard let folder else { return }
        folders[folder.id] = Stored()
        save()
        refresh(folder.id)
    }

    func delete(_ folderID: Foundation.UUID) {
        folders[folderID] = nil
        pullRequests[folderID] = nil
        status[folderID] = nil
        save()
        store?.update { _ = $0.delete(folderID) }
    }

    /// The repositories of the folder's pull requests, its menu's list.
    func repositories(of folderID: Foundation.UUID) -> [String] {
        var seen = Set<String>()
        return (pullRequests[folderID] ?? []).map(\.repository).filter { seen.insert($0).inserted }
    }

    func isShown(_ repository: String, in folderID: Foundation.UUID) -> Bool {
        folders[folderID]?.hiddenRepositories.contains(repository) == false
    }

    /// Shows or hides a repository's pull requests in the folder.
    func toggle(_ repository: String, in folderID: Foundation.UUID) {
        guard var stored = folders[folderID] else { return }
        if let index = stored.hiddenRepositories.firstIndex(of: repository) {
            stored.hiddenRepositories.remove(at: index)
        } else {
            stored.hiddenRepositories.append(repository)
        }
        folders[folderID] = stored
        save()
        if let found = pullRequests[folderID] { fill(folderID, with: found) }
    }

    func refreshAll() {
        guard let store else { return }
        // Folders deleted meanwhile stop being live.
        let existing = Set(store.state.spaces.flatMap { Self.folderIDs(in: $0.pinned) })
        let gone = folders.keys.filter { !existing.contains($0) }
        if !gone.isEmpty {
            for id in gone { folders[id] = nil }
            save()
        }
        for id in folders.keys {
            refresh(id)
        }
    }

    private func refresh(_ folderID: Foundation.UUID) {
        guard let store, !refreshing.contains(folderID),
              let space = store.state.spaces.first(where: { Self.folderIDs(in: $0.pinned).contains(folderID) })
        else { return }
        let context = store.requestContext(for: space.profileID)
        refreshing.insert(folderID)
        Task {
            defer { refreshing.remove(folderID) }
            var found: [PullRequest] = []
            for page in Self.pages {
                switch await Self.read(page, in: context) {
                case let .pullRequests(more):
                    found += more.filter { request in !found.contains { $0.url == request.url } }
                case .signedOut:
                    status[folderID] = .signedOut
                    return
                case nil:
                    status[folderID] = .unreachable
                    return
                }
            }
            status[folderID] = nil
            pullRequests[folderID] = found
            fill(folderID, with: found)
        }
    }

    /// Replaces the folder's tabs with the pull requests of the repositories
    /// it shows, keeping the tabs of the pages it already has.
    private func fill(_ folderID: Foundation.UUID, with found: [PullRequest]) {
        guard let store else { return }
        let shown = found.filter { isShown($0.repository, in: folderID) }
        store.update { browser in
            for index in browser.spaces.indices {
                browser.spaces[index].pinned = Self.replacing(browser.spaces[index].pinned, folder: folderID) { old in
                    let existing = Dictionary(old.allTabs.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
                    return shown.map { request in
                        .tab(existing[request.url] ?? Tab(url: request.url, title: request.title, pinnedURL: request.url))
                    }
                }
            }
        }
    }

    /// Reads the pull requests of a github.com page in a hidden page of
    /// `context`; nil when it could not.
    private static func read(_ url: String, in context: any BrowsingContext) async -> Page? {
        let page = context.makeBrowser()
        page.create(url: url)
        defer { page.close(force: true) }
        var last: [PullRequest]?
        var emptyReads = 0
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            guard let result = await page.evaluateJavaScript(scrapeScript) as? [String: Any] else { continue }
            if result["signedOut"] as? Bool == true { return .signedOut }
            let found = pullRequests(result)
            // github.com may draw its list once loaded: the list is complete
            // when read twice the same, or empty when it stays empty.
            if found.isEmpty {
                emptyReads += 1
                if emptyReads == 6 { return .pullRequests([]) }
                continue
            }
            if found == last { return .pullRequests(found) }
            last = found
        }
        return last.map { .pullRequests($0) }
    }

    /// The pull requests `scrapeScript` found.
    static func pullRequests(_ result: [String: Any]) -> [PullRequest] {
        (result["items"] as? [Any] ?? []).compactMap { item in
            guard let pair = item as? [Any], pair.count == 2, let url = pair[0] as? String,
                  let title = pair[1] as? String else { return nil }
            return PullRequest(title: title, url: url)
        }
    }

    /// The page's links to pull requests, each with its longest title; null
    /// until loaded, `signedOut` on GitHub's sign-in page.
    static let scrapeScript = """
    (() => {
      if (document.readyState !== 'complete') return null;
      if (/^\\/(login|session)/.test(location.pathname)) return { signedOut: true };
      const titles = new Map();
      for (const link of document.querySelectorAll('a[href*="/pull/"]')) {
        const url = link.href.split(/[?#]/)[0];
        const title = link.textContent.trim().replace(/\\s+/g, ' ');
        if (!/^https:\\/\\/github\\.com\\/[^/]+\\/[^/]+\\/pull\\/\\d+$/.test(url) || !title || /^#?\\d+$/.test(title)) continue;
        if ((titles.get(url) || '').length < title.length) titles.set(url, title);
      }
      return { items: [...titles] };
    })()
    """

    private static func replacing(_ nodes: [SidebarNode], folder id: Foundation.UUID,
                                  _ children: ([SidebarNode]) -> [SidebarNode]) -> [SidebarNode] {
        nodes.map { node in
            guard case var .folder(folder) = node else { return node }
            folder.children = folder.id == id ? children(folder.children) : replacing(folder.children, folder: id, children)
            return .folder(folder)
        }
    }

    private static func folderIDs(in nodes: [SidebarNode]) -> [Foundation.UUID] {
        nodes.flatMap { node -> [Foundation.UUID] in
            guard case let .folder(folder) = node else { return [] }
            return [folder.id] + folderIDs(in: folder.children)
        }
    }

    private static func load() -> [Foundation.UUID: Stored] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: Stored].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            Foundation.UUID(uuidString: key).map { ($0, value) }
        })
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: folders.map { ($0.key.uuidString, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: Self.key)
        UserDefaults.standard.synchronize()
    }
}
