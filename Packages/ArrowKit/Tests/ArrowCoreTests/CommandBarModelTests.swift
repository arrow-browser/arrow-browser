import ArrowKit
import Foundation
import Testing
@testable import ArrowCore

@MainActor
struct CommandBarModelTests {
    private var history = History()
    private var settings = ArrowSettings()

    init() {
        history.recordVisit(url: "https://www.swift.org/", title: "Swift")
        // No network in tests.
        settings.searchSuggestions = false
    }

    private func makeModel(initialText: String = "", tabs: [Tab] = [], currentTabID: UUID? = nil,
                           settings: ArrowSettings? = nil) -> CommandBarModel {
        let history = history
        let settings = settings ?? self.settings
        let sources = CommandBarModel.Sources(
            openTabs: { tabs.map { CommandBarTab(tab: $0, spaceTitle: nil) } },
            history: { history },
            commands: [],
            engine: { settings.searchEngine },
            settings: { settings },
            currentTabID: currentTabID
        )
        return CommandBarModel(mode: .newTab, anchor: .center, initialText: initialText, sources: sources)
    }

    @Test func typingForwardCompletesFromHistoryAndSelectsTheCompletion() throws {
        let model = makeModel()
        model.text = "Sw"
        #expect(model.text == "Swift.org")
        #expect(model.typedText == "Sw")
        #expect(model.completion?.url == "https://www.swift.org/")
        let range = try #require(model.selectedRange)
        #expect(model.text[range] == "ift.org")
        #expect(model.items.first?.kind == .open(url: "https://www.swift.org/"))
        #expect(model.selectedIndex == 0)
    }

    @Test func deletingDoesNotComplete() {
        let model = makeModel()
        model.text = "Sw"
        model.text = "S"
        #expect(model.text == "S")
        #expect(model.completion == nil)
        #expect(model.items.first?.kind == .search(query: "S"))
    }

    @Test func tabAcceptsTheSiteSearchHint() {
        let model = makeModel()
        model.text = "youtube"
        #expect(model.siteSearchHint?.name == "YouTube")
        #expect(model.acceptSiteSearchHint())
        #expect(model.activeSiteSearch?.name == "YouTube")
        #expect(model.text.isEmpty)
        #expect(model.siteSearchHint == nil)
        #expect(model.placeholder == "Search YouTube…")

        model.text = "lofi"
        #expect(model.items.first?.kind == .siteSearch(model.activeSiteSearch!, query: "lofi"))
        model.clearSiteSearch()
        #expect(model.activeSiteSearch == nil)
        #expect(model.placeholder == "Search or Enter URL…")
    }

    @Test func selectionWrapsAround() {
        let now = Date()
        let tabs = [
            Tab(url: "https://a.com", title: "A", lastActiveAt: now),
            Tab(url: "https://b.com", title: "B", lastActiveAt: now.addingTimeInterval(-10)),
        ]
        let model = makeModel(tabs: tabs)
        #expect(model.items.count == 2)
        model.moveSelection(-1)
        #expect(model.selectedIndex == 1)
        model.moveSelection(1)
        #expect(model.selectedIndex == 0)
        #expect(model.selectedItem?.title == "A")
    }

    @Test func instantLinksNeedTheSetting() {
        let model = makeModel(initialText: "swift concurrency")
        #expect(model.instantLinkURL == nil)

        var settings = settings
        settings.instantLinks = true
        let enabled = makeModel(initialText: "swift concurrency", settings: settings)
        #expect(enabled.instantLinkURL == settings.searchEngine.topResultURL(for: "swift concurrency"))
    }
}
