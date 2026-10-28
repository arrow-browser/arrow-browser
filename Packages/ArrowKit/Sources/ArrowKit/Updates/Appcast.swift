import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A release of a Sparkle appcast (served by Arrow Cloud at
/// `/v1/updates/appcast.xml`).
public struct AppcastItem: Equatable, Sendable {
    /// CFBundleVersion.
    public var version: String
    /// CFBundleShortVersionString.
    public var shortVersion: String
    public var url: String
    public var length: Int?
    /// Base64 Ed25519 signature of the archive (Sparkle's edSignature).
    public var edSignature: String?
    public var minimumSystemVersion: String?

    public init(version: String, shortVersion: String, url: String, length: Int? = nil, edSignature: String? = nil,
                minimumSystemVersion: String? = nil) {
        self.version = version
        self.shortVersion = shortVersion
        self.url = url
        self.length = length
        self.edSignature = edSignature
        self.minimumSystemVersion = minimumSystemVersion
    }

    /// Whether this release is newer than the running build.
    public func isNewer(thanShortVersion shortVersion: String, version: String) -> Bool {
        switch self.shortVersion.compare(shortVersion, options: .numeric) {
        case .orderedDescending: true
        case .orderedAscending: false
        case .orderedSame: self.version.compare(version, options: .numeric) == .orderedDescending
        }
    }
}

public enum Appcast {
    /// Parses the `<item>`s of an appcast.
    public static func parse(_ data: Data) -> [AppcastItem] {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    /// Newest release that is newer than the running build, if any.
    public static func latest(in items: [AppcastItem], currentShortVersion: String, currentVersion: String) -> AppcastItem? {
        items
            .filter { $0.isNewer(thanShortVersion: currentShortVersion, version: currentVersion) }
            .max { lhs, rhs in rhs.isNewer(thanShortVersion: lhs.shortVersion, version: lhs.version) }
    }

    /// Checks an archive against Sparkle's EdDSA signature and the expected
    /// length. Without a public key nothing is trusted.
    public static func verify(archive: Data, item: AppcastItem, publicKey: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signatureText = item.edSignature, let signature = Data(base64Encoded: signatureText) else { return false }
        if let length = item.length, length != archive.count { return false }
        return key.isValidSignature(signature, for: archive)
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: AppcastItem?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            switch element {
            case "item":
                current = AppcastItem(version: "", shortVersion: "", url: "")
            case "enclosure":
                current?.url = attributes["url"] ?? ""
                current?.length = attributes["length"].flatMap(Int.init)
                current?.edSignature = attributes["sparkle:edSignature"]
                if let version = attributes["sparkle:version"] { current?.version = version }
                if let short = attributes["sparkle:shortVersionString"] { current?.shortVersion = short }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "sparkle:version": current?.version = value
            case "sparkle:shortVersionString": current?.shortVersion = value
            case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value
            case "item":
                if var item = current, !item.url.isEmpty {
                    if item.shortVersion.isEmpty { item.shortVersion = item.version }
                    items.append(item)
                }
                current = nil
            default:
                break
            }
        }
    }
}
