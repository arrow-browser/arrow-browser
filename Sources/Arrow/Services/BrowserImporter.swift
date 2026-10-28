import AppKit
import ArrowKit

/// Imports spaces, pinned tabs and favorites from Arc, and bookmarks from
/// Safari when readable.
@MainActor
struct BrowserImporter {
    let store: BrowserStore

    enum Source: Hashable {
        case arc
        case chromium(name: String, directory: String)
        case safari

        var name: String {
            switch self {
            case .arc: "Arc"
            case let .chromium(name, _): name
            case .safari: "Safari"
            }
        }
    }

    /// Browsers whose data exists on this Mac.
    static func availableSources() -> [Source] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var sources: [Source] = []
        if FileManager.default.fileExists(atPath: support.appendingPathComponent("Arc/StorableSidebar.json").path) {
            sources.append(.arc)
        }
        for browser in chromiumBrowsers
        where FileManager.default.fileExists(atPath: support.appendingPathComponent(browser.directory).appendingPathComponent("Default/Bookmarks").path) {
            sources.append(.chromium(name: browser.name, directory: browser.directory))
        }
        sources.append(.safari)
        return sources
    }

    /// Imports one source; returns a summary or nil when nothing was found.
    func importData(from source: Source) -> String? {
        switch source {
        case .arc: importArc()
        case let .chromium(name, directory): importChromiumBookmarks(name: name, directory: directory)
        case .safari: importSafariBookmarks()
        }
    }

    private static let chromiumBrowsers: [(name: String, directory: String)] = [
        ("Chrome", "Google/Chrome"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Edge", "Microsoft Edge"),
        ("Vivaldi", "Vivaldi"),
        ("Chromium", "Chromium"),
    ]

    /// Imports a Chromium browser's bookmarks bar as a pinned folder.
    func importChromiumBookmarks(name: String, directory: String) -> String? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directory).appendingPathComponent("Default/Bookmarks")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { return nil }

        func nodes(_ value: Any?) -> [SidebarNode] {
            Self.objects((value as? [String: Any])?["children"]).compactMap { item in
                switch item["type"] as? String {
                case "url":
                    guard let address = item["url"] as? String, address.hasPrefix("http") else { return nil }
                    return .tab(Tab(url: address, title: item["name"] as? String ?? "", pinnedURL: address))
                case "folder":
                    let children = nodes(item)
                    return children.isEmpty ? nil : .folder(Folder(title: item["name"] as? String ?? "Folder", isExpanded: false, children: children))
                default:
                    return nil
                }
            }
        }
        let bar = nodes(roots["bookmark_bar"]) + nodes(roots["other"])
        guard !bar.isEmpty else { return nil }
        return addImportedFolder(title: "\(name) Bookmarks", children: bar, source: name)
    }

    /// Imports Safari's bookmarks (needs Full Disk Access to read them).
    func importSafariBookmarks() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }

        func nodes(_ item: [String: Any]) -> [SidebarNode] {
            Self.objects(item["Children"]).compactMap { child in
                switch child["WebBookmarkType"] as? String {
                case "WebBookmarkTypeLeaf":
                    guard let address = child["URLString"] as? String, address.hasPrefix("http") else { return nil }
                    let title = (child["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                    return .tab(Tab(url: address, title: title, pinnedURL: address))
                case "WebBookmarkTypeList":
                    guard (child["Title"] as? String) != "com.apple.ReadingList" else { return nil }
                    let children = nodes(child)
                    return children.isEmpty ? nil : .folder(Folder(title: child["Title"] as? String ?? "Folder", isExpanded: false, children: children))
                default:
                    return nil
                }
            }
        }
        let imported = nodes(root)
        guard !imported.isEmpty else { return nil }
        return addImportedFolder(title: "Safari Bookmarks", children: imported, source: "Safari")
    }

    private func addImportedFolder(title: String, children: [SidebarNode], source: String) -> String? {
        guard let spaceID = store.state.spaces.first?.id else { return nil }
        let count = children.allTabs.count
        store.update { state in
            guard let index = state.spaceIndex(spaceID) else { return }
            state.spaces[index].pinned.append(.folder(Folder(title: title, isExpanded: false, children: children)))
        }
        return "\(source): \(count) bookmarks"
    }

    /// Reads Arc's `StorableSidebar.json` (spaces, pinned tabs, folders,
    /// favorites) and its space themes.
    func importArc() -> String? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Arc/StorableSidebar.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [Any],
              let container = containers.compactMap({ $0 as? [String: Any] }).first(where: { $0["spaces"] != nil })
        else { return nil }

        let items = Self.objects(container["items"])
        let itemsByID = Dictionary(items.compactMap { item in (item["id"] as? String).map { ($0, item) } },
                                   uniquingKeysWith: { first, _ in first })
        let spaces = Self.objects(container["spaces"])

        func node(_ id: String) -> SidebarNode? {
            guard let item = itemsByID[id] else { return nil }
            if let tab = (item["data"] as? [String: Any])?["tab"] as? [String: Any],
               let address = tab["savedURL"] as? String, !address.isEmpty {
                let title = item["title"] as? String
                return .tab(Tab(url: address, title: tab["savedTitle"] as? String ?? "", customTitle: title,
                                pinnedURL: address))
            }
            let children = (item["childrenIds"] as? [String] ?? []).compactMap(node)
            if (item["data"] as? [String: Any])?["list"] != nil || item["title"] is String {
                return .folder(Folder(title: item["title"] as? String ?? "Folder", isExpanded: false, children: children))
            }
            if (item["data"] as? [String: Any])?["splitView"] != nil {
                let tabs = children.compactMap(\.asTab)
                return tabs.count >= 2 ? .split(SplitView(tabs: tabs)) : tabs.first.map(SidebarNode.tab)
            }
            return nil
        }

        var importedSpaces = 0
        var importedTabs = 0
        let profileID = store.state.defaultProfile.id
        for space in spaces {
            guard let title = space["title"] as? String else { continue }
            let containerIDs = space["containerIDs"] as? [Any] ?? []
            // containerIDs alternate a kind marker ("pinned"/"unpinned") and an item ID.
            var pinnedRoot: String?
            for (index, value) in containerIDs.enumerated() where (value as? String) == "pinned" || (value as? [String: Any])?["pinned"] != nil {
                if index + 1 < containerIDs.count { pinnedRoot = containerIDs[index + 1] as? String }
            }
            let pinned = pinnedRoot.flatMap { itemsByID[$0]?["childrenIds"] as? [String] }?.compactMap(node) ?? []
            // Spaces without a custom theme use Arc's default gradient.
            let theme = Self.theme(from: space["customInfo"] as? [String: Any]) ?? .lavender
            let iconName = ((space["customInfo"] as? [String: Any])?["iconType"] as? [String: Any])?["icon"] as? String
            let icon = iconName.flatMap(Self.spaceIcon)
            store.update { state in
                let created = state.createSpace(title: title, icon: icon, theme: theme, profileID: profileID)
                state.updateSpace(created.id) { $0.pinned = pinned }
            }
            importedSpaces += 1
            importedTabs += pinned.allTabs.count
        }

        // Favorites ("top apps").
        var favorites: [Tab] = []
        if let topIDs = container["topAppsContainerIDs"] as? [Any] {
            for case let id as String in topIDs {
                for child in itemsByID[id]?["childrenIds"] as? [String] ?? [] {
                    if case let .tab(tab)? = node(child) { favorites.append(tab) }
                }
            }
        }
        if !favorites.isEmpty {
            store.update { state in
                state.favorites[profileID.uuidString, default: []] += favorites
            }
        }
        guard importedSpaces > 0 || !favorites.isEmpty else { return nil }
        return "Arc: \(importedSpaces) spaces, \(importedTabs) pinned tabs, \(favorites.count) favorites"
    }

    /// Arc stores either an emoji or the name of one of its icons.
    static func spaceIcon(_ value: String) -> SpaceIcon? {
        if value.count == 1, value.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C }) {
            return .emoji(value)
        }
        let arcIcons: [String: String] = [
            "planet": "globe.americas.fill", "star": "star.fill", "heart": "heart.fill", "bolt": "bolt.fill",
            "briefcase": "briefcase.fill", "house": "house.fill", "book": "book.fill", "music": "music.note",
            "camera": "camera.fill", "code": "chevron.left.forwardslash.chevron.right", "leaf": "leaf.fill",
            "flame": "flame.fill", "moon": "moon.fill", "sun": "sun.max.fill", "cloud": "cloud.fill",
            "game": "gamecontroller.fill", "cart": "cart.fill", "plane": "airplane", "person": "person.fill",
        ]
        if let symbol = arcIcons[value.lowercased()] { return .symbol(symbol) }
        if NSImage(systemSymbolName: value, accessibilityDescription: nil) != nil { return .symbol(value) }
        return nil
    }

    private static func objects(_ value: Any?) -> [[String: Any]] {
        (value as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    private static func theme(from customInfo: [String: Any]?) -> SpaceTheme? {
        guard let windowTheme = customInfo?["windowTheme"] as? [String: Any],
              let background = windowTheme["background"] as? [String: Any],
              let single = (background["single"] as? [String: Any])?["_0"] as? [String: Any],
              let style = single["style"] as? [String: Any],
              let color = (style["color"] as? [String: Any])?["_0"] as? [String: Any],
              let gradient = (color["blendedGradient"] as? [String: Any])?["_0"] as? [String: Any],
              let baseColors = gradient["baseColors"] as? [[String: Any]] else { return nil }
        let colors = baseColors.map { value in
            RGBColor(red: value["red"] as? Double ?? 0.5, green: value["green"] as? Double ?? 0.5, blue: value["blue"] as? Double ?? 0.5)
        }
        let modifiers = gradient["modifiers"] as? [String: Any]
        let appearance: ThemeAppearance = switch gradient["translucencyStyle"] as? String {
        case "light": .light
        case "dark": .dark
        default: .automatic
        }
        let wheel = (gradient["wheel"] as? [String: Any])?.keys.first
        let harmony: ColorHarmony = switch wheel {
        case "complementary": .complementary
        case "triadic": .triadic
        case "analogous": .analogous
        default: colors.count > 1 ? .analogous : .single
        }
        return SpaceTheme(colors: colors, harmony: harmony, appearance: appearance,
                          intensity: modifiers?["intensityFactor"] as? Double ?? 0.3,
                          grain: modifiers?["noiseFactor"] as? Double ?? 0.1)
    }
}
