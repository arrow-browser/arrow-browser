import Foundation

/// An Arrow Note (opened as a tab at `arrow://note/<id>`).
public struct Note: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    /// RTF data of the note body.
    public var body: Data
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String = "Untitled", body: Data = Data(), createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var url: String { "arrow://note/\(id.uuidString)" }
}

/// A point of a freehand stroke, relative to its item's origin.
public struct EaselPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// An element placed on an Easel.
public struct EaselItem: Codable, Identifiable, Hashable, Sendable {
    public enum Content: Codable, Hashable, Sendable {
        /// PNG data of a capture.
        case image(Data, sourceURL: String?)
        case text(String)
        case link(url: String, title: String)
        /// Freehand pen or highlighter stroke.
        case stroke(points: [EaselPoint], color: RGBColor, lineWidth: Double, isHighlighter: Bool)
    }

    /// A stroke item framed around `points` (canvas coordinates).
    public static func stroke(_ points: [EaselPoint], color: RGBColor, lineWidth: Double, isHighlighter: Bool) -> EaselItem? {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        let margin = lineWidth
        let relative = points.map { EaselPoint(x: $0.x - minX + margin, y: $0.y - minY + margin) }
        return EaselItem(content: .stroke(points: relative, color: color, lineWidth: lineWidth, isHighlighter: isHighlighter),
                         x: minX - margin, y: minY - margin,
                         width: maxX - minX + margin * 2, height: maxY - minY + margin * 2)
    }

    public var id: UUID
    public var content: Content
    /// Frame in canvas coordinates.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(id: UUID = UUID(), content: Content, x: Double, y: Double, width: Double, height: Double) {
        self.id = id
        self.content = content
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A freeform canvas of captures, text and links (`arrow://easel/<id>`).
public struct Easel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var items: [EaselItem]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String = "Untitled Easel", items: [EaselItem] = [], createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var url: String { "arrow://easel/\(id.uuidString)" }
}

/// Internal `arrow://` pages.
public enum InternalPage: Equatable, Sendable {
    case note(UUID)
    case easel(UUID)
    case newTab
    case settings
    case library
    case shortcuts

    public init?(url: String) {
        guard let components = URLComponents(string: url), components.scheme == "arrow" else { return nil }
        let host = components.host ?? ""
        let identifier = components.path.split(separator: "/").first.flatMap { UUID(uuidString: String($0)) }
        switch host {
        case "note": guard let identifier else { return nil }; self = .note(identifier)
        case "easel": guard let identifier else { return nil }; self = .easel(identifier)
        case "newtab": self = .newTab
        case "settings": self = .settings
        case "library": self = .library
        case "shortcuts": self = .shortcuts
        default: return nil
        }
    }
}
