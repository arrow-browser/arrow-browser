import Testing
@testable import ArrowKit

struct ContentBlockerTests {
    private let blocker = ContentBlocker(lists: ["""
    [Adblock Plus 2.0]
    ! Title: Test list
    ||doubleclick.net^
    ||ads.example.com^$script,image
    ||tracker.io^$third-party
    ||firstparty-only.com^$~third-party
    ||scoped.com^$domain=news.com
    ||path.com/ads/banner.js
    @@||allowed.doubleclick.net^
    example.org##.ad-banner
    """])

    @Test func compilesHostRulesOnly() {
        #expect(blocker.blockedHosts == ["doubleclick.net", "ads.example.com"])
        #expect(blocker.thirdPartyHosts == ["tracker.io"])
        #expect(blocker.allowedHosts == ["allowed.doubleclick.net"])
    }

    @Test func blocksHostsAndSubdomains() {
        #expect(blocker.shouldBlock(url: "https://stats.g.doubleclick.net/collect", initiator: "https://news.com", isNavigation: false))
        #expect(blocker.shouldBlock(url: "https://ads.example.com/a.js", initiator: nil, isNavigation: false))
        #expect(!blocker.shouldBlock(url: "https://example.com/a.js", initiator: nil, isNavigation: false))
    }

    @Test func honorsExceptionsAndNavigations() {
        #expect(!blocker.shouldBlock(url: "https://allowed.doubleclick.net/x", initiator: nil, isNavigation: false))
        #expect(!blocker.shouldBlock(url: "https://doubleclick.net", initiator: nil, isNavigation: true))
    }

    @Test func thirdPartyRulesSpareFirstPartyRequests() {
        #expect(blocker.shouldBlock(url: "https://cdn.tracker.io/t.js", initiator: "https://news.com", isNavigation: false))
        #expect(!blocker.shouldBlock(url: "https://cdn.tracker.io/t.js", initiator: "https://www.tracker.io", isNavigation: false))
    }

    @Test func listsSuffixes() {
        #expect(ContentBlocker.suffixes(of: "a.b.example.com") == ["a.b.example.com", "b.example.com", "example.com"])
        #expect(ContentBlocker.suffixes(of: "localhost") == ["localhost"])
    }
}
