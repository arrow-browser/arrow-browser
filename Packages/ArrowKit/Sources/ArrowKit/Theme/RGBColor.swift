import Foundation

/// An sRGB color with components in 0…1.
public struct RGBColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    public init(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let s = saturation.clamped(to: 0...1)
        let v = brightness.clamped(to: 0...1)
        let sector = Int(h) % 6
        let f = h - Double(Int(h))
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        let (r, g, b): (Double, Double, Double) = switch sector {
        case 0: (v, t, p)
        case 1: (q, v, p)
        case 2: (p, v, t)
        case 3: (p, q, v)
        case 4: (t, p, v)
        default: (v, p, q)
        }
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }

    /// Hue, saturation and brightness, each in 0…1.
    public var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue
        let saturation = maxValue == 0 ? 0 : delta / maxValue
        var hue = 0.0
        if delta > 0 {
            if maxValue == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, saturation, maxValue)
    }

    public var hexString: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// Relative luminance (WCAG).
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// Linear interpolation towards `other`.
    public func mixed(with other: RGBColor, amount: Double) -> RGBColor {
        let t = amount.clamped(to: 0...1)
        return RGBColor(red: red + (other.red - red) * t,
                        green: green + (other.green - green) * t,
                        blue: blue + (other.blue - blue) * t,
                        alpha: alpha + (other.alpha - alpha) * t)
    }

    public func withAlpha(_ alpha: Double) -> RGBColor {
        RGBColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public func withHSB(saturation: Double? = nil, brightness: Double? = nil, hueShift: Double = 0) -> RGBColor {
        let current = hsb
        return RGBColor(hue: current.hue + hueShift,
                        saturation: saturation ?? current.saturation,
                        brightness: brightness ?? current.brightness,
                        alpha: alpha)
    }

    public static let white = RGBColor(red: 1, green: 1, blue: 1)
    public static let black = RGBColor(red: 0, green: 0, blue: 0)
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
