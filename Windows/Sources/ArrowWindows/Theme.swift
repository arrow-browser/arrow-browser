import ArrowCore
import ArrowKit
import Foundation
import UWP
import WindowsFoundation
import WinUI

/// The current space's colors (ArrowKit's `ThemePalette`) as WinUI brushes,
/// as Arc draws them on Windows: the theme's colors over Mica (the desktop
/// showing through), titles and icons in a dark shade of the theme's hue.
/// The window's elements share them, and they change color in place when
/// the space or its theme changes.
@MainActor
final class ThemeBrushes {
    /// The space gradient behind the sidebar and around the content, over
    /// the window's Mica backdrop.
    let background = LinearGradientBrush()
    /// Folder icons, in a vivid shade of the theme's hue.
    let folder = SolidColorBrush()
    let title = SolidColorBrush()
    let subtitle = SolidColorBrush()
    let icon = SolidColorBrush()
    let disabledIcon = SolidColorBrush()
    let controlFill = SolidColorBrush()
    let controlHover = SolidColorBrush()
    let hover = SolidColorBrush()
    let pressed = SolidColorBrush()
    let selection = SolidColorBrush()
    let separator = SolidColorBrush()
    /// The bottom edge of the selected row, Arc's card shadow.
    let selectionEdge = SolidColorBrush()
    let content = SolidColorBrush()
    let clear = SolidColorBrush(Color(a: 0, r: 0, g: 0, b: 0))
    private(set) var palette: ThemePalette

    init(theme: SpaceTheme, isDark: Bool) {
        palette = theme.palette(isDark: isDark)
        background.startPoint = Point(x: 0, y: 0)
        background.endPoint = Point(x: 1, y: 1)
        apply(theme: theme, isDark: isDark)
    }

    func apply(theme: SpaceTheme, isDark: Bool) {
        let palette = theme.palette(isDark: isDark)
        self.palette = palette
        // Arc's tint over Mica: the theme's own colors, partly transparent.
        let colors = theme.colors.count == 1 ? [theme.colors[0], theme.colors[0]] : theme.colors
        let alpha = isDark ? 0.18 + theme.intensity * 0.5 : 0.16 + theme.intensity * 0.6
        background.gradientStops.clear()
        for (index, color) in colors.enumerated() {
            let stop = GradientStop()
            stop.color = Color(color.withAlpha(alpha))
            stop.offset = Double(index) / Double(colors.count - 1)
            background.gradientStops.append(stop)
        }
        let hue = theme.primary.hsb.hue
        // Arc's titles and icons on Windows: a dark shade of the theme's hue
        // (#0D0F4B in its default space).
        let ink = isDark ? palette.title : RGBColor(hue: hue, saturation: 0.82, brightness: 0.29)
        title.color = Color(ink)
        subtitle.color = Color(palette.subtitle)
        icon.color = Color(isDark ? palette.icon : ink)
        folder.color = Color(RGBColor(hue: hue, saturation: 0.82, brightness: isDark ? 1 : 0.98))
        disabledIcon.color = Color((isDark ? palette.icon : ink).withAlpha(0.4))
        controlFill.color = Color(palette.controlFill)
        controlHover.color = Color(palette.controlFill.withAlpha(min(palette.controlFill.alpha * 1.6, 1)))
        hover.color = Color(palette.hover)
        pressed.color = Color(palette.isDark ? RGBColor.white.withAlpha(0.12) : RGBColor.black.withAlpha(0.08))
        selection.color = Color(palette.selection)
        separator.color = Color(palette.subtitle.withAlpha(0.35))
        selectionEdge.color = Color(RGBColor.black.withAlpha(isDark ? 0.2 : 0.07))
        content.color = Color(palette.contentBackground)
    }

    /// Opaque color of the window's top right corner under the pointer, for
    /// the caption buttons (which take no transparency when hovered).
    var captionHover: Color {
        let corner = palette.backgroundStops.last ?? palette.contentBackground
        return Color(corner.mixed(with: palette.isDark ? .white : .black, amount: palette.isDark ? 0.1 : 0.06))
    }

    /// Lightweight styling of the buttons under `resources`' element: the
    /// Button template's brushes, for each state, from the palette.
    func styleButtons(in resources: ResourceDictionary) {
        let brushes: [(String, SolidColorBrush)] = [
            ("ButtonBackground", clear), ("ButtonBackgroundPointerOver", hover),
            ("ButtonBackgroundPressed", pressed), ("ButtonBackgroundDisabled", clear),
            ("ButtonForeground", title), ("ButtonForegroundPointerOver", title),
            ("ButtonForegroundPressed", title), ("ButtonForegroundDisabled", disabledIcon),
            ("ButtonBorderBrush", clear), ("ButtonBorderBrushPointerOver", clear),
            ("ButtonBorderBrushPressed", clear), ("ButtonBorderBrushDisabled", clear),
        ]
        for (key, brush) in brushes {
            _ = resources.insert(key, brush)
        }
    }
}

/// Settings ▸ General ▸ Window backdrop, Arc's: Mica matches the window to
/// the desktop, Acrylic blurs what is behind it. A Windows setting, kept in
/// the app's defaults.
enum WindowBackdrop: String, CaseIterable {
    case mica = "Mica"
    case acrylic = "Acrylic"

    private static let key = "WindowBackdrop"

    static var current: WindowBackdrop {
        get { UserDefaults.standard.string(forKey: key).flatMap(WindowBackdrop.init(rawValue:)) ?? .mica }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            UserDefaults.standard.synchronize()
        }
    }

    @MainActor
    func make() -> SystemBackdrop {
        switch self {
        case .mica:
            let mica = MicaBackdrop()
            mica.kind = .baseAlt
            return mica
        case .acrylic:
            return DesktopAcrylicBackdrop()
        }
    }
}

extension Color {
    init(_ color: RGBColor) {
        func byte(_ value: Double) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        self.init(a: byte(color.alpha), r: byte(color.red), g: byte(color.green), b: byte(color.blue))
    }
}

/// Glyphs of Segoe Fluent Icons, the Windows 11 icon font.
@MainActor
enum Glyph {
    static let back = "\u{E72B}"
    static let forward = "\u{E72A}"
    static let reload = "\u{E72C}"
    static let sidebar = "\u{E90C}"
    static let link = "\u{E71B}"
    static let add = "\u{E710}"
    static let close = "\u{E711}"
    static let folder = "\u{E8B7}"
    static let folderOpen = "\u{E838}"
    static let split = "\u{E89A}"
    static let globe = "\u{E774}"
    static let clear = "\u{E74B}"
    static let search = "\u{E721}"
    static let history = "\u{E81C}"
    static let pin = "\u{E718}"
    static let undo = "\u{E7A7}"
    static let heart = "\u{EB51}"
    static let update = "\u{EBD3}"
    static let importItems = "\u{E8B5}"
    static let newWindow = "\u{E737}"
    static let incognito = "\u{E890}"
    static let spaces = "\u{E8EA}"
    static let extensions = "\u{EA86}"
    static let developer = "\u{E943}"
    static let help = "\u{E76E}"
    static let settings = "\u{E713}"
    static let print = "\u{E749}"
    static let person = "\u{E77B}"
    static let newSpace = "\u{EA61}"
    static let newFolder = "\u{E8F4}"
    static let addCircle = "\u{ECC8}"
    static let splitView = "\u{F57C}"
    static let splitRight = "\u{F5A6}"
    static let splitLeft = "\u{F5A5}"
    static let splitTop = "\u{F5A7}"
    static let splitBottom = "\u{F5A8}"
    static let siteControls = "\u{E9E9}"
    static let archive = "\u{E7B8}"
    static let lock = "\u{E72E}"
    static let share = "\u{E72D}"
    static let more = "\u{E712}"
    static let find = "\u{E721}"
    static let chevronUp = "\u{E70E}"
    static let chevronDown = "\u{E70D}"
    static let speaker = "\u{E767}"
    static let mute = "\u{E74F}"
    static let download = "\u{E896}"
    static let play = "\u{E768}"
    static let pause = "\u{E769}"
    static let live = "\u{E945}"

    static let font = FontFamily("Segoe Fluent Icons")

    /// `glyph` drawn at `size`, in the color of its parent's text.
    static func view(_ glyph: String, size: Double = 14) -> TextBlock {
        let view = TextBlock()
        view.text = glyph
        view.fontFamily = font
        view.fontSize = size
        view.verticalAlignment = .center
        view.horizontalAlignment = .center
        return view
    }

    /// The glyph for an SF Symbol of the shared code (the command bar's
    /// rows), the globe for others.
    static func symbol(_ name: String) -> String {
        switch name {
        case "magnifyingglass": search
        case "clock": history
        case "link": link
        case "pin": pin
        case "sidebar.left": sidebar
        case "arrow.left.square": back
        case "arrow.right.square": forward
        case "xmark.circle": close
        case "arrow.uturn.backward": undo
        default: globe
        }
    }
}

extension PageImage {
    /// The image decoded for WinUI, once.
    var bitmap: BitmapImage {
        if let bitmap = decoded as? BitmapImage { return bitmap }
        let bitmap = BitmapImage()
        decoded = bitmap
        let data = data
        Task {
            // A failed decoding leaves the image empty.
            try? await bitmap.load(png: data)
        }
        return bitmap
    }
}

@MainActor
private extension BitmapImage {
    func load(png data: Data) async throws {
        let stream = InMemoryRandomAccessStream()
        let writer = DataWriter(stream)
        try writer.writeBytes(Array(data))
        _ = try await writer.storeAsync().get()
        _ = try writer.detachStream()
        try stream.seek(0)
        try setSource(stream)
    }
}
