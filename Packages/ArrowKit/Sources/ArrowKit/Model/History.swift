import Foundation

/// A visited address, used by command bar suggestions.
public struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String { url }
    public var url: String
    public var title: String
    public var visitCount: Int
    public var lastVisit: Date

    public init(url: String, title: String, visitCount: Int = 1, lastVisit: Date = Date()) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisit = lastVisit
    }

    /// Frecency: frequency weighted by recency.
    public func score(now: Date = Date()) -> Double {
        let ageDays = max(now.timeIntervalSince(lastVisit) / 86400, 0)
        let recency: Double = switch ageDays {
        case ..<1: 100
        case ..<4: 70
        case ..<14: 50
        case ..<31: 30
        case ..<90: 10
        default: 5
        }
        return Double(visitCount) * recency
    }
}

/// Bounded browsing history.
public struct History: Codable, Sendable {
    public static let limit = 10000

    public private(set) var entries: [String: HistoryEntry] = [:]

    public init() {}

    public mutating func recordVisit(url: String, title: String, at date: Date = Date()) {
        guard url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("file://") else { return }
        let key = URLDisplay.normalized(url)
        if var entry = entries[key] {
            entry.visitCount += 1
            entry.lastVisit = date
            entry.url = url
            if !title.isEmpty { entry.title = title }
            entries[key] = entry
        } else {
            entries[key] = HistoryEntry(url: url, title: title, lastVisit: date)
            trimIfNeeded()
        }
    }

    public mutating func updateTitle(url: String, title: String) {
        let key = URLDisplay.normalized(url)
        guard !title.isEmpty, entries[key] != nil else { return }
        entries[key]?.title = title
    }

    public mutating func remove(url: String) {
        entries[URLDisplay.normalized(url)] = nil
    }

    public mutating func clear(since date: Date? = nil) {
        guard let date else {
            entries.removeAll()
            return
        }
        entries = entries.filter { $0.value.lastVisit < date }
    }

    /// Best matches for `query` (title or address), by frecency.
    public func search(_ query: String, limit: Int = 8, now: Date = Date()) -> [HistoryEntry] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        return entries.values
            .filter { entry in
                let haystack = (entry.title + " " + URLDisplay.full(entry.url)).lowercased()
                return terms.allSatisfy { haystack.contains($0) }
            }
            .sorted { lhs, rhs in
                let lhsPrefix = URLDisplay.full(lhs.url).lowercased().hasPrefix(terms[0])
                let rhsPrefix = URLDisplay.full(rhs.url).lowercased().hasPrefix(terms[0])
                if lhsPrefix != rhsPrefix { return lhsPrefix }
                return lhs.score(now: now) > rhs.score(now: now)
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Most visited sites, for the new tab suggestions.
    public func topSites(limit: Int = 8, now: Date = Date()) -> [HistoryEntry] {
        entries.values.sorted { $0.score(now: now) > $1.score(now: now) }.prefix(limit).map { $0 }
    }

    private mutating func trimIfNeeded() {
        guard entries.count > Self.limit else { return }
        let sorted = entries.sorted { $0.value.lastVisit < $1.value.lastVisit }
        for (key, _) in sorted.prefix(entries.count - Self.limit) {
            entries[key] = nil
        }
    }
}
