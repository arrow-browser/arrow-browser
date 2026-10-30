import ArrowCore
import ArrowKit
import SwiftUI

/// Spaces ▸ Edit Theme…: Arc's compact color picker, next to the sidebar.
/// Tap the dotted canvas to pick colors (across: hue, down: paler), choose
/// light/dark, a swatch, the grain (wave) and the intensity (dial). Changes
/// apply as they are made, as in Arc.
struct ThemePickerPanel: View {
    let spaceID: UUID
    let controller: BrowserWindowController
    @Environment(BrowserStore.self) private var store
    @Environment(WindowState.self) private var state

    /// Picked colors as points of the canvas (0…1); none means Arc's default theme.
    @State private var points: [CGPoint] = []
    @State private var appearance: ThemeAppearance = .automatic
    @State private var intensity = 0.35
    @State private var grain = 0.0
    @State private var page = 0
    @State private var didLoad = false

    /// Measured on Arc: a 356×507 pt panel with a 340×339 pt canvas.
    static let size = CGSize(width: 356, height: 507)
    private static let canvasSize = CGSize(width: 340, height: 339)

    /// Arc's swatches, then Arrow's presets on the second page.
    private static let swatches: [[RGBColor]] = [
        [0xF3EAE4, 0xF29BBB, 0xA6729D, 0xF25E6B, 0xFF8558, 0xF8D558, 0x33E895, 0x6CB9D9, 0x666789].map { RGBColor(hex: $0) },
        [0x9A8CFF, 0xFF8FA3, 0xFFB36B, 0xF5D76E, 0x7ED6A5, 0x6EC6F5, 0x5B7CFA, 0xB3B3B3, 0x3B2A5C].map { RGBColor(hex: $0) },
    ]

    private var theme: SpaceTheme {
        guard !points.isEmpty else {
            var theme = SpaceTheme.lavender
            theme.appearance = appearance
            return theme
        }
        let colors = points.map(Self.color(at:))
        return colors.count == 1
            ? SpaceTheme(primary: colors[0], harmony: .analogous, appearance: appearance, intensity: intensity, grain: grain)
            : SpaceTheme(colors: colors, harmony: .single, appearance: appearance, intensity: intensity, grain: grain)
    }

    static func color(at point: CGPoint) -> RGBColor {
        RGBColor(hue: point.x, saturation: 0.15 + 0.75 * (1 - point.y), brightness: 0.95)
    }

    static func point(for color: RGBColor) -> CGPoint {
        let hsb = color.hsb
        return CGPoint(x: hsb.hue, y: min(max(1 - (hsb.saturation - 0.15) / 0.75, 0), 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            canvas
                .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
                .padding(.top, 8)
            swatchRow
                .frame(height: 48)
                .padding(.top, 9.5)
            HStack(spacing: 0) {
                GrainWave(value: $grain, isEnabled: !points.isEmpty, accent: accent)
                    .frame(width: 224, height: 34)
                    .padding(.leading, 18)
                Spacer(minLength: 0)
                IntensityDial(value: $intensity, isEnabled: !points.isEmpty, accent: accent)
                    .frame(width: 68, height: 68)
                    .padding(.trailing, 24)
            }
            .frame(height: 68)
            .padding(.top, 13.5)
            Spacer(minLength: 0)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.969, green: 0.965, blue: 0.992))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        )
        .onAppear(perform: load)
        .onChange(of: theme) { _, theme in
            guard didLoad else { return }
            store.update { $0.updateSpace(spaceID) { $0.theme = theme } }
        }
    }

    private var accent: Color {
        Color(theme.palette(isDark: false).accent.withHSB(saturation: 0.7, brightness: 0.95))
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.929, green: 0.925, blue: 0.961))
                if !points.isEmpty {
                    ThemeBackground(palette: theme.palette(isDark: false))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                DotGrid()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in
                        let point = CGPoint(x: tap.location.x / proxy.size.width, y: tap.location.y / proxy.size.height)
                        if points.isEmpty { points = [point] } else { points[points.count - 1] = point }
                    })

                if points.isEmpty {
                    Text("Tap to pick a color for this space")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(white: 0.21))
                        .allowsHitTesting(false)
                }

                ForEach(points.indices, id: \.self) { index in
                    ColorKnob(color: Color(Self.color(at: points[index])))
                        .position(x: points[index].x * proxy.size.width, y: points[index].y * proxy.size.height)
                        .gesture(DragGesture(coordinateSpace: .named("canvas")).onChanged { drag in
                            points[index] = CGPoint(x: min(max(drag.location.x / proxy.size.width, 0), 1),
                                                    y: min(max(drag.location.y / proxy.size.height, 0), 1))
                        })
                }

                VStack {
                    HStack(spacing: 7.5) {
                        AppearanceButton(symbol: "sparkles", help: "Match System", isSelected: appearance == .automatic) {
                            appearance = .automatic
                        }
                        AppearanceButton(symbol: "sun.max.fill", help: "Light", isSelected: appearance == .light) {
                            appearance = .light
                        }
                        AppearanceButton(symbol: "moon.stars.fill", help: "Dark", isSelected: appearance == .dark) {
                            appearance = .dark
                        }
                    }
                    .padding(.top, 24)
                    Spacer()
                    HStack(spacing: 20) {
                        Button { if !points.isEmpty { points.removeLast() } } label: {
                            Image(systemName: "minus").frame(width: 20, height: 20)
                        }
                        .disabled(points.isEmpty)
                        .help("Remove Color")
                        Button { addPoint() } label: {
                            Image(systemName: "plus").frame(width: 20, height: 20)
                        }
                        .disabled(points.isEmpty || points.count >= 3)
                        .help("Add Color")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color(white: points.isEmpty ? 0.72 : 0.4))
                    .padding(.bottom, 21)
                }
            }
            .coordinateSpace(name: "canvas")
        }
    }

    private func addPoint() {
        guard let last = points.last, points.count < 3 else { return }
        points.append(CGPoint(x: (last.x + 0.08).truncatingRemainder(dividingBy: 1), y: last.y))
    }

    // MARK: Swatches

    private var swatchRow: some View {
        HStack(spacing: 0) {
            Button { page = max(page - 1, 0) } label: {
                Image(systemName: "chevron.left").frame(width: 20, height: 30)
            }
            .disabled(page == 0)
            .foregroundStyle(Color(white: page == 0 ? 0.81 : 0.48))
            .frame(width: 31)
            HStack(spacing: 5.5) {
                ForEach(Array(Self.swatches[page].enumerated()), id: \.offset) { _, color in
                    Button { points = [Self.point(for: color)] } label: {
                        Circle()
                            .fill(Color(color))
                            .overlay(Circle().strokeBorder(Color(color.withHSB(brightness: color.hsb.brightness * 0.86)), lineWidth: 1.5))
                            .frame(width: 24, height: 24)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            Button { page = min(page + 1, Self.swatches.count - 1) } label: {
                Image(systemName: "chevron.right").frame(width: 20, height: 30)
            }
            .disabled(page == Self.swatches.count - 1)
            .foregroundStyle(Color(white: page == Self.swatches.count - 1 ? 0.81 : 0.48))
            .frame(width: 31)
        }
        .buttonStyle(.plain)
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 8)
    }

    private func load() {
        guard !didLoad, let space = store.state.space(spaceID) else { return }
        let theme = space.theme
        appearance = theme.appearance
        intensity = theme.intensity
        grain = theme.grain
        if theme.colors != SpaceTheme.lavender.colors {
            points = theme.harmony == .single ? theme.colors.map(Self.point(for:)) : [Self.point(for: theme.primary)]
        }
        // Let the first onChange (from loading) pass without writing.
        DispatchQueue.main.async { didLoad = true }
    }
}

/// Arc's dotted canvas.
private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 6
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.55, y: y - 0.55, width: 1.1, height: 1.1)),
                                 with: .color(.black.opacity(0.22)))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(true)
    }
}

private struct ColorKnob: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
}

private struct AppearanceButton: View {
    let symbol: String
    let help: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(white: 0.36))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.835, green: 0.835, blue: 0.855).opacity(isSelected ? 1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Grain: drag along the wave; the part up to the value takes the accent.
private struct GrainWave: View {
    @Binding var value: Double
    let isEnabled: Bool
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let wave = WaveShape()
            ZStack {
                Capsule()
                    .fill(Color(red: 0.898, green: 0.894, blue: 0.918))
                    .frame(height: 17)
                wave.stroke(Color(red: 0.765, green: 0.757, blue: 0.78), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .padding(.horizontal, 7)
                if isEnabled {
                    wave.stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .padding(.horizontal, 7)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: proxy.size.width * value)
                        }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard isEnabled else { return }
                value = min(max(drag.location.x / proxy.size.width, 0), 1)
            })
        }
        .help("Grain")
    }
}

private struct WaveShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let periods = 5.3
        let amplitude = rect.height * 0.42
        for step in 0...200 {
            let t = Double(step) / 200
            let point = CGPoint(x: rect.minX + rect.width * t, y: rect.midY - amplitude * sin(t * periods * 2 * .pi))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// Intensity: a ring of dots, filled up to the value; drag around it.
private struct IntensityDial: View {
    @Binding var value: Double
    let isEnabled: Bool
    let accent: Color
    private let dots = 24

    var body: some View {
        GeometryReader { proxy in
            let radius = proxy.size.width / 2 - 3
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                ForEach(0..<dots, id: \.self) { index in
                    let angle = Double(index) / Double(dots) * 2 * .pi - .pi / 2
                    Circle()
                        .fill(isEnabled && Double(index) < value * Double(dots)
                              ? accent : Color(red: 0.831, green: 0.824, blue: 0.835))
                        .frame(width: 4.5, height: 4.5)
                        .position(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                }
                Circle()
                    .strokeBorder(Color(red: 0.835, green: 0.831, blue: 0.851), lineWidth: 1)
                    .background(Circle().fill(Color(red: 0.976, green: 0.969, blue: 0.984)))
                    .frame(width: 40, height: 40)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard isEnabled else { return }
                var angle = atan2(drag.location.y - center.y, drag.location.x - center.x) + .pi / 2
                if angle < 0 { angle += 2 * .pi }
                value = angle / (2 * .pi)
            })
        }
        .help("Intensity")
    }
}
