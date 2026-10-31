import Foundation
import Testing
@testable import ArrowKit

struct CommandBarTests {
    private let ranker = CommandBarRanker(engine: .google)

    @Test func emptyQueryListsRecentTabsExceptCurrent() {
        let now = Date()
        let current = Tab(url: "https://current.com", title: "Current", lastActiveAt: now)
        let older = Tab(url: "https://older.com", title: "Older", lastActiveAt: now.addingTimeInterval(-60))
        let recent = Tab(url: "https://recent.com", title: "Recent", lastActiveAt: now.addingTimeInterval(-10))
        let items = ranker.items(for: "", openTabs: [current, older, recent].map { CommandBarTab(tab: $0, spaceTitle: nil) },
                                 history: History(), suggestions: [], commands: [], currentTabID: current.id)
        #expect(items.map(\.title) == ["Recent", "Older"])
    }

    @Test func searchComesFirstThenTabsHistorySuggestionsAndCommands() {
        var history = History()
        history.recordVisit(url: "https://swift.org/documentation", title: "Swift Documentation")
        let tab = Tab(url: "https://developer.apple.com/swift", title: "Swift - Apple Developer")
        let commands = [CommandBarCommand(id: "copy-url", title: "Copy URL", keywords: ["swift"], symbol: "link")]
        let items = ranker.items(for: "swift", openTabs: [CommandBarTab(tab: tab, spaceTitle: "Work")], history: history,
                                 suggestions: ["swift", "swift ui", "swiftly"], commands: commands)

        #expect(items.first?.kind == .search(query: "swift"))
        #expect(items.contains { $0.kind == .switchToTab(tab.id) })
        #expect(items.contains { $0.kind == .open(url: "https://swift.org/documentation") })
        #expect(items.contains { $0.kind == .search(query: "swift ui") })
        #expect(!items.dropFirst().contains { $0.kind == .search(query: "swift") })
        #expect(items.last?.kind == .command("copy-url"))
    }

    @Test func typedAddressNavigatesAndDeduplicatesHistory() {
        var history = History()
        history.recordVisit(url: "https://github.com", title: "GitHub")
        let items = ranker.items(for: "github.com", openTabs: [], history: history, suggestions: [], commands: [])
        #expect(items.first?.kind == .navigate(url: "https://github.com"))
        #expect(!items.contains { $0.kind == .open(url: "https://github.com") })
    }

    @Test func offersSiteSearchInTheFieldAndRunsIt() throws {
        #expect(ranker.siteSearchHint(for: "youtube")?.name == "YouTube")
        #expect(ranker.siteSearchHint(for: "youtube music") == nil)
        let rows = ranker.items(for: "youtube", openTabs: [], history: History(), suggestions: [], commands: [])
        #expect(!rows.contains { $0.actionLabel == "Tab" })

        let site = try #require(SiteSearch.matching("youtube"))
        let items = ranker.items(for: "lofi", activeSiteSearch: site, openTabs: [], history: History(), suggestions: [],
                                 commands: [])
        #expect(items.first?.kind == .siteSearch(site, query: "lofi"))
        #expect(site.searchURL(for: "lofi beats") == "https://www.youtube.com/results?search_query=lofi+beats")
    }

    @Test func completesTypedAddressFromHistoryAndListsItFirst() throws {
        var history = History()
        history.recordVisit(url: "https://github.com/euskadi31", title: "euskadi31")
        history.recordVisit(url: "https://www.swift.org/", title: "Swift")
        let completion = try #require(ranker.completion(for: "Sw", history: history))
        #expect(completion.text == "Swift.org")
        #expect(completion.url == "https://www.swift.org/")
        #expect(ranker.completion(for: "github.com/euskadi31", history: history) == nil)
        #expect(ranker.completion(for: "swift tutorial", history: history) == nil)
        #expect(ranker.completion(for: "gitlab", history: history) == nil)

        let items = ranker.items(for: "Sw", completion: completion, openTabs: [], history: history, suggestions: [],
                                 commands: [])
        #expect(items.first?.kind == .open(url: "https://www.swift.org/"))
        #expect(items.dropFirst().first?.kind == .search(query: "Sw"))
        #expect(items.filter { $0.url == "https://www.swift.org/" }.count == 1)
    }

    @Test func parsesSuggestionPayloads() throws {
        let google = Data(#"["swi",["swift","swiss"],[],{}]"#.utf8)
        #expect(SearchSuggestions.parse(google) == ["swift", "swiss"])
        let duck = Data(#"[{"phrase":"arc"},{"phrase":"arrow"}]"#.utf8)
        #expect(SearchSuggestions.parse(duck) == ["arc", "arrow"])
        // Google's ISO-8859-1 answer when a suggestion has an accent.
        let latin1 = try #require(#"["traduction",["traduction français"]]"#.data(using: .isoLatin1))
        #expect(SearchSuggestions.parse(latin1) == ["traduction français"])
    }
}

struct HistoryTests {
    @Test func ranksByPrefixThenFrecency() {
        var history = History()
        let now = Date()
        history.recordVisit(url: "https://news.ycombinator.com", title: "Hacker News", at: now)
        for _ in 0..<5 { history.recordVisit(url: "https://example.com/news", title: "Example news", at: now) }
        let results = history.search("news", now: now)
        #expect(results.first?.url == "https://news.ycombinator.com")
        #expect(results.count == 2)
    }

    @Test func ignoresNonWebAddresses() {
        var history = History()
        history.recordVisit(url: "arrow://note/1", title: "Note")
        history.recordVisit(url: "about:blank", title: "")
        #expect(history.entries.isEmpty)
    }
}

struct AirTrafficControlTests {
    @Test func routesByRule() {
        let work = UUID()
        var settings = ArrowSettings()
        settings.airTrafficRules = [
            AirTrafficRule(condition: .hostIs, value: "github.com", spaceID: work),
            AirTrafficRule(condition: .urlContains, value: "figma", spaceID: work),
        ]
        #expect(settings.route("https://gist.github.com/x") == work)
        #expect(settings.route("https://www.figma.com/file/1") == work)
        #expect(settings.route("https://notgithub.com") == nil)
    }

    @Test func decodesOlderSettingsLeniently() throws {
        let data = Data(#"{"searchEngine":"kagi","unknown":1}"#.utf8)
        let settings = try JSONDecoder().decode(ArrowSettings.self, from: data)
        #expect(settings.searchEngine == .kagi)
        #expect(settings.archiveInterval == .twelveHours)
        #expect(settings.automaticallyInstallUpdates)
        #expect(settings.contentAppearance == .automatic)
        #expect(!settings.allowJavaScriptFromAppleEvents)
        #expect(settings.littleArrowArchive == .sixHours && settings.downloadLocation == .downloads)
        #expect(settings.searchSuggestions && settings.restoreWindows && settings.customShortcuts.isEmpty)
    }

    @Test func roundTripsNewPreferences() throws {
        var settings = ArrowSettings()
        settings.documentApp = .notion
        settings.downloadLocation = .folder
        settings.downloadFolder = "/tmp/x"
        settings.customShortcuts = ["Tabs/Clear Today": "⇧⌘J"]
        let decoded = try JSONDecoder().decode(ArrowSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(DocumentApp.notion.newDocumentURL == "https://notion.new")
        #expect(LittleArrowArchive.never.seconds == nil)
    }
}

struct BoostTests {
    @Test func appliesToDomainAndSubdomains() {
        let boost = Boost(name: "GitHub", domain: "github.com")
        #expect(boost.applies(to: "https://github.com/x"))
        #expect(boost.applies(to: "https://gist.github.com"))
        #expect(!boost.applies(to: "https://notgithub.com"))
    }

    @Test func generatesStylesheetAndSafeScript() {
        let boost = Boost(name: "Test", domain: "a.com", hueRotation: 90, fontFamily: "Avenir",
                          zappedSelectors: [".ads", "bad { }"], css: "body { margin: 0 }")
        let css = boost.generatedCSS
        #expect(css.contains("hue-rotate(90deg)"))
        #expect(css.contains("\"Avenir\""))
        #expect(css.contains(".ads { display: none !important; }"))
        #expect(!css.contains("bad {"))
        #expect(boost.injectionScript.contains("arrow-boost-"))

        let hostile = Boost(name: "x", domain: "a.com", css: "</style><script>alert(1)</script>")
        #expect(!hostile.injectionScript.contains("</script>"))
    }
}

struct ThemeTests {
    @Test func convertsBetweenRGBAndHSB() {
        let color = RGBColor(hex: 0x9A8CFF)
        let hsb = color.hsb
        let back = RGBColor(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness)
        #expect(abs(back.red - color.red) < 0.001)
        #expect(abs(back.green - color.green) < 0.001)
        #expect(abs(back.blue - color.blue) < 0.001)
        #expect(color.hexString == "#9A8CFF")
    }

    @Test func harmonyGeneratesGradientStops() {
        #expect(SpaceTheme(primary: .white, harmony: .triadic).colors.count == 3)
        #expect(SpaceTheme(primary: .white, harmony: .single).colors.count == 1)
    }

    @Test func lightPaletteMatchesArcDefaultTheme() {
        let palette = SpaceTheme.lavender.palette(isDark: false)
        // Measured on Arc: #E9E7FF at the top left, #FDEFF4 at the bottom right.
        let expected: [(Double, Double, Double)] = [(0xE9, 0xE7, 0xFF), (0xFD, 0xEF, 0xF4)]
        for (stop, target) in zip(palette.backgroundStops, expected) {
            #expect(abs(stop.red * 255 - target.0) < 3)
            #expect(abs(stop.green * 255 - target.1) < 3)
            #expect(abs(stop.blue * 255 - target.2) < 3)
        }
        #expect(palette.title.luminance < 0.05)
        // The command bar selection, measured on Arc.
        #expect(palette.accent == RGBColor(hex: 0xA4A9FF))
    }

    @Test func darkPaletteHasLightText() {
        let palette = SpaceTheme.lavender.palette(isDark: true)
        #expect(palette.title.luminance > 0.7)
        #expect(SpaceTheme.lavender.isDark(systemIsDark: true))
        #expect(!SpaceTheme(primary: .white, appearance: .light).isDark(systemIsDark: true))
    }
}

struct EaselTests {
    @Test func framesStrokesAroundTheirPoints() throws {
        let points = [EaselPoint(x: 10, y: 20), EaselPoint(x: 50, y: 5), EaselPoint(x: 30, y: 40)]
        let item = try #require(EaselItem.stroke(points, color: .black, lineWidth: 4, isHighlighter: false))
        #expect(item.x == 6 && item.y == 1)
        #expect(item.width == 48 && item.height == 43)
        guard case let .stroke(relative, _, _, _) = item.content else {
            Issue.record("expected a stroke")
            return
        }
        #expect(relative.first == EaselPoint(x: 4, y: 19))
        #expect(EaselItem.stroke([], color: .black, lineWidth: 2, isHighlighter: false) == nil)
    }

    @Test func roundTripsStrokesThroughJSON() throws {
        let item = try #require(EaselItem.stroke([EaselPoint(x: 0, y: 0), EaselPoint(x: 3, y: 4)],
                                                 color: RGBColor(hex: 0xFF0000), lineWidth: 3, isHighlighter: true))
        let decoded = try JSONDecoder().decode(EaselItem.self, from: JSONEncoder().encode(item))
        #expect(decoded == item)
    }
}

struct AutofillTests {
    @Test func validatesAndDescribesCards() {
        #expect(PaymentCard.isValidNumber("4242 4242 4242 4242"))
        #expect(!PaymentCard.isValidNumber("4242 4242 4242 4241"))
        #expect(!PaymentCard.isValidNumber("1234"))
        let card = PaymentCard(holder: "Ada Lovelace", number: "5555-5555-5555-4444", expiryMonth: 7, expiryYear: 29)
        #expect(card.brand == .mastercard && card.label == "Mastercard •••• 4444")
        #expect(card.expiry == "07/29" && card.expiryYear == 2029)
        #expect(PaymentCard(holder: "", number: "378282246310005", expiryMonth: 1, expiryYear: 2030).brand == .amex)
        #expect(PaymentCard.parseExpiry("7 / 2031")! == (7, 2031))
        #expect(PaymentCard.parseExpiry("13/29") == nil)
    }

    @Test func offersTranslationOnlyForUnknownLanguages() {
        let url = "https://www.lemonde.fr/article"
        #expect(PageTranslation.shouldOffer(pageLanguage: "fr-FR", userLanguages: ["en-US"], url: url, neverLanguages: [], neverSites: []))
        #expect(!PageTranslation.shouldOffer(pageLanguage: "fr", userLanguages: ["en-US", "fr-FR"], url: url, neverLanguages: [], neverSites: []))
        #expect(!PageTranslation.shouldOffer(pageLanguage: "fr", userLanguages: ["en"], url: url, neverLanguages: ["fr"], neverSites: []))
        #expect(!PageTranslation.shouldOffer(pageLanguage: "fr", userLanguages: ["en"], url: url, neverLanguages: [], neverSites: ["lemonde.fr"]))
        #expect(!PageTranslation.shouldOffer(pageLanguage: nil, userLanguages: ["en"], url: url, neverLanguages: [], neverSites: []))
        #expect(!PageTranslation.shouldOffer(pageLanguage: "fr", userLanguages: ["en"], url: "arrow://note/1", neverLanguages: [], neverSites: []))
    }
}
