import Foundation

/// An action available from the command bar (also used by the menus).
public struct CommandBarCommand: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var keywords: [String]
    /// SF Symbol name.
    public var symbol: String
    /// Display form of the keyboard shortcut, e.g. "⌘⇧C".
    public var shortcut: String?

    public init(id: String, title: String, keywords: [String] = [], symbol: String, shortcut: String? = nil) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.symbol = symbol
        self.shortcut = shortcut
    }

    func matches(_ terms: [String]) -> Bool {
        let haystack = ([title] + keywords).joined(separator: " ").lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }
}

/// A row of the command bar.
public struct CommandBarItem: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// Load a typed address.
        case navigate(url: String)
        /// Search the web.
        case search(query: String)
        /// Search a specific site.
        case siteSearch(SiteSearch, query: String)
        /// Focus an open tab.
        case switchToTab(UUID)
        /// Open an address (history, suggestion).
        case open(url: String)
        case command(String)
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    /// Address used for the favicon.
    public var url: String?
    public var symbol: String?
    /// Right-aligned hint ("Switch to Tab", "⌘⇧C"…).
    public var actionLabel: String?

    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, url: String? = nil,
                symbol: String? = nil, actionLabel: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.symbol = symbol
        self.actionLabel = actionLabel
    }
}

/// Arc's inline autocompletion: the typed text is completed in the field
/// with the address of the best history match ("git" → "github.com").
public struct CommandBarCompletion: Hashable, Sendable {
    /// Full text of the field once completed.
    public var text: String
    public var url: String
    public var title: String

    public init(text: String, url: String, title: String) {
        self.text = text
        self.url = url
        self.title = title
    }
}

/// An open tab offered by the command bar.
public struct CommandBarTab: Hashable, Sendable {
    public var tab: Tab
    public var spaceTitle: String?

    public init(tab: Tab, spaceTitle: String?) {
        self.tab = tab
        self.spaceTitle = spaceTitle
    }
}

/// Builds and ranks command bar rows.
public struct CommandBarRanker: Sendable {
    public var engine: SearchEngine
    public var siteSearches: [SiteSearch]
    /// Hosts whose history entries are deduplicated by title (Arc's
    /// `dedupByTitleAndHostList`).
    public var dedupByTitleHosts: Set<String>

    public init(engine: SearchEngine, siteSearches: [SiteSearch] = SiteSearch.builtIn,
                dedupByTitleHosts: Set<String> = CommandBarRanker.defaultDedupHosts) {
        self.engine = engine
        self.siteSearches = siteSearches
        self.dedupByTitleHosts = dedupByTitleHosts
    }

    public static let defaultDedupHosts: Set<String> = [
        "figma.com", "maps.google.com", "notion.so", "app.notion.com", "zoom.us", "opentable.com", "zillow.com",
        "github.com", "app.mode.com", "console.cloud.google.com",
    ]

    /// Site offered for `text` ("youtube", then Tab to search YouTube). Arc
    /// shows it at the end of the field rather than as a row.
    public func siteSearchHint(for text: String) -> SiteSearch? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !query.contains(" ") else { return nil }
        return SiteSearch.matching(query, in: siteSearches)
    }

    /// Completion of `text` with the address of the best history match whose
    /// address starts with it.
    public func completion(for text: String, history: History, now: Date = Date()) -> CommandBarCompletion? {
        let typed = text.lowercased()
        guard !typed.isEmpty, !typed.contains(" ") else { return nil }
        for entry in history.search(text, limit: 8, now: now) {
            let address = URLDisplay.full(entry.url)
            guard address.lowercased().hasPrefix(typed), address.count > text.count else { continue }
            return CommandBarCompletion(text: text + address.dropFirst(text.count), url: entry.url,
                                        title: entry.title.isEmpty ? address : entry.title)
        }
        return nil
    }

    /// Rows for `text`. `activeSiteSearch` is set once the user pressed Tab
    /// on a site keyword; `completion` is the inline autocompletion, listed
    /// first.
    public func items(for text: String, activeSiteSearch: SiteSearch? = nil, completion: CommandBarCompletion? = nil,
                      openTabs: [CommandBarTab], history: History, suggestions: [String], commands: [CommandBarCommand],
                      currentTabID: UUID? = nil, now: Date = Date()) -> [CommandBarItem] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let activeSiteSearch {
            guard !query.isEmpty else { return [] }
            return [CommandBarItem(id: "site-search", kind: .siteSearch(activeSiteSearch, query: query), title: query,
                                   subtitle: "Search \(activeSiteSearch.name)", url: "https://\(activeSiteSearch.domain)")]
                + suggestions.prefix(6).map { suggestion in
                    CommandBarItem(id: "site-suggestion-\(suggestion)", kind: .siteSearch(activeSiteSearch, query: suggestion),
                                   title: suggestion, subtitle: "Search \(activeSiteSearch.name)", symbol: "magnifyingglass")
                }
        }

        guard !query.isEmpty else {
            return openTabs
                .filter { $0.tab.id != currentTabID }
                .sorted { $0.tab.lastActiveAt > $1.tab.lastActiveAt }
                .prefix(6)
                .map(tabItem)
        }

        let terms = query.lowercased().split(separator: " ").map(String.init)
        var items: [CommandBarItem] = []
        var seenURLs = Set<String>()
        var seenTitleHosts = Set<String>()

        func isDuplicate(url: String, title: String) -> Bool {
            let normalized = URLDisplay.normalized(url)
            if seenURLs.contains(normalized) { return true }
            if let host = URLDisplay.host(of: url), dedupByTitleHosts.contains(host) {
                let key = "\(host)|\(title.lowercased())"
                if seenTitleHosts.contains(key) { return true }
                seenTitleHosts.insert(key)
            }
            seenURLs.insert(normalized)
            return false
        }

        // 1. Primary action: the autocompleted address, then navigate or search.
        if let completion {
            items.append(CommandBarItem(id: "completion", kind: .open(url: completion.url), title: completion.title,
                                        subtitle: URLDisplay.full(completion.url), url: completion.url, symbol: "clock"))
            _ = isDuplicate(url: completion.url, title: completion.title)
        }
        switch URLInput.parse(query) {
        case let .url(url):
            items.append(CommandBarItem(id: "navigate", kind: .navigate(url: url), title: URLDisplay.full(url),
                                        subtitle: "Open", url: url))
            _ = isDuplicate(url: url, title: "")
        case .search:
            items.append(CommandBarItem(id: "search", kind: .search(query: query), title: query,
                                        subtitle: "Search \(engine.name)", symbol: "magnifyingglass"))
        }

        // 2. Open tabs.
        let tabMatches = openTabs.filter { candidate in
            let haystack = (candidate.tab.displayTitle + " " + URLDisplay.full(candidate.tab.url)).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
        .sorted { $0.tab.lastActiveAt > $1.tab.lastActiveAt }
        for candidate in tabMatches.prefix(5) where !isDuplicate(url: candidate.tab.url, title: candidate.tab.displayTitle) {
            items.append(tabItem(candidate))
        }

        // 3. History.
        for entry in history.search(query, limit: 8, now: now) where !isDuplicate(url: entry.url, title: entry.title) {
            items.append(CommandBarItem(id: "history-\(entry.url)", kind: .open(url: entry.url),
                                        title: entry.title.isEmpty ? URLDisplay.full(entry.url) : entry.title,
                                        subtitle: URLDisplay.full(entry.url), url: entry.url))
            if items.count >= 9 { break }
        }

        // 4. Search suggestions.
        let loweredQuery = query.lowercased()
        for suggestion in suggestions.prefix(5) where suggestion.lowercased() != loweredQuery {
            switch URLInput.parse(suggestion) {
            case let .url(url) where !suggestion.contains(" "):
                if !isDuplicate(url: url, title: "") {
                    items.append(CommandBarItem(id: "suggestion-url-\(url)", kind: .navigate(url: url), title: suggestion, url: url))
                }
            default:
                items.append(CommandBarItem(id: "suggestion-\(suggestion)", kind: .search(query: suggestion), title: suggestion,
                                            symbol: "magnifyingglass"))
            }
        }

        // 5. Commands.
        for command in commands.filter({ $0.matches(terms) }).prefix(5) {
            items.append(CommandBarItem(id: "command-\(command.id)", kind: .command(command.id), title: command.title,
                                        symbol: command.symbol, actionLabel: command.shortcut))
        }
        return items
    }

    private func tabItem(_ candidate: CommandBarTab) -> CommandBarItem {
        CommandBarItem(id: "tab-\(candidate.tab.id)", kind: .switchToTab(candidate.tab.id), title: candidate.tab.displayTitle,
                       subtitle: candidate.spaceTitle, url: candidate.tab.url, actionLabel: "Switch to Tab")
    }
}

/// Parses an OpenSearch suggestions response (`["query", ["a", "b"]]`).
public enum SearchSuggestions {
    /// A site the engine suggests going to, with its relevance (Google's
    /// "NAVIGATION" suggestions).
    public struct Navigation: Hashable, Sendable {
        public var url: String
        public var relevance: Int

        public init(url: String, relevance: Int) {
            self.url = url
            self.relevance = relevance
        }
    }

    public static func parse(_ data: Data) -> [String] {
        guard let json = json(data) else { return [] }
        if let array = json as? [Any], array.count >= 2, let values = array[1] as? [String] {
            return values
        }
        if let objects = json as? [[String: Any]] {
            return objects.compactMap { $0["phrase"] as? String }
        }
        return []
    }

    /// The navigational suggestions of a Google answer (its "chrome" client
    /// lists their types and relevance).
    public static func navigations(_ data: Data) -> [Navigation] {
        guard let array = json(data) as? [Any], array.count >= 5, let values = array[1] as? [String],
              let metadata = array[4] as? [String: Any],
              let types = metadata["google:suggesttype"] as? [String] else { return [] }
        let relevances = metadata["google:suggestrelevance"] as? [Int] ?? []
        return zip(values, types).enumerated().compactMap { index, suggestion in
            guard suggestion.1 == "NAVIGATION" else { return nil }
            return Navigation(url: suggestion.0, relevance: relevances.indices.contains(index) ? relevances[index] : 0)
        }
    }

    // Google answers in ISO-8859-1 when a suggestion has an accent
    // ("traduction français").
    private static func json(_ data: Data) -> Any? {
        (try? JSONSerialization.jsonObject(with: data))
            ?? String(data: data, encoding: .isoLatin1).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    }
}
