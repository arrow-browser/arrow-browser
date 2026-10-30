import ArrowKit
import Foundation

/// Arc Max features, powered by Arrow Cloud's AI endpoint.
@MainActor
public enum AIFeatures {
    private static func cloud(_ store: BrowserStore) -> ArrowCloud? {
        guard store.settings.aiEnabled, !store.isIncognito, store.cloud.isSignedIn else { return nil }
        return store.cloud
    }

    public static func isAvailable(_ store: BrowserStore) -> Bool { cloud(store) != nil }

    /// Tidy Tab Titles: shortens the title of a newly pinned tab.
    public static func tidyTitle(of tabID: UUID, in store: BrowserStore) {
        guard store.settings.tidyTabTitles, let cloud = cloud(store), let tab = store.state.tab(tabID),
              tab.customTitle == nil, !tab.title.isEmpty else { return }
        Task {
            guard let title = try? await cloud.ai(.tidyTabTitle, prompt: "Title: \(tab.title)\nURL: \(tab.url)"),
                  !title.isEmpty, title.count <= 60 else { return }
            store.update { $0.updateTab(tabID) { $0.customTitle = title } }
        }
    }

    /// Tidy Downloads: renames a finished download with a readable name.
    public static func tidyDownload(_ item: DownloadManager.Item, in store: BrowserStore, rename: @escaping @MainActor (URL) -> Void) {
        guard store.settings.tidyDownloads, let cloud = cloud(store) else { return }
        Task {
            let prompt = "File: \(item.fileName)\nURL: \(item.url)"
            guard let suggestion = try? await cloud.ai(.tidyDownloadName, prompt: prompt) else { return }
            let ext = item.destination.pathExtension
            var base = suggestion
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
            if !ext.isEmpty, base.lowercased().hasSuffix("." + ext.lowercased()) { base = String(base.dropLast(ext.count + 1)) }
            guard !base.isEmpty, base.count <= 120 else { return }
            let target = item.destination.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
            guard !FileManager.default.fileExists(atPath: target.path),
                  (try? FileManager.default.moveItem(at: item.destination, to: target)) != nil else { return }
            rename(target)
        }
    }

    /// Max ▸ Tidy Tabs: sorts the Today tabs of a space by topic.
    public static func canTidy(_ space: Space, store: BrowserStore) -> Bool {
        store.settings.tidyTabs && cloud(store) != nil && space.today.count > 6
    }

    public static func tidyToday(in space: Space, store: BrowserStore) async {
        guard let cloud = cloud(store) else { return }
        let items = space.today
        let prompt = items.enumerated().map { index, node in
            let tab = node.tabs.first
            return "\(index + 1). \(tab?.displayTitle ?? "Split View") — \(tab.flatMap { URLDisplay.host(of: $0.url) } ?? "")"
        }.joined(separator: "\n")
        guard let reply = try? await cloud.ai(.tidyTabs, prompt: prompt),
              let groups = TidyGroups.parse(reply) else { return }
        let order = groups.flatMap { $0 }.compactMap { items.indices.contains($0 - 1) ? items[$0 - 1].id : nil }
        store.update { $0.reorderToday(in: space.id, order: order) }
    }

    /// Text of the page, for questions and summaries.
    private static func pageText(_ tab: WebTab) async -> String {
        let text = await tab.engine?.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String ?? ""
        return String(text.prefix(120_000))
    }

    /// Ask on Page: answers a question about the current page.
    public static func ask(_ question: String, about tab: WebTab, store: BrowserStore) async -> String {
        guard let cloud = cloud(store) else { return "Turn on AI features in Settings ▸ Arrow Cloud." }
        let text = await pageText(tab)
        let prompt = "Page: \(tab.displayTitle)\nURL: \(tab.url)\n\n\(text)\n\nQuestion: \(question)"
        do {
            return try await cloud.ai(.askPage, prompt: prompt) ?? "Arrow can’t help with that."
        } catch {
            return error.localizedDescription
        }
    }

    /// 5-second previews: summary of a page.
    public static func summarize(_ tab: WebTab, store: BrowserStore) async -> String {
        guard let cloud = cloud(store) else { return "Turn on AI features in Settings ▸ Arrow Cloud." }
        let text = await pageText(tab)
        do {
            return try await cloud.ai(.previewSummary, prompt: "Title: \(tab.displayTitle)\nURL: \(tab.url)\n\n\(text)")
                ?? "Arrow can’t summarize this page."
        } catch {
            return error.localizedDescription
        }
    }
}

/// Reply of the tidy-tabs task: {"groups":[{"name":"…","tabs":[1,3]}]}.
public enum TidyGroups {
    public static func parse(_ reply: String) -> [[Int]]? {
        // Models sometimes wrap JSON in a code fence.
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}") else { return nil }
        struct Reply: Decodable {
            struct Group: Decodable { let tabs: [Int] }
            let groups: [Group]
        }
        return (try? JSONDecoder().decode(Reply.self, from: Data(reply[start...end].utf8)))?.groups.map(\.tabs)
    }
}
