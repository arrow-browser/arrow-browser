import ArrowCore
import ArrowKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Arc's Live Folders: pinned folders kept filled from GitHub (the open pull
/// requests or issues of a user or a repository), refreshed every few
/// minutes. Which folders are live is a setting of this app, in its
/// defaults.
@MainActor
final class LiveFolders {
    struct Source: Codable, Equatable {
        enum Kind: String, Codable {
            case pullRequests, issues
        }

        /// A user ("octocat") or a repository ("apple/swift").
        var query: String
        var kind: Kind

        var title: String {
            "\(query) \(kind == .pullRequests ? "Pull Requests" : "Issues")"
        }

        /// GitHub's search for the open items.
        var searchURL: URL? {
            var components = URLComponents(string: "https://api.github.com/search/issues")
            let scope = query.contains("/") ? "repo:\(query)" : "involves:\(query)"
            components?.queryItems = [
                URLQueryItem(name: "q", value: "\(scope) is:open is:\(kind == .pullRequests ? "pr" : "issue")"),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "per_page", value: "30"),
            ]
            return components?.url
        }
    }

    static let shared = LiveFolders()
    private static let key = "LiveFolders"
    private static let refreshInterval: TimeInterval = 10 * 60

    private weak var store: BrowserStore?
    private var timer: Timer?
    private var sources: [Foundation.UUID: Source] = LiveFolders.load()

    func isLive(_ folderID: Foundation.UUID) -> Bool {
        sources[folderID] != nil
    }

    /// Refreshes the live folders now, then every few minutes.
    func start(store: BrowserStore) {
        self.store = store
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated { LiveFolders.shared.refreshAll() }
        }
    }

    /// A new live folder pinned in `spaceID`, filled at once.
    func add(_ source: Source, in spaceID: Foundation.UUID) -> ArrowKit.Folder? {
        guard let store else { return nil }
        var folder: ArrowKit.Folder?
        store.update { folder = $0.createFolder(in: spaceID, title: source.title) }
        guard let folder else { return nil }
        sources[folder.id] = source
        save()
        refresh(folder.id)
        return folder
    }

    private func refreshAll() {
        guard let store else { return }
        // Folders deleted meanwhile stop being live.
        let existing = Set(store.state.spaces.flatMap { Self.folderIDs(in: $0.pinned) })
        let gone = sources.keys.filter { !existing.contains($0) }
        if !gone.isEmpty {
            for id in gone { sources[id] = nil }
            save()
        }
        for id in sources.keys {
            refresh(id)
        }
    }

    private func refresh(_ folderID: Foundation.UUID) {
        guard let source = sources[folderID], let url = source.searchURL else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Arrow", forHTTPHeaderField: "User-Agent")
        Task {
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }
            let items = Self.items(data)
            guard !items.isEmpty || Self.isEmptyResult(data) else { return }
            fill(folderID, with: items)
        }
    }

    /// Replaces the folder's tabs with `items`, keeping the tabs of the
    /// addresses it already has (and their pages).
    private func fill(_ folderID: Foundation.UUID, with items: [(title: String, url: String)]) {
        guard let store else { return }
        store.update { browser in
            for index in browser.spaces.indices {
                browser.spaces[index].pinned = Self.replacing(browser.spaces[index].pinned, folder: folderID) { old in
                    let existing = Dictionary(old.allTabs.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
                    return items.map { item in
                        .tab(existing[item.url] ?? Tab(url: item.url, title: item.title, pinnedURL: item.url))
                    }
                }
            }
        }
    }

    /// GitHub's search results: each item's title and page.
    static func items(_ data: Data) -> [(title: String, url: String)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let title = item["title"] as? String, let url = item["html_url"] as? String else { return nil }
            return (title, url)
        }
    }

    private static func isEmptyResult(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["total_count"] as? Int == 0
    }

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

    private static func load() -> [Foundation.UUID: Source] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: Source].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            Foundation.UUID(uuidString: key).map { ($0, value) }
        })
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: sources.map { ($0.key.uuidString, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: Self.key)
        UserDefaults.standard.synchronize()
    }
}
