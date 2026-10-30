import ArrowKit
import Foundation
import Testing
@testable import ArrowCore

@MainActor
struct WebTabTests {
    @Test func pageEventsUpdateTheTabTheSidebarAndHistory() throws {
        let browser = try TestBrowser()
        let (tab, engine) = try browser.openTab("https://example.com")
        tab.browser(engine, didChangeAddress: "https://example.com/page")
        tab.browser(engine, didChangeTitle: "A page")
        tab.browser(engine, didFinishLoad: "https://example.com/page", httpStatusCode: 200)

        #expect(tab.url == "https://example.com/page")
        #expect(tab.displayTitle == "A page")
        #expect(browser.store.state.tab(tab.id)?.title == "A page")
        #expect(browser.store.history.search("A page").first?.url == "https://example.com/page")
    }

    @Test func modifiedLinkClicksOpenLittleArrowOrPeek() throws {
        let browser = try TestBrowser()
        let (tab, engine) = try browser.openTab("https://example.com")
        let host = FakeTabHost()
        tab.host = host

        browser.platform.heldModifiers = [.command, .option]
        #expect(tab.browser(engine, openURL: "https://a.com", disposition: .newForegroundTab))
        browser.platform.heldModifiers = [.shift]
        #expect(tab.browser(engine, openURL: "https://b.com", disposition: .newForegroundTab))
        browser.platform.heldModifiers = []
        #expect(tab.browser(engine, openURL: "https://c.com", disposition: .newBackgroundTab))
        #expect(!tab.browser(engine, openURL: "https://d.com", disposition: .currentTab))

        #expect(host.littleArrow == ["https://a.com"])
        #expect(host.peeked == ["https://b.com"])
        #expect(host.opened.map(\.url) == ["https://c.com"])
        #expect(host.opened.first?.inBackground == true)
    }

    @Test func contextMenuCopiesGoToTheClipboard() throws {
        let browser = try TestBrowser()
        let (tab, engine) = try browser.openTab("https://example.com")
        let params = ContextMenuParams(linkURL: "https://link.com", sourceURL: "", pageURL: tab.url, frameURL: tab.url,
                                       selectionText: "", titleText: "", isEditable: false, mediaType: .none,
                                       location: CGPoint(x: 0, y: 0))
        let items = tab.browser(engine, contextMenuItemsFor: params)
        guard case let .item(copyLink, "Copy Link")? = items.first(where: {
            if case .item(_, "Copy Link") = $0 { true } else { false }
        }) else {
            Issue.record("No Copy Link item")
            return
        }
        tab.browser(engine, didSelectContextMenuItem: copyLink, params: params)
        #expect(browser.platform.clipboard == ["https://link.com"])
    }

    @Test func consoleMessagesReportMediaPlayback() throws {
        let browser = try TestBrowser()
        let (tab, engine) = try browser.openTab("https://example.com")
        #expect(tab.browser(engine, consoleMessage: "__arrow_media__:1"))
        #expect(tab.isPlayingMedia)
        #expect(tab.browser(engine, consoleMessage: "__arrow_media__:0"))
        #expect(!tab.isPlayingMedia)
        #expect(!tab.browser(engine, consoleMessage: "hello"))
    }

    @Test func reloadingACrashedTabCreatesANewBrowser() throws {
        let browser = try TestBrowser()
        let (tab, engine) = try browser.openTab("https://example.com")
        tab.browser(engine, rendererDidTerminate: .crashed)
        #expect(tab.crash == .crashed)

        tab.reload()
        #expect(engine.isClosed)
        #expect(tab.crash == nil)
        #expect(browser.runtime.defaultProfile.browsers.count == 2)
        #expect(tab.engine === browser.runtime.defaultProfile.browsers.last)
    }

    @Test func themeIsSharedWithWebsitesInTheSystemAppearance() throws {
        let browser = try TestBrowser()
        browser.store.settings.shareThemeWithWebsites = true
        browser.store.settings.sharedQuotes = false
        let (tab, engine) = try browser.openTab("https://example.com")
        browser.platform.isDarkAppearance = true
        tab.applyPageFeatures(engine)
        let space = try #require(browser.store.state.spaces.first)
        let palette = space.theme.palette(isDark: space.theme.isDark(systemIsDark: true))
        #expect(engine.scripts.last?.contains("'--arc-palette-focus', '\(palette.accent.hexString)'") == true)
    }

    @Test func submittedLoginsAreOfferedThenSaved() throws {
        let browser = try TestBrowser()
        let (tab, _) = try browser.openTab("https://example.com/login")
        #expect(tab.handleAutofillMessage(#"__arrow_login__:{"username":"ada","password":"secret"}"#))
        guard case .savePassword("example.com", "ada", "secret")? = tab.offer?.kind else {
            Issue.record("No save offer: \(tab.offerDescription)")
            return
        }
        tab.acceptOffer()
        #expect(browser.platform.credentials.password(host: "example.com", username: "ada") == "secret")
        #expect(tab.offer == nil)

        // The same login again is not offered.
        #expect(tab.handleAutofillMessage(#"__arrow_login__:{"username":"ada","password":"secret"}"#))
        #expect(tab.offer == nil)
    }
}
