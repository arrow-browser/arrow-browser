import ArrowKit
import Foundation
import Testing
@testable import ArrowCore

@MainActor
struct BrowserStoreTests {
    @Test func tabsGetABrowserFromTheirProfile() throws {
        let browser = try TestBrowser()
        let (tab, engine) = try browser.openTab("https://example.com")
        #expect(browser.store.tabs[tab.id] === tab)
        #expect(engine.context === browser.runtime.defaultProfile)
        #expect(engine.loadedURLs == ["https://example.com"])
        #expect(engine.delegate === tab)
    }

    @Test func closingATodayTabArchivesItAndClosesItsBrowser() throws {
        let browser = try TestBrowser()
        let (tab, engine) = try browser.openTab("https://example.com")
        browser.store.close(tab.id)
        #expect(browser.store.state.location(of: tab.id) == nil)
        #expect(browser.store.state.archive.contains { $0.tab.id == tab.id })
        #expect(browser.store.tabs[tab.id] == nil)
        #expect(engine.isClosed)
        #expect(!tab.isEngineLoaded)
    }

    @Test func savedSidebarIsLoadedAgain() throws {
        let browser = try TestBrowser()
        let (tab, _) = try browser.openTab("https://example.com")
        browser.store.saveNow()
        let reopened = BrowserStore(engine: browser.runtime, platform: browser.platform)
        #expect(reopened.state.tab(tab.id)?.url == "https://example.com")
    }

    @Test func profilesHaveTheirOwnContexts() throws {
        let browser = try TestBrowser()
        let store = browser.store
        let profile = Profile(name: "Work")
        store.update { $0.profiles.append(profile) }
        let work = try #require(store.requestContext(for: profile.id) as? FakeContext)
        #expect(work.path == browser.directory.appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profile.id.uuidString, isDirectory: true))
        #expect(store.requestContext(for: profile.id) === work)
        #expect(store.requestContext(for: store.state.defaultProfile.id) === browser.runtime.defaultProfile)

        store.clearBrowsingData(since: nil, history: false, cookies: true, cache: true)
        for context in [work, browser.runtime.defaultProfile] {
            #expect(context.deletedCookies == [nil])
            #expect(context.cacheClears == 1)
        }
    }

    @Test func incognitoStoresUseAnIncognitoContextAndKeepNoHistory() throws {
        let browser = try TestBrowser()
        let incognito = BrowserStore(incognitoWith: browser.store.settings, downloads: browser.store.downloads,
                                     engine: browser.runtime, platform: browser.platform)
        let space = incognito.state.spaces[0]
        let tab = try #require(incognito.openTab(url: "https://example.com", in: space.id))
        #expect(incognito.requestContext(for: tab.profileID).isIncognito)

        incognito.recordVisit(url: "https://example.com", title: "Example", incognito: tab.isIncognito)
        #expect(incognito.history.search("example").isEmpty)
    }

    @Test func settingsTheAppAppliesReachThePlatformExceptInIncognito() throws {
        let browser = try TestBrowser()
        browser.store.settings.littleArrowShortcut.toggle()
        #expect(browser.platform.appliedSettings.count == 1)

        let incognito = BrowserStore(incognitoWith: browser.store.settings, downloads: browser.store.downloads,
                                     engine: browser.runtime, platform: browser.platform)
        incognito.settings.littleArrowShortcut.toggle()
        #expect(browser.platform.appliedSettings.count == 1)
    }

    @Test func soundsFollowTheSetting() throws {
        let browser = try TestBrowser()
        browser.store.settings.soundEffects = false
        browser.store.playSound(.event)
        browser.store.settings.soundEffects = true
        browser.store.playSound(.capture)
        #expect(browser.platform.sounds == [.capture])
    }
}
