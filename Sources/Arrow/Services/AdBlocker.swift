import ArrowKit
import Foundation
import Observation

/// Arrow's built-in ad and tracker blocker (Arc's ad blocker).
///
/// Filter lists come from the Arrow Cloud server when configured
/// (`/v1/blocklists`), otherwise directly from EasyList. They are cached for
/// a day and compiled into a `ContentBlocker` used by `CEFResourceFilter`.
@MainActor
@Observable
final class AdBlocker {
    private(set) var ruleCount = 0
    private(set) var lastUpdate: Date?
    @ObservationIgnored private weak var store: BrowserStore?
    @ObservationIgnored private var blocker = ContentBlocker()
    @ObservationIgnored private let cacheDirectory: URL

    private static let defaultLists = [
        ("easylist", "https://easylist.to/easylist/easylist.txt"),
        ("easyprivacy", "https://easylist.to/easylist/easyprivacy.txt"),
    ]
    private static let refreshInterval: TimeInterval = 24 * 3600

    init(store: BrowserStore) {
        self.store = store
        cacheDirectory = store.dataDirectory.appendingPathComponent("Blocklists", isDirectory: true)
    }

    var blockedRequests: Int { CEFResourceFilter.shared.blocked }

    /// Loads the cached lists, applies them, then refreshes stale ones.
    func start() {
        Task {
            await compile(from: cachedLists())
            apply()
            if isStale { await refresh() }
        }
    }

    /// Re-applies the current settings (toggle, allowed sites).
    func apply() {
        guard let settings = store?.settings, settings.adBlockerEnabled, blocker.ruleCount > 0 else {
            CEFResourceFilter.shared.setDecision(nil)
            return
        }
        let blocker = blocker
        let allowed = Set(settings.adBlockerAllowedSites)
        CEFResourceFilter.shared.setDecision { url, initiator, isNavigation in
            if let initiator, let host = URLComponents(string: initiator)?.host,
               allowed.contains(URLDisplay.registrableDomain(host.lowercased())) {
                return false
            }
            return blocker.shouldBlock(url: url, initiator: initiator, isNavigation: isNavigation)
        }
    }

    func isAllowed(site url: String) -> Bool {
        guard let host = URLDisplay.host(of: url)?.lowercased() else { return false }
        return store?.settings.adBlockerAllowedSites.contains(URLDisplay.registrableDomain(host)) ?? false
    }

    func setAllowed(_ allowed: Bool, site url: String) {
        guard let store, let host = URLDisplay.host(of: url)?.lowercased() else { return }
        let site = URLDisplay.registrableDomain(host)
        store.settings.adBlockerAllowedSites.removeAll { $0 == site }
        if allowed { store.settings.adBlockerAllowedSites.append(site) }
        apply()
    }

    // MARK: - Lists

    private var isStale: Bool {
        guard let lastUpdate else { return true }
        return Date().timeIntervalSince(lastUpdate) > Self.refreshInterval
    }

    private func cachedLists() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let lists = files.filter { $0.pathExtension == "txt" }
        lastUpdate = lists.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.min()
        return lists.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// Downloads the lists (from Arrow Cloud when configured).
    func refresh() async {
        var sources = Self.defaultLists.map { (id: $0.0, url: URL(string: $0.1)!) }
        if let server = store?.settings.cloudServerURL, !server.isEmpty,
           let manifestURL = URL(string: server)?.appendingPathComponent("v1/blocklists/manifest.json"),
           let (data, _) = try? await URLSession.shared.data(from: manifestURL),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data), !manifest.lists.isEmpty {
            sources = manifest.lists.compactMap { list in URL(string: list.url).map { (list.id, $0) } }
        }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        var lists: [String] = []
        for source in sources {
            guard let (data, response) = try? await URLSession.shared.data(from: source.url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else { continue }
            try? data.write(to: cacheDirectory.appendingPathComponent("\(source.id).txt"), options: .atomic)
            lists.append(text)
        }
        guard !lists.isEmpty else { return }
        lastUpdate = Date()
        await compile(from: lists)
        apply()
    }

    private struct Manifest: Decodable {
        struct List: Decodable {
            var id: String
            var url: String
        }

        var lists: [List]
    }

    private func compile(from lists: [String]) async {
        guard !lists.isEmpty else { return }
        let compiled = await Task.detached(priority: .utility) { ContentBlocker(lists: lists) }.value
        blocker = compiled
        ruleCount = compiled.ruleCount
    }
}
