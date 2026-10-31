import ArrowCore
import ArrowKit
import Foundation

/// The command bar of Arc on Windows: five rows, a well-known site completed
/// in the field ("transl" → translate.google.com), then the search, the
/// other sites, open tabs, commands, history and suggestions.
enum CommandBarRanking {
    struct Site {
        var domain: String
        var name: String
        var url: String { "https://\(domain)/" }
    }

    static let maximumRows = 5

    /// Completes `text` with the first well-known site whose domain starts
    /// with it, keeping what was typed.
    static func completion(for text: String) -> CommandBarCompletion? {
        guard let site = sites(matching: text).first else { return nil }
        return CommandBarCompletion(text: text + site.domain.dropFirst(text.count), url: site.url, title: site.name)
    }

    /// Well-known sites whose domain starts with `text`, the most visited
    /// first.
    static func sites(matching text: String) -> [Site] {
        let typed = text.lowercased()
        guard !typed.isEmpty, !typed.contains(" ") else { return [] }
        return sites.filter { $0.domain.hasPrefix(typed) && $0.domain.count > typed.count }
    }

    static func arrange(_ items: [CommandBarItem], _ typedText: String) -> [CommandBarItem] {
        let query = typedText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return items }
        // A well-known site shows its name and address, with its favicon.
        let completion = items.filter { $0.id == "completion" }.map { item -> CommandBarItem in
            guard let site = sites.first(where: { $0.url == item.url }) else { return item }
            var row = item
            row.title = site.name
            row.subtitle = site.url
            row.symbol = nil
            return row
        }
        let search = items.filter { $0.id == "search" || $0.id == "navigate" }
        var commands = items.filter { if case .command = $0.kind { true } else { false } }
        let tabs = items.filter { if case .switchToTab = $0.kind { true } else { false } }
        let history = items.filter { $0.id.hasPrefix("history-") }
        let suggestions = items.filter { $0.id.hasPrefix("suggestion") || $0.id == "chatgpt" }
        // Without a site, a command named after what was typed comes first.
        var first = completion
        if first.isEmpty, let index = commands.firstIndex(where: { $0.title.lowercased().hasPrefix(query) }) {
            first = [commands.remove(at: index)]
        }
        let completed = Set(completion.compactMap(\.url))
        let otherSites = sites(matching: query).filter { !completed.contains($0.url) }.map { site in
            CommandBarItem(id: "site-\(site.domain)", kind: .open(url: site.url), title: site.name, subtitle: site.url,
                           url: site.url)
        }
        return Array((first + search + otherSites + tabs + commands + history + suggestions).prefix(maximumRows))
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
        ("stackoverflow.com", "Stack Overflow"), ("developer.mozilla.org", "MDN Web Docs"), ("npmjs.com", "npm"),
        ("notion.so", "Notion"), ("figma.com", "Figma"), ("slack.com", "Slack"), ("discord.com", "Discord"),
        ("zoom.us", "Zoom"), ("trello.com", "Trello"), ("asana.com", "Asana"), ("atlassian.com", "Atlassian"),
        ("linear.app", "Linear"), ("vercel.com", "Vercel"), ("dropbox.com", "Dropbox"), ("canva.com", "Canva"),
        ("adobe.com", "Adobe"), ("salesforce.com", "Salesforce"), ("shopify.com", "Shopify"),
        ("twitch.tv", "Twitch"), ("tiktok.com", "TikTok"), ("pinterest.com", "Pinterest"),
        ("tumblr.com", "Tumblr"), ("whatsapp.com", "WhatsApp"), ("web.whatsapp.com", "WhatsApp Web"),
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
        ("archive.org", "Internet Archive"), ("wikihow.com", "wikiHow"), ("fandom.com", "Fandom"),
        ("weather.com", "The Weather Channel"), ("espn.com", "ESPN"), ("nba.com", "NBA"),
        ("store.steampowered.com", "Steam"), ("epicgames.com", "Epic Games"), ("roblox.com", "Roblox"),
        ("xbox.com", "Xbox"), ("playstation.com", "PlayStation"), ("nintendo.com", "Nintendo"),
        ("coursera.org", "Coursera"), ("khanacademy.org", "Khan Academy"), ("duolingo.com", "Duolingo"),
        ("deepl.com", "DeepL"), ("wordpress.com", "WordPress"), ("mozilla.org", "Mozilla"), ("proton.me", "Proton"),
    ].map { Site(domain: $0.0, name: $0.1) }
}
