import ArrowCore
import ArrowKit
import Foundation

/// The command bar of Arc on Windows: five rows, a well-known site completed
/// in the field ("transl" → translate.google.com), then the search, the
/// other sites, open tabs, commands, history and suggestions. Like Arc, it
/// learns: the row chosen for a query comes first the next time
/// (queriesToSelectedArchetype), commands run often come before others
/// (typeTravelUsage) and tabs switched to lately before other tabs
/// (recentlySwitchedToTabs).
enum CommandBarRanking {
    struct Site {
        var domain: String
        var name: String
        var url: String { "https://\(domain)/" }
    }

    static let maximumRows = 5
    /// The share of a page's title what was typed covers for the page to
    /// come before the suggestions (Arc: "split" in "Split View" does, "pin"
    /// in "Pinned Tabs" does not).
    static let minimumTitleShare = 0.4

    /// Words for which Arc lists a command before the search, as observed in
    /// Arc 1.130 for Windows (where it had no usage of its own).
    static let triggers: [String: String] = [
        "close": "close", "copy": "build-info", "developer": "devtools", "duplicate": "duplicate",
        "force": "force-reload", "fullscreen": "fullscreen", "import": "import", "inspect": "inspect",
        "previous": "previous-tab", "print": "print", "reopen": "reopen", "rename": "rename-space",
        "settings": "settings", "sidebar": "toggle-sidebar", "update": "updates", "view": "view-source",
    ]

    private static let selectionsKey = "CommandBarSelections"
    private static let usageKey = "CommandBarCommandUsage"
    private static let switchedTabsKey = "CommandBarSwitchedTabs"
    private static let maximumSelections = 200
    private static let maximumSwitchedTabs = 20
    /// Runs after which a command matching what was typed comes first.
    static let usageBump = 3

    /// Remembers the row chosen for `query`, to list it first next time,
    /// and counts the commands run and the tabs switched to.
    static func remember(_ item: CommandBarItem, for query: String) {
        let defaults = UserDefaults.standard
        switch item.kind {
        case let .command(id):
            var usage = defaults.dictionary(forKey: usageKey) as? [String: Int] ?? [:]
            usage[id, default: 0] += 1
            defaults.set(usage, forKey: usageKey)
        case let .switchToTab(id):
            var tabs = defaults.stringArray(forKey: switchedTabsKey) ?? []
            tabs.removeAll { $0 == id.uuidString }
            tabs.insert(id.uuidString, at: 0)
            defaults.set(Array(tabs.prefix(maximumSwitchedTabs)), forKey: switchedTabsKey)
        default:
            break
        }
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return }
        var selections = defaults.dictionary(forKey: selectionsKey) as? [String: String] ?? [:]
        if selections[query] == nil, selections.count >= maximumSelections, let any = selections.keys.first {
            selections[any] = nil
        }
        selections[query] = identity(of: item)
        defaults.set(selections, forKey: selectionsKey)
    }

    /// How many times each command was run from the bar.
    static var commandUsage: [String: Int] {
        UserDefaults.standard.dictionary(forKey: usageKey) as? [String: Int] ?? [:]
    }

    /// What a row stands for, the same from one query to the next.
    static func identity(of item: CommandBarItem) -> String {
        switch item.kind {
        case let .navigate(url), let .open(url): "url:\(url)"
        case let .search(query): "search:\(query.lowercased())"
        case let .siteSearch(site, query): "site:\(site.domain):\(query.lowercased())"
        case let .switchToTab(id): "tab:\(id.uuidString)"
        case let .command(id): "command:\(id)"
        }
    }

    /// Completes `text` with the first well-known site whose domain starts
    /// with it, keeping what was typed.
    static func completion(for text: String) -> CommandBarCompletion? {
        guard let site = sites(matching: text).first else { return nil }
        return CommandBarCompletion(text: text + site.domain.dropFirst(text.count), url: site.url, title: site.name)
    }

    /// Completes `text` with a site Google suggests strongly whose address
    /// starts with it, as Arc does once suggestions arrive ("zoom" →
    /// zoomalia.com, relevance 1249; not "help" → helpmariage.fr, 601).
    static func suggestedCompletion(_ navigations: [SearchSuggestions.Navigation], _ text: String) -> CommandBarCompletion? {
        let typed = text.lowercased()
        guard !typed.isEmpty, !typed.contains(" ") else { return nil }
        for navigation in navigations where navigation.relevance >= 1200 {
            guard let host = URLDisplay.host(of: navigation.url), host.hasPrefix(typed), host.count > typed.count
            else { continue }
            return CommandBarCompletion(text: text + host.dropFirst(text.count), url: navigation.url, title: host)
        }
        return nil
    }

    /// Well-known sites whose domain starts with `text`, the most visited
    /// first.
    static func sites(matching text: String) -> [Site] {
        let typed = text.lowercased()
        guard !typed.isEmpty, !typed.contains(" ") else { return [] }
        return sites.filter { $0.domain.hasPrefix(typed) && $0.domain.count > typed.count }
    }

    /// Whether Arc lists `command` for `query`: a word starts its title's
    /// first word or one of its keywords ("view" finds View Source, not New
    /// Split View), or the query starts its title.
    static func matches(_ command: CommandBarCommand, _ query: String) -> Bool {
        let title = command.title.lowercased()
        let firstWord = title.split(separator: " ").first.map(String.init) ?? title
        return firstWord.hasPrefix(query) || title.hasPrefix(query)
            || command.keywords.contains { $0.lowercased().hasPrefix(query) }
    }

    static func arrange(_ items: [CommandBarItem], _ typedText: String,
                        commands catalog: [CommandBarCommand] = []) -> [CommandBarItem] {
        let query = typedText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return items }
        // A well-known site shows its name and address, with its favicon.
        let completion = items.filter { $0.id == "completion" }.map { item -> CommandBarItem in
            var row = item
            if let site = sites.first(where: { $0.url == item.url }) {
                row.title = site.name
                row.subtitle = site.url
                row.symbol = nil
            } else if let url = item.url, URLDisplay.host(of: url) == item.title {
                // A site Google suggested: its address, with its favicon.
                row.subtitle = url
                row.symbol = nil
            }
            return row
        }
        let search = items.filter { $0.id == "search" || $0.id == "navigate" }
        let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let usage = commandUsage
        func runs(_ item: CommandBarItem) -> Int {
            if case let .command(id) = item.kind { usage[id] ?? 0 } else { 0 }
        }
        // Commands run more often first (a stable sort keeps Arc's order).
        var commands = items.filter { item in
            guard case let .command(id) = item.kind else { return false }
            return byID[id].map { matches($0, query) } ?? true
        }
        commands = commands.enumerated().sorted { lhs, rhs in
            let (left, right) = (runs(lhs.element), runs(rhs.element))
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
        // Tabs switched to lately first.
        let switched = UserDefaults.standard.stringArray(forKey: switchedTabsKey) ?? []
        func recency(_ item: CommandBarItem) -> Int {
            guard case let .switchToTab(id) = item.kind else { return Int.max }
            return switched.firstIndex(of: id.uuidString) ?? Int.max
        }
        var tabs = items.filter { if case .switchToTab = $0.kind { true } else { false } }
            .enumerated().sorted { (recency($0.element), $0.offset) < (recency($1.element), $1.offset) }.map(\.element)
        var history = items.filter { $0.id.hasPrefix("history-") }
        let suggestions = items.filter { $0.id.hasPrefix("suggestion") || $0.id == "chatgpt" }
        // A page found in the middle of its title or address ("view" in
        // "Split View"), or covering little of its title ("pin" in "Pinned
        // Tabs"), comes after the suggestions: Arc scores a match by its
        // position and its share of the title ("split" in "Split View" is
        // half of it, and comes first).
        func startsWithQuery(_ item: CommandBarItem) -> Bool {
            let title = item.title.lowercased()
            return title.hasPrefix(query) && Double(query.count) >= Double(title.count) * minimumTitleShare
                || item.url.flatMap { URLDisplay.host(of: $0) }?.hasPrefix(query) == true
        }
        let laterTabs = tabs.filter { !startsWithQuery($0) }
        tabs = tabs.filter(startsWithQuery)
        let laterHistory = history.filter { !startsWithQuery($0) }
        history = history.filter(startsWithQuery)
        // Without a site, Arc's command for that word comes first.
        var first = completion
        let trigger = triggers[query] ?? triggers.keys.sorted().first { query.count >= 3 && $0.hasPrefix(query) }
            .flatMap { triggers[$0] }
        if first.isEmpty, let id = trigger,
           let index = commands.firstIndex(where: { $0.kind == .command(id) }) {
            first = [commands.remove(at: index)]
        }
        // Or the command run most, once run often.
        if first.isEmpty, let command = commands.first, runs(command) >= usageBump {
            first = [commands.removeFirst()]
        }
        // Then an open tab named after what was typed.
        if first.isEmpty, let index = tabs.firstIndex(where: { $0.title.lowercased().hasPrefix(query) }) {
            first = [tabs.remove(at: index)]
        }
        let completed = Set(completion.compactMap(\.url))
        let otherSites = sites(matching: query).filter { !completed.contains($0.url) }.map { site in
            CommandBarItem(id: "site-\(site.domain)", kind: .open(url: site.url), title: site.name, subtitle: site.url,
                           url: site.url)
        }
        var rows = first + search + otherSites + tabs + commands + history + suggestions + laterTabs + laterHistory
        // The row chosen the last time this was typed.
        let selections = UserDefaults.standard.dictionary(forKey: selectionsKey) as? [String: String]
        if let chosen = selections?[query], let index = rows.firstIndex(where: { identity(of: $0) == chosen }) {
            rows.insert(rows.remove(at: index), at: 0)
        }
        return Array(rows.prefix(maximumRows))
    }

    /// Popular sites, by domain.
    static let sites: [Site] = [
        ("google.com", "Google"), ("youtube.com", "YouTube"), ("facebook.com", "Facebook"),
        ("instagram.com", "Instagram"), ("wikipedia.org", "Wikipedia"), ("x.com", "X"), ("reddit.com", "Reddit"),
        ("amazon.com", "Amazon"), ("linkedin.com", "LinkedIn"), ("netflix.com", "Netflix"),
        ("mail.google.com", "Gmail"), ("translate.google.com", "Google Translate"), ("docs.google.com", "Google Docs"),
        ("drive.google.com", "Google Drive"), ("maps.google.com", "Google Maps"), ("news.google.com", "Google News"),
        ("calendar.google.com", "Google Calendar"), ("meet.google.com", "Google Meet"),
        ("photos.google.com", "Google Photos"), ("sheets.google.com", "Google Sheets"),
        ("slides.google.com", "Google Slides"), ("gemini.google.com", "Gemini"), ("play.google.com", "Google Play"),
        ("scholar.google.com", "Google Scholar"), ("music.youtube.com", "YouTube Music"), ("yahoo.com", "Yahoo"),
        ("news.yahoo.com", "Yahoo News"), ("bing.com", "Bing"), ("duckduckgo.com", "DuckDuckGo"),
        ("chatgpt.com", "ChatGPT"), ("claude.ai", "Claude"), ("openai.com", "OpenAI"), ("anthropic.com", "Anthropic"),
        ("microsoft.com", "Microsoft"), ("outlook.live.com", "Outlook"), ("office.com", "Microsoft 365"),
        ("apple.com", "Apple"), ("icloud.com", "iCloud"), ("github.com", "GitHub"), ("gitlab.com", "GitLab"),
        ("stackoverflow.com", "Stack Overflow"), ("npmjs.com", "npm"),
        ("notion.so", "Notion"), ("figma.com", "Figma"), ("slack.com", "Slack"), ("discord.com", "Discord"),
        ("zoom.us", "Zoom"), ("trello.com", "Trello"), ("asana.com", "Asana"), ("atlassian.com", "Atlassian"),
        ("linear.app", "Linear"), ("vercel.com", "Vercel"), ("dropbox.com", "Dropbox"), ("canva.com", "Canva"),
        ("adobe.com", "Adobe"), ("salesforce.com", "Salesforce"), ("shopify.com", "Shopify"),
        ("twitch.tv", "Twitch"), ("tiktok.com", "TikTok"), ("pinterest.com", "Pinterest"),
        ("pinterest.co.uk", "Pinterest UK"), ("tumblr.com", "Tumblr"), ("whatsapp.com", "WhatsApp"), ("web.whatsapp.com", "WhatsApp Web"),
        ("telegram.org", "Telegram"), ("web.telegram.org", "Telegram Web"), ("signal.org", "Signal"),
        ("spotify.com", "Spotify"), ("soundcloud.com", "SoundCloud"), ("vimeo.com", "Vimeo"),
        ("hulu.com", "Hulu"), ("disneyplus.com", "Disney+"), ("primevideo.com", "Prime Video"),
        ("crunchyroll.com", "Crunchyroll"), ("imdb.com", "IMDb"), ("ebay.com", "eBay"), ("etsy.com", "Etsy"),
        ("walmart.com", "Walmart"), ("target.com", "Target"), ("bestbuy.com", "Best Buy"), ("ikea.com", "IKEA"),
        ("aliexpress.com", "AliExpress"), ("paypal.com", "PayPal"), ("chase.com", "Chase"),
        ("bankofamerica.com", "Bank of America"), ("wellsfargo.com", "Wells Fargo"), ("coinbase.com", "Coinbase"),
        ("airbnb.com", "Airbnb"), ("booking.com", "Booking.com"), ("tripadvisor.com", "Tripadvisor"),
        ("uber.com", "Uber"), ("yelp.com", "Yelp"), ("nextdoor.com", "Nextdoor"), ("craigslist.org", "Craigslist"),
        ("zillow.com", "Zillow"), ("indeed.com", "Indeed"), ("glassdoor.com", "Glassdoor"),
        ("nytimes.com", "The New York Times"), ("newyorker.com", "The New Yorker"), ("newsweek.com", "Newsweek"),
        ("theguardian.com", "The Guardian"), ("washingtonpost.com", "The Washington Post"),
        ("wsj.com", "The Wall Street Journal"), ("bbc.com", "BBC"), ("cnn.com", "CNN"), ("reuters.com", "Reuters"),
        ("bloomberg.com", "Bloomberg"), ("forbes.com", "Forbes"), ("theverge.com", "The Verge"),
        ("medium.com", "Medium"), ("substack.com", "Substack"), ("quora.com", "Quora"),
        ("archive.org", "Internet Archive"), ("archiveofourown.org", "Archive of Our Own"), ("wikihow.com", "wikiHow"), ("fandom.com", "Fandom"),
        ("weather.com", "The Weather Channel"), ("espn.com", "ESPN"), ("nba.com", "NBA"),
        ("store.steampowered.com", "Steam"), ("epicgames.com", "Epic Games"), ("roblox.com", "Roblox"),
        ("xbox.com", "Xbox"), ("playstation.com", "PlayStation"), ("nintendo.com", "Nintendo"),
        ("coursera.org", "Coursera"), ("khanacademy.org", "Khan Academy"), ("duolingo.com", "Duolingo"),
        ("deepl.com", "DeepL"), ("tabelog.com", "Tabelog"), ("themeforest.net", "ThemeForest"),
        ("windows.net", "Windows Azure"), ("networkadvertising.org", "Network Advertising Initiative"), ("wordpress.com", "WordPress"), ("mozilla.org", "Mozilla"), ("proton.me", "Proton"),
    ].map { Site(domain: $0.0, name: $0.1) }
}
