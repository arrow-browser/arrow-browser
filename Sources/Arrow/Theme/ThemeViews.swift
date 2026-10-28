import AppKit
import ArrowKit
import SwiftUI

extension Color {
    init(_ color: RGBColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

extension NSColor {
    convenience init(_ color: RGBColor) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

extension RGBColor {
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }
}

/// Colors of the current space, resolved for the effective appearance.
struct Palette: Equatable {
    var theme: ThemePalette

    var title: Color { Color(theme.title) }
    var subtitle: Color { Color(theme.subtitle) }
    var icon: Color { Color(theme.icon) }
    var controlFill: Color { Color(theme.controlFill) }
    var hover: Color { Color(theme.hover) }
    var selection: Color { Color(theme.selection) }
    var accent: Color { Color(theme.accent) }
    var contentBackground: Color { Color(theme.contentBackground) }
    var isDark: Bool { theme.isDark }

    static let fallback = Palette(theme: SpaceTheme.lavender.palette(isDark: false))
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.fallback
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// The space gradient drawn behind the sidebar and around the content,
/// with Arc's film grain overlay.
struct ThemeBackground: View {
    var palette: ThemePalette

    var body: some View {
        ZStack {
            LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
            if palette.grain > 0 {
                GrainView(amount: palette.grain, isDark: palette.isDark)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: palette)
    }

    private var stops: [Color] {
        let colors = palette.backgroundStops.map(Color.init)
        return colors.count == 1 ? [colors[0], colors[0]] : colors
    }
}

/// Tiled monochrome noise texture.
struct GrainView: View {
    var amount: Double
    var isDark: Bool

    var body: some View {
        Rectangle()
            .fill(ImagePaint(image: Image(nsImage: GrainTexture.image), scale: 0.5))
            .opacity(amount * (isDark ? 0.5 : 0.35))
            .blendMode(isDark ? .screen : .multiply)
            .allowsHitTesting(false)
    }
}

@MainActor
private enum GrainTexture {
    static let image: NSImage = {
        let size = 256
        var generator = SystemRandomNumberGenerator()
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let value = UInt8.random(in: 96...255, using: &generator)
            pixels[index] = value
            pixels[index + 1] = value
            pixels[index + 2] = value
            pixels[index + 3] = 255
        }
        let image = pixels.withUnsafeMutableBytes { buffer -> NSImage in
            let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                    bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return NSImage(cgImage: context.makeImage()!, size: NSSize(width: size, height: size))
        }
        return image
    }()
}

/// Rounded rectangle style used by sidebar controls.
struct SidebarControlBackground: View {
    @Environment(\.palette) private var palette
    var cornerRadius: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(palette.controlFill)
    }
}

/// Plain icon button of the sidebar chrome.
struct ChromeButton: View {
    @Environment(\.palette) private var palette
    var symbol: String
    var help: String
    var isEnabled = true
    var size: CGFloat = 15
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(palette.icon.opacity(isEnabled ? 1 : 0.45))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered && isEnabled ? palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .onHover { isHovered = $0 }
    }
}
