import Foundation

/// Light/dark preference of a space theme.
public enum ThemeAppearance: String, Codable, CaseIterable, Sendable {
    case light
    case dark
    case automatic
}

/// How additional gradient colors are derived from the primary one
/// (the "wheel" of Arc's space color picker).
public enum ColorHarmony: String, Codable, CaseIterable, Sendable {
    case single
    case analogous
    case complementary
    case triadic

    /// Hue offsets (in turns) of the generated colors, primary first.
    var hueOffsets: [Double] {
        switch self {
        case .single: [0]
        case .analogous: [0, 0.075]
        case .complementary: [0, 0.5]
        case .triadic: [0, 1.0 / 3.0, 2.0 / 3.0]
        }
    }
}

/// Visual identity of a space: a blended gradient of 1–3 colors drawn
/// behind the sidebar and around the web content, plus film grain.
public struct SpaceTheme: Codable, Hashable, Sendable {
    /// Gradient stops, primary first.
    public var colors: [RGBColor]
    public var harmony: ColorHarmony
    public var appearance: ThemeAppearance
    /// Strength of the color over the light/dark base (Arc's intensityFactor).
    public var intensity: Double
    /// Film grain amount (Arc's noiseFactor).
    public var grain: Double

    public init(colors: [RGBColor], harmony: ColorHarmony = .analogous, appearance: ThemeAppearance = .automatic,
                intensity: Double = 0.35, grain: Double = 0.15) {
        self.colors = colors.isEmpty ? [SpaceTheme.defaultColor] : Array(colors.prefix(3))
        self.harmony = harmony
        self.appearance = appearance
        self.intensity = intensity.clamped(to: 0...1)
        self.grain = grain.clamped(to: 0...1)
    }

    /// Builds the gradient stops of `harmony` from a single picked color.
    public init(primary: RGBColor, harmony: ColorHarmony = .analogous, appearance: ThemeAppearance = .automatic,
                intensity: Double = 0.35, grain: Double = 0.15) {
        let hsb = primary.hsb
        let colors = harmony.hueOffsets.map { offset in
            offset == 0 ? primary : RGBColor(hue: hsb.hue + offset, saturation: hsb.saturation, brightness: hsb.brightness)
        }
        self.init(colors: colors, harmony: harmony, appearance: appearance, intensity: intensity, grain: grain)
    }

    public var primary: RGBColor { colors[0] }

    static let defaultColor = RGBColor(red: 0.563, green: 0.405, blue: 0.602)

    /// Arc's default theme (spaces without a custom theme): lavender at the
    /// top left to pink at the bottom right, rendered #E9E7FF → #FDEFF4.
    public static let lavender = SpaceTheme(colors: [RGBColor(hex: 0xA197FF), RGBColor(hex: 0xFFBFD0)],
                                            harmony: .analogous, intensity: 0.267, grain: 0)

    /// Preset swatches offered in the space color picker.
    public static let presets: [SpaceTheme] = [
        SpaceTheme(primary: RGBColor(hex: 0x9A8CFF)),
        SpaceTheme(primary: RGBColor(hex: 0xFF8FA3)),
        SpaceTheme(primary: RGBColor(hex: 0xFFB36B)),
        SpaceTheme(primary: RGBColor(hex: 0xF5D76E)),
        SpaceTheme(primary: RGBColor(hex: 0x7ED6A5)),
        SpaceTheme(primary: RGBColor(hex: 0x6EC6F5)),
        SpaceTheme(primary: RGBColor(hex: 0x5B7CFA)),
        SpaceTheme(primary: RGBColor(hex: 0xB3B3B3), harmony: .single),
    ]

    /// Theme of incognito windows.
    public static let incognito = SpaceTheme(primary: RGBColor(hex: 0x3B2A5C), harmony: .single, appearance: .dark,
                                             intensity: 0.9, grain: 0.2)

    /// Colors resolved for `isDark`.
    public func palette(isDark: Bool) -> ThemePalette {
        ThemePalette(theme: self, isDark: isDark)
    }

    /// Effective darkness for the system appearance.
    public func isDark(systemIsDark: Bool) -> Bool {
        switch appearance {
        case .light: false
        case .dark: true
        case .automatic: systemIsDark
        }
    }
}

/// Semantic colors derived from a space theme, mirroring Arc's
/// `primaryColorPalette` / `semanticColorPalette`.
public struct ThemePalette: Hashable, Sendable {
    /// Gradient stops of the window background (already blended over the base).
    public var backgroundStops: [RGBColor]
    public var grain: Double
    public var isDark: Bool

    public var tintedLight: RGBColor
    public var shaded: RGBColor
    public var shadedDark: RGBColor
    public var midTone: RGBColor

    /// Primary text of the sidebar (tab titles).
    public var title: RGBColor
    /// Secondary text (space name, section headers).
    public var subtitle: RGBColor
    /// Icons of the sidebar chrome (navigation buttons…).
    public var icon: RGBColor
    /// Fill of controls drawn over the background (URL bar, favorites tiles).
    public var controlFill: RGBColor
    /// Row hover fill.
    public var hover: RGBColor
    /// Selected tab fill.
    public var selection: RGBColor
    /// Accent used for focus rings and the command bar selection.
    public var accent: RGBColor
    /// Background of the web content panel when a page has none yet.
    public var contentBackground: RGBColor

    init(theme: SpaceTheme, isDark: Bool) {
        let base = theme.primary.hsb
        let hue = base.hue
        let saturation = max(base.saturation, 0.08)
        self.isDark = isDark
        grain = theme.grain

        let canvas: RGBColor = isDark ? RGBColor(hex: 0x1C1B22) : RGBColor(hex: 0xFBFBFD)
        let amount = isDark ? 0.25 + theme.intensity * 0.6 : 0.08 + theme.intensity * 0.45
        backgroundStops = theme.colors.map { canvas.mixed(with: $0, amount: amount) }

        tintedLight = RGBColor(hue: hue, saturation: saturation * 0.077, brightness: 0.953)
        shaded = RGBColor(hue: hue, saturation: saturation, brightness: max(base.brightness, 0.45))
        shadedDark = RGBColor(hue: hue, saturation: saturation, brightness: max(base.brightness, 0.45) * 0.76)
        midTone = RGBColor(hue: hue, saturation: saturation * 0.66, brightness: 0.698)
        accent = RGBColor(hue: hue, saturation: min(max(saturation, 0.35), 0.75), brightness: isDark ? 0.9 : 1)

        if isDark {
            title = RGBColor(hue: hue, saturation: saturation * 0.08, brightness: 0.95)
            subtitle = RGBColor(hue: hue, saturation: saturation * 0.12, brightness: 0.62)
            icon = RGBColor(hue: hue, saturation: saturation * 0.12, brightness: 0.70)
            controlFill = RGBColor.white.withAlpha(0.08)
            hover = RGBColor.white.withAlpha(0.07)
            selection = RGBColor.white.withAlpha(0.14)
            contentBackground = RGBColor(hex: 0x1F1F23)
        } else {
            title = RGBColor(hue: hue, saturation: saturation * 0.33, brightness: 0.137)
            subtitle = RGBColor(hue: hue, saturation: saturation * 0.12, brightness: 0.52)
            icon = RGBColor(hue: hue, saturation: saturation * 0.16, brightness: 0.62)
            controlFill = RGBColor(hue: hue, saturation: saturation * 0.5, brightness: 0.35, alpha: 0.075)
            hover = RGBColor.black.withAlpha(0.045)
            selection = RGBColor.white.withAlpha(0.72)
            contentBackground = RGBColor.white
        }
        if theme == .lavender, !isDark {
            // Arc's default theme selects in periwinkle, bluer than its background.
            accent = RGBColor(hex: 0xA4A9FF)
        }
    }
}
