import Foundation

/// Customization of a website (Arc "Boosts"): colors, font, hidden
/// elements ("Zap") and custom CSS/JS injected on every page of the domain.
public struct Boost: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Host the boost applies to (subdomains included).
    public var domain: String
    public var isEnabled: Bool
    /// Hue rotation in degrees applied to the page (color picker).
    public var hueRotation: Double?
    public var brightness: Double?
    public var saturation: Double?
    public var invertColors: Bool
    /// Font family forced on the whole page.
    public var fontFamily: String?
    public var fontScale: Double?
    /// CSS selectors hidden with "Zap".
    public var zappedSelectors: [String]
    public var css: String
    public var javaScript: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, domain: String, isEnabled: Bool = true, hueRotation: Double? = nil,
                brightness: Double? = nil, saturation: Double? = nil, invertColors: Bool = false, fontFamily: String? = nil,
                fontScale: Double? = nil, zappedSelectors: [String] = [], css: String = "", javaScript: String = "",
                createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.domain = domain
        self.isEnabled = isEnabled
        self.hueRotation = hueRotation
        self.brightness = brightness
        self.saturation = saturation
        self.invertColors = invertColors
        self.fontFamily = fontFamily
        self.fontScale = fontScale
        self.zappedSelectors = zappedSelectors
        self.css = css
        self.javaScript = javaScript
        self.createdAt = createdAt
    }

    public func applies(to url: String) -> Bool {
        guard isEnabled, let host = URLDisplay.host(of: url)?.lowercased() else { return false }
        let target = domain.lowercased().replacingOccurrences(of: "www.", with: "")
        return host == target || host.hasSuffix("." + target)
    }

    /// Stylesheet generated from the visual settings and custom CSS.
    public var generatedCSS: String {
        var rules: [String] = []
        var filters: [String] = []
        if let hueRotation, hueRotation != 0 { filters.append("hue-rotate(\(Int(hueRotation))deg)") }
        if let brightness, brightness != 1 { filters.append("brightness(\(brightness))") }
        if let saturation, saturation != 1 { filters.append("saturate(\(saturation))") }
        if invertColors { filters.append("invert(1) hue-rotate(180deg)") }
        if !filters.isEmpty {
            rules.append("html { filter: \(filters.joined(separator: " ")) !important; }")
            if invertColors {
                rules.append("img, video, picture, canvas, svg image { filter: invert(1) hue-rotate(180deg) !important; }")
            }
        }
        if let fontFamily, !fontFamily.isEmpty {
            let escaped = fontFamily.replacingOccurrences(of: "\"", with: "")
            rules.append("body, body *:not(code):not(pre):not(kbd):not(samp) { font-family: \"\(escaped)\", sans-serif !important; }")
        }
        if let fontScale, fontScale != 1 {
            rules.append("html { font-size: \(Int(fontScale * 100))% !important; }")
        }
        let zapped = zappedSelectors.filter { !$0.contains("{") && !$0.contains("}") }
        if !zapped.isEmpty {
            rules.append("\(zapped.joined(separator: ", ")) { display: none !important; }")
        }
        if !css.isEmpty { rules.append(css) }
        return rules.joined(separator: "\n")
    }

    /// Script injected after load: installs the stylesheet then runs the
    /// boost's JavaScript.
    public var injectionScript: String {
        let cssLiteral = Self.javaScriptStringLiteral(generatedCSS)
        var script = """
        (() => {
          const id = 'arrow-boost-\(id.uuidString)';
          let style = document.getElementById(id);
          if (!style) { style = document.createElement('style'); style.id = id; (document.head || document.documentElement).appendChild(style); }
          style.textContent = \(cssLiteral);
        })();
        """
        if !javaScript.isEmpty {
            script += "\ntry {\n\(javaScript)\n} catch (error) { console.error('Arrow Boost', error); }"
        }
        return script
    }

    static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal.replacingOccurrences(of: "</", with: "<\\/")
    }
}
