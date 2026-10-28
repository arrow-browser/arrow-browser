import Testing
@testable import ArrowKit

struct URLInputTests {
    @Test(arguments: [
        ("github.com", "https://github.com"),
        ("github.com/euskadi31", "https://github.com/euskadi31"),
        ("https://example.org/a?b=c", "https://example.org/a?b=c"),
        ("localhost:3000", "http://localhost:3000"),
        ("127.0.0.1:8080/health", "http://127.0.0.1:8080/health"),
        ("arrow://note/123", "arrow://note/123"),
        ("about:blank", "about:blank"),
        ("sub.domain.co.uk", "https://sub.domain.co.uk"),
    ])
    func parsesAddresses(input: String, expected: String) {
        #expect(URLInput.parse(input) == .url(expected))
    }

    @Test(arguments: ["swift concurrency", "hello", "what is 2.5", "1.5", "node.js tutorial", "foo."])
    func parsesSearches(input: String) {
        #expect(URLInput.parse(input) == .search(input))
    }

    @Test func resolvesSearchWithEngine() {
        #expect(URLInput.resolve("swift ui", engine: .google) == "https://www.google.com/search?q=swift+ui")
        #expect(URLInput.resolve("a&b", engine: .duckDuckGo) == "https://duckduckgo.com/?q=a%26b")
    }

    @Test func buildsInstantLinkAddresses() {
        #expect(SearchEngine.google.topResultURL(for: "swift book") == "https://www.google.com/search?btnI=1&q=swift+book")
        #expect(SearchEngine.kagi.topResultURL(for: "swift") == "https://duckduckgo.com/?q=%5Cswift")
        #expect(SiteSearch.chatGPT.searchURL(for: "hi there") == "https://chatgpt.com/?q=hi+there")
    }

    @Test func recognizesSearchResultsPage() {
        #expect(SearchEngine.google.query(fromSearchURL: "https://www.google.com/search?q=arc+browser") == "arc browser")
        #expect(SearchEngine.google.query(fromSearchURL: "https://github.com") == nil)
    }

    @Test func displaysShortAndFullAddresses() {
        #expect(URLDisplay.short("https://www.github.com/euskadi31") == "github.com")
        #expect(URLDisplay.full("https://www.github.com/euskadi31/") == "github.com/euskadi31")
        #expect(URLDisplay.normalized("https://www.Example.com/a/#top") == URLDisplay.normalized("https://example.com/a"))
        #expect(URLDisplay.isSameSite("https://mail.google.com", "https://docs.google.com"))
        #expect(!URLDisplay.isSameSite("https://google.com", "https://github.com"))
        #expect(URLDisplay.registrableDomain("a.b.example.co.uk") == "example.co.uk")
    }

    @Test func matchesSiteSearchKeyword() {
        #expect(SiteSearch.matching("yout")?.name == "YouTube")
        #expect(SiteSearch.matching("y") == nil)
        #expect(SiteSearch.matching("zzz") == nil)
    }

    @Test func buildsTranslationProxyURLs() {
        #expect(PageTranslation.url(for: "https://www.my-site.co.uk/a?b=1", to: "fr")
                    == "https://www-my--site-co-uk.translate.goog/a?b=1&_x_tr_sl=auto&_x_tr_tl=fr&_x_tr_hl=fr")
        #expect(PageTranslation.url(for: "arrow://note/1", to: "fr") == nil)
        #expect(PageTranslation.url(for: "https://x-com.translate.goog/", to: "fr") == nil)
    }

    @Test func parsesInternalPages() {
        let id = UUID()
        #expect(InternalPage(url: "arrow://note/\(id.uuidString)") == .note(id))
        #expect(InternalPage(url: "arrow://newtab") == .newTab)
        #expect(InternalPage(url: "https://example.com") == nil)
    }
}

import Foundation
