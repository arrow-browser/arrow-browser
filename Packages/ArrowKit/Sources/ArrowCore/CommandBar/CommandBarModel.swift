import ArrowKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation

/// State of an open command bar: input, rows and keyboard selection.
@MainActor
@Observable
public final class CommandBarModel {
    public enum Mode: Equatable {
        /// Cmd+T: results open in a new tab.
        case newTab
        /// Cmd+L / URL field: results replace the current tab's page.
        case editCurrent(tabID: UUID)
        /// Choose the page of a new split pane.
        case splitPane(besideTabID: UUID)
    }

    public enum Anchor {
        case center
        /// Dropped down from the sidebar URL field.
        case sidebar
    }

    public let mode: Mode
    public let anchor: Anchor
    /// Content of the field: what was typed, plus the inline completion.
    public var text: String {
        didSet { if text != oldValue { textDidChange() } }
    }

    /// Selection of the field (an empty range is the insertion point); covers
    /// the completed part of `text`.
    public var selectedRange: Range<String.Index>?
    /// What the user typed, without the completion.
    public private(set) var typedText: String
    public private(set) var completion: CommandBarCompletion?
    @ObservationIgnored private var isCompleting = false

    public var activeSiteSearch: SiteSearch? {
        didSet { refresh() }
    }

    public private(set) var items: [CommandBarItem] = []
    public var selectedIndex = 0

    @ObservationIgnored private var suggestions: [String] = []
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?
    @ObservationIgnored private let sources: Sources

    /// Data the ranking reads from the browser.
    public struct Sources {
        public var openTabs: () -> [CommandBarTab]
        public var history: () -> History
        public var commands: [CommandBarCommand]
        public var engine: () -> SearchEngine
        public var settings: () -> ArrowSettings
        public var currentTabID: UUID?
        /// The platform's completion of typed text history does not complete
        /// (Arc on Windows completes well-known sites: "transl" →
        /// translate.google.com).
        public var fallbackCompletion: (String) -> CommandBarCompletion? = { _ in nil }
        /// The platform's order of the ranked rows for the typed text (Arc on
        /// Windows shows five, its commands among the first).
        public var arrange: ([CommandBarItem], String) -> [CommandBarItem] = { items, _ in items }

        public init(openTabs: @escaping () -> [CommandBarTab], history: @escaping () -> History,
                    commands: [CommandBarCommand], engine: @escaping () -> SearchEngine,
                    settings: @escaping () -> ArrowSettings, currentTabID: UUID?) {
            self.openTabs = openTabs
            self.history = history
            self.commands = commands
            self.engine = engine
            self.settings = settings
            self.currentTabID = currentTabID
        }
    }

    public init(mode: Mode, anchor: Anchor, initialText: String = "", sources: Sources) {
        self.mode = mode
        self.anchor = anchor
        text = initialText
        typedText = initialText
        self.sources = sources
        refresh()
    }

    private var ranker: CommandBarRanker {
        // Max ▸ ChatGPT in the Command Bar: "chatgpt", then Tab.
        CommandBarRanker(engine: sources.engine(),
                         siteSearches: SiteSearch.builtIn + (sources.settings().chatGPTInCommandBar ? [.chatGPT] : []))
    }

    /// "Search YouTube  Tab", shown at the end of the field.
    public var siteSearchHint: SiteSearch? {
        activeSiteSearch == nil ? ranker.siteSearchHint(for: typedText) : nil
    }

    public var selectedItem: CommandBarItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    public var placeholder: String {
        if let activeSiteSearch { return "Search \(activeSiteSearch.name)…" }
        return "Search or Enter URL…"
    }

    public func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
    }

    /// Tab accepts the site search hint ("youtube" + Tab → Search YouTube).
    public func acceptSiteSearchHint() -> Bool {
        guard let site = siteSearchHint else { return false }
        activeSiteSearch = site
        text = ""
        return true
    }

    public func clearSiteSearch() {
        activeSiteSearch = nil
    }

    /// Typing forward completes the address from history, as in Arc;
    /// deleting does not, so the completion can be removed.
    private func textDidChange() {
        guard !isCompleting else { return }
        let typedForward = text.count > typedText.count && text.lowercased().hasPrefix(typedText.lowercased())
        typedText = text
        completion = typedForward && activeSiteSearch == nil
            ? ranker.completion(for: text, history: sources.history()) ?? sources.fallbackCompletion(text) : nil
        if let completion {
            isCompleting = true
            text = completion.text
            isCompleting = false
            selectedRange = text.index(text.startIndex, offsetBy: typedText.count)..<text.endIndex
        }
        selectedIndex = 0
        refresh()
    }

    private func refresh() {
        rank()
        fetchSuggestions()
    }

    private func rank() {
        items = ranker.items(for: typedText, activeSiteSearch: activeSiteSearch, completion: completion,
                             openTabs: sources.openTabs(), history: sources.history(), suggestions: suggestions,
                             commands: sources.commands, currentTabID: sources.currentTabID)
        let query = typedText.trimmingCharacters(in: .whitespaces)
        if sources.settings().chatGPTInCommandBar, activeSiteSearch == nil, !query.isEmpty {
            // Max ▸ ChatGPT in the Command Bar, as a search suggestion.
            let row = CommandBarItem(id: "chatgpt", kind: .siteSearch(.chatGPT, query: query), title: query,
                                     subtitle: "Ask ChatGPT", url: "https://chatgpt.com")
            items.insert(row, at: min(items.count, completion == nil ? 1 : 2))
        }
        if activeSiteSearch == nil { items = sources.arrange(items, typedText) }
        selectedIndex = min(selectedIndex, max(items.count - 1, 0))
        if typedText.isEmpty { selectedIndex = 0 }
    }

    /// Max ▸ Instant Links: Shift-Return opens the top result of a web search.
    public var instantLinkURL: String? {
        guard sources.settings().instantLinks, activeSiteSearch == nil else { return nil }
        let query: String
        if case let .search(selected)? = selectedItem?.kind {
            query = selected
        } else {
            query = typedText.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty, case .search = URLInput.parse(query) else { return nil }
        }
        return sources.engine().topResultURL(for: query)
    }

    private func fetchSuggestions() {
        suggestionTask?.cancel()
        let query = typedText.trimmingCharacters(in: .whitespaces)
        guard sources.settings().searchSuggestions, !query.isEmpty, case .search = URLInput.parse(query),
              let address = sources.engine().suggestionURL(for: query), let url = URL(string: address) else {
            suggestions = []
            return
        }
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            guard let (data, _) = try? await URLSession.shared.data(for: request), !Task.isCancelled else { return }
            guard let self else { return }
            suggestions = SearchSuggestions.parse(data)
            rank()
        }
    }
}
