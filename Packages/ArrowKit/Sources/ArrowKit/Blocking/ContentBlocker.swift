import Foundation

/// Network filter compiled from Adblock Plus / EasyList syntax.
///
/// Only host rules are compiled (`||host^`, optionally `$third-party`, and
/// `@@||host^` exceptions): they cover the vast majority of ad and tracker
/// requests and can be matched quickly on Chromium's IO thread. Rules with
/// paths, regular expressions, `domain=` restrictions and cosmetic filters
/// are ignored.
public struct ContentBlocker: Sendable {
    public private(set) var blockedHosts: Set<String> = []
    public private(set) var thirdPartyHosts: Set<String> = []
    public private(set) var allowedHosts: Set<String> = []

    public init() {}

    public init(lists: [String]) {
        for list in lists { add(list) }
    }

    public var ruleCount: Int { blockedHosts.count + thirdPartyHosts.count }

    public mutating func add(_ list: String) {
        for rawLine in list.split(whereSeparator: \.isNewline) {
            parse(rawLine.trimmingCharacters(in: .whitespaces))
        }
    }

    private mutating func parse(_ line: String) {
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), !line.contains("#") else { return }
        var rule = Substring(line)
        let isException = rule.hasPrefix("@@")
        if isException { rule = rule.dropFirst(2) }
        guard rule.hasPrefix("||") else { return }
        rule = rule.dropFirst(2)

        var options: [Substring] = []
        if let dollar = rule.firstIndex(of: "$") {
            options = rule[rule.index(after: dollar)...].split(separator: ",")
            rule = rule[..<dollar]
        }
        // Host-only rules: "host^" or "host" (possibly "host^|").
        if rule.hasSuffix("^|") { rule = rule.dropLast(2) } else if rule.hasSuffix("^") { rule = rule.dropLast() }
        let host = rule.lowercased()
        guard !host.isEmpty, host.contains("."),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else { return }

        if options.contains(where: { $0.hasPrefix("domain=") || $0 == "~third-party" || $0.hasPrefix("redirect") || $0 == "badfilter" }) {
            return
        }
        if isException {
            allowedHosts.insert(host)
        } else if options.contains("third-party") {
            thirdPartyHosts.insert(host)
        } else {
            blockedHosts.insert(host)
        }
    }

    /// Whether a request to `url` made by `initiator` (an origin) is blocked.
    /// Top-level navigations are never blocked.
    public func shouldBlock(url: String, initiator: String?, isNavigation: Bool) -> Bool {
        guard !isNavigation, let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        let suffixes = Self.suffixes(of: host)
        if suffixes.contains(where: allowedHosts.contains) { return false }
        if suffixes.contains(where: blockedHosts.contains) { return true }
        guard suffixes.contains(where: thirdPartyHosts.contains) else { return false }
        guard let initiator, let initiatorHost = URLComponents(string: initiator)?.host?.lowercased() else { return true }
        return URLDisplay.registrableDomain(initiatorHost) != URLDisplay.registrableDomain(host)
    }

    /// "a.b.example.com" → ["a.b.example.com", "b.example.com", "example.com"].
    static func suffixes(of host: String) -> [String] {
        var result = [host]
        var remainder = Substring(host)
        while let dot = remainder.firstIndex(of: "."), remainder[remainder.index(after: dot)...].contains(".") {
            remainder = remainder[remainder.index(after: dot)...]
            result.append(String(remainder))
        }
        return result
    }
}
