import ArrowCore
import ArrowKit
import Foundation
import UWP
import WindowsFoundation
import WinUI

/// The current space's colors (ArrowKit's `ThemePalette`) as WinUI brushes.
/// The window's elements share them, and they change color in place when
/// the space or its theme changes.
@MainActor
final class ThemeBrushes {
    /// The space gradient behind the sidebar and around the content.
    let background = LinearGradientBrush()
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
    let content = SolidColorBrush()
    let clear = SolidColorBrush(Color(a: 0, r: 0, g: 0, b: 0))
    private(set) var palette: ThemePalette

    init(palette: ThemePalette) {
        self.palette = palette
        background.startPoint = Point(x: 0, y: 0)
        background.endPoint = Point(x: 1, y: 1)
        apply(palette)
    }

    func apply(_ palette: ThemePalette) {
        self.palette = palette
        let stops = palette.backgroundStops.count == 1
            ? [palette.backgroundStops[0], palette.backgroundStops[0]] : palette.backgroundStops
        background.gradientStops.clear()
        for (index, color) in stops.enumerated() {
            let stop = GradientStop()
            stop.color = Color(color)
            stop.offset = Double(index) / Double(stops.count - 1)
            background.gradientStops.append(stop)
        }
        title.color = Color(palette.title)
        subtitle.color = Color(palette.subtitle)
        icon.color = Color(palette.icon)
        disabledIcon.color = Color(palette.icon.withAlpha(0.45))
        controlFill.color = Color(palette.controlFill)
        controlHover.color = Color(palette.controlFill.withAlpha(min(palette.controlFill.alpha * 1.6, 1)))
        hover.color = Color(palette.hover)
        pressed.color = Color(palette.isDark ? RGBColor.white.withAlpha(0.12) : RGBColor.black.withAlpha(0.08))
        selection.color = Color(palette.selection)
        separator.color = Color(palette.subtitle.withAlpha(0.25))
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
    static let sidebar = "\u{E8A0}"
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
