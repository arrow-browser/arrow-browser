import Foundation

/// Formatting helpers for addresses shown in the UI.
public enum URLDisplay {
    /// Host without "www.", e.g. `github.com`.
    public static func host(of url: String) -> String? {
        guard let host = URLComponents(string: url)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Short form shown in the sidebar URL field (host only, like Arc).
    public static func short(_ url: String) -> String {
        if url.isEmpty || url == "about:blank" { return "" }
        if url.hasPrefix("arrow://") { return url }
        return host(of: url) ?? url
    }

    /// Full form without the scheme for display ("developer mode").
    public static func full(_ url: String) -> String {
        var value = url
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        if value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// Canonical form used to compare addresses (no fragment, trailing slash
    /// or "www.").
    public static func normalized(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.fragment = nil
        if let host = components.host, host.hasPrefix("www.") {
            components.host = String(host.dropFirst(4))
        }
        var value = components.string ?? url
        if value.hasSuffix("/") { value.removeLast() }
        return value.lowercased()
    }

    public static func isSameSite(_ lhs: String, _ rhs: String) -> Bool {
        guard let a = host(of: lhs), let b = host(of: rhs) else { return false }
        return registrableDomain(a) == registrableDomain(b)
    }

    /// Approximates the registrable domain (eTLD+1) of a host.
    public static func registrableDomain(_ host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let secondLevel = ["co", "com", "org", "net", "gov", "ac", "edu"]
        let take = secondLevel.contains(String(labels[labels.count - 2])) && labels.last!.count == 2 ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }
}

/// Page translation through Google's translation proxy (`*.translate.goog`).
public enum PageTranslation {
    /// Whether to offer translating a page written in `pageLanguage` (its
    /// `lang` attribute) to a user reading `userLanguages`, as Chrome's
    /// translate prompt does.
    public static func shouldOffer(pageLanguage: String?, userLanguages: [String], url: String,
                                   neverLanguages: [String], neverSites: [String]) -> Bool {
        guard let page = pageLanguage.map(baseLanguage), !page.isEmpty, page != "und",
              url.hasPrefix("http"), let host = URLDisplay.host(of: url) else { return false }
        let known = Set(userLanguages.map(baseLanguage))
        return !known.contains(page) && !neverLanguages.contains(page)
            && !neverSites.contains(URLDisplay.registrableDomain(host))
    }

    /// "fr-FR" → "fr".
    public static func baseLanguage(_ identifier: String) -> String {
        String(identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    /// Translated address of `url` in `language` (e.g. "fr"), or nil when the
    /// page cannot be proxied (non-web or already translated).
    public static func url(for url: String, to language: String) -> String? {
        guard var components = URLComponents(string: url), components.scheme == "https" || components.scheme == "http",
              let host = components.host, !host.hasSuffix(".translate.goog") else { return nil }
        // Dots become dashes and dashes are doubled in the proxy host name.
        let proxied = host.replacingOccurrences(of: "-", with: "--").replacingOccurrences(of: ".", with: "-")
        components.scheme = "https"
        components.host = proxied + ".translate.goog"
        components.port = nil
        var items = components.queryItems ?? []
        items += [URLQueryItem(name: "_x_tr_sl", value: "auto"), URLQueryItem(name: "_x_tr_tl", value: language),
                  URLQueryItem(name: "_x_tr_hl", value: language)]
        components.queryItems = items
        return components.string
    }
}

/// A web search provider.
public enum SearchEngine: String, Codable, CaseIterable, Sendable, Identifiable {
    case google
    case duckDuckGo
    case bing
    case ecosia
    case kagi
    case brave
    case perplexity
    case startpage
    case yahoo

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .ecosia: "Ecosia"
        case .kagi: "Kagi"
        case .brave: "Brave Search"
        case .perplexity: "Perplexity"
        case .startpage: "Startpage"
        case .yahoo: "Yahoo"
        }
    }

    /// Template where `%s` is the percent-encoded query.
    public var searchTemplate: String {
        switch self {
        case .google: "https://www.google.com/search?q=%s"
        case .duckDuckGo: "https://duckduckgo.com/?q=%s"
        case .bing: "https://www.bing.com/search?q=%s"
        case .ecosia: "https://www.ecosia.org/search?q=%s"
        case .kagi: "https://kagi.com/search?q=%s"
        case .brave: "https://search.brave.com/search?q=%s"
        case .perplexity: "https://www.perplexity.ai/search?q=%s"
        case .startpage: "https://www.startpage.com/sp/search?query=%s"
        case .yahoo: "https://search.yahoo.com/search?p=%s"
        }
    }

    /// Endpoint returning OpenSearch suggestions (`[query, [suggestions]]`).
    public var suggestionTemplate: String? {
        switch self {
        case .google: "https://www.google.com/complete/search?client=chrome&q=%s"
        case .duckDuckGo: "https://duckduckgo.com/ac/?type=list&q=%s"
        case .bing: "https://api.bing.com/osjson.aspx?query=%s"
        case .brave: "https://search.brave.com/api/suggest?q=%s"
        case .ecosia: "https://ac.ecosia.org/autocomplete?type=list&q=%s"
        case .yahoo: "https://search.yahoo.com/sugg/os?command=%s&output=fxjson"
        case .kagi, .perplexity, .startpage: nil
        }
    }

    public func searchURL(for query: String) -> String {
        searchTemplate.replacingOccurrences(of: "%s", with: URLInput.encodeQuery(query))
    }

    /// Instant Links (Shift-Return): an address that redirects to the top
    /// result. Google does it itself; DuckDuckGo's `\query` for the others.
    public func topResultURL(for query: String) -> String {
        switch self {
        case .google: "https://www.google.com/search?btnI=1&q=\(URLInput.encodeQuery(query))"
        default: "https://duckduckgo.com/?q=" + URLInput.encodeQuery("\\" + query)
        }
    }

    public func suggestionURL(for query: String) -> String? {
        suggestionTemplate?.replacingOccurrences(of: "%s", with: URLInput.encodeQuery(query))
    }

    /// Recognizes a results page of this engine and returns its query.
    public func query(fromSearchURL url: String) -> String? {
        guard let components = URLComponents(string: url),
              let template = URLComponents(string: searchTemplate),
              components.host == template.host, components.path == template.path,
              let key = template.queryItems?.first(where: { $0.value == "%s" })?.name
        else { return nil }
        // Form encoding uses "+" for spaces, which URLComponents keeps.
        return components.queryItems?.first(where: { $0.name == key })?.value?.replacingOccurrences(of: "+", with: " ")
    }
}

/// Search scoped to a website: type its name then Tab in the command bar
/// ("Site Search" in Arc).
public struct SiteSearch: Codable, Hashable, Sendable, Identifiable {
    public var id: String { keyword }
    public var name: String
    /// Typed prefix that activates it (e.g. "youtube").
    public var keyword: String
    public var template: String
    public var domain: String

    public init(name: String, keyword: String, template: String, domain: String) {
        self.name = name
        self.keyword = keyword
        self.template = template
        self.domain = domain
    }

    public func searchURL(for query: String) -> String {
        template.replacingOccurrences(of: "%s", with: URLInput.encodeQuery(query))
    }

    /// Max ▸ ChatGPT in the Command Bar.
    public static let chatGPT = SiteSearch(name: "ChatGPT", keyword: "chatgpt", template: "https://chatgpt.com/?q=%s",
                                           domain: "chatgpt.com")

    public static let builtIn: [SiteSearch] = [
        SiteSearch(name: "YouTube", keyword: "youtube", template: "https://www.youtube.com/results?search_query=%s", domain: "youtube.com"),
        SiteSearch(name: "Google Maps", keyword: "maps", template: "https://www.google.com/maps/search/%s", domain: "google.com/maps"),
        SiteSearch(name: "Wikipedia", keyword: "wikipedia", template: "https://wikipedia.org/w/index.php?search=%s", domain: "wikipedia.org"),
        SiteSearch(name: "GitHub", keyword: "github", template: "https://github.com/search?q=%s", domain: "github.com"),
        SiteSearch(name: "X", keyword: "x", template: "https://x.com/search?q=%s", domain: "x.com"),
        SiteSearch(name: "Reddit", keyword: "reddit", template: "https://www.reddit.com/search/?q=%s", domain: "reddit.com"),
        SiteSearch(name: "Amazon", keyword: "amazon", template: "https://www.amazon.com/s?k=%s", domain: "amazon.com"),
        SiteSearch(name: "Spotify", keyword: "spotify", template: "https://open.spotify.com/search/%s", domain: "open.spotify.com"),
        SiteSearch(name: "Apple Music", keyword: "music", template: "https://music.apple.com/us/search?term=%s", domain: "music.apple.com"),
        SiteSearch(name: "LinkedIn", keyword: "linkedin", template: "https://www.linkedin.com/search/results/all/?keywords=%s", domain: "linkedin.com"),
        SiteSearch(name: "Netflix", keyword: "netflix", template: "https://www.netflix.com/search?q=%s", domain: "netflix.com"),
        SiteSearch(name: "Pinterest", keyword: "pinterest", template: "https://www.pinterest.com/search/pins/?q=%s", domain: "pinterest.com"),
        SiteSearch(name: "TikTok", keyword: "tiktok", template: "https://www.tiktok.com/search?q=%s", domain: "tiktok.com"),
        SiteSearch(name: "Threads", keyword: "threads", template: "https://www.threads.net/search/?q=%s", domain: "threads.net"),
        SiteSearch(name: "Stack Overflow", keyword: "stackoverflow", template: "https://stackoverflow.com/search?q=%s", domain: "stackoverflow.com"),
        SiteSearch(name: "SoundCloud", keyword: "soundcloud", template: "https://soundcloud.com/search?q=%s", domain: "soundcloud.com"),
        SiteSearch(name: "Goodreads", keyword: "goodreads", template: "https://www.goodreads.com/search?q=%s", domain: "goodreads.com"),
        SiteSearch(name: "Figma", keyword: "figma", template: "https://www.figma.com/files/search?q=%s", domain: "figma.com"),
        SiteSearch(name: "Google Flights", keyword: "flights", template: "https://www.google.com/travel/flights?q=%s", domain: "google.com/travel"),
        SiteSearch(name: "Perplexity", keyword: "perplexity", template: "https://www.perplexity.ai/search?q=%s", domain: "perplexity.ai"),
    ]

    /// Site search whose keyword starts with `text` (case-insensitive).
    public static func matching(_ text: String, in engines: [SiteSearch] = builtIn) -> SiteSearch? {
        let typed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard typed.count >= 2 else { return nil }
        return engines.first { $0.keyword.hasPrefix(typed) || $0.name.lowercased().hasPrefix(typed) }
    }
}

/// Interpretation of text typed in the command bar / URL field.
public enum URLInput: Equatable, Sendable {
    case url(String)
    case search(String)

    private static let knownSchemes: Set<String> = [
        "http", "https", "file", "about", "chrome", "arrow", "data", "blob", "view-source", "mailto", "javascript", "ftp",
    ]

    public static func encodeQuery(_ query: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        return query.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: "%20", with: "+") ?? query
    }

    /// Parses `text`: an address when it looks like one, a search otherwise.
    public static func parse(_ text: String) -> URLInput {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .search("") }

        if let schemeEnd = input.firstIndex(of: ":") {
            let scheme = input[..<schemeEnd].lowercased()
            if knownSchemes.contains(scheme), !input.contains(" ") || scheme == "javascript" || scheme == "data" {
                return .url(input)
            }
        }
        if input.contains(" ") { return .search(input) }
        if input.hasPrefix("/") || input.hasPrefix("~/") {
            return .url(URL(fileURLWithPath: (input as NSString).expandingTildeInPath).absoluteString)
        }

        let hostPart = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        let hostOnly = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let lowered = hostOnly.lowercased()

        if lowered == "localhost" || isIPv4(lowered) || (hostOnly.hasPrefix("[") && hostOnly.contains("]")) {
            return .url("http://\(input)")
        }
        let labels = lowered.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter || $0 == "-" || $0.isNumber }),
              !tld.allSatisfy(\.isNumber),
              lowered.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
        else {
            return .search(input)
        }
        return .url("https://\(input)")
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// Address to load for `text` with `engine` for searches.
    public static func resolve(_ text: String, engine: SearchEngine) -> String {
        switch parse(text) {
        case let .url(url): url
        case let .search(query): engine.searchURL(for: query)
        }
    }
}
