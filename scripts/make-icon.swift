// Renders Arrow's app icon into Resources/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift
import AppKit

let output = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset")
let variantsOutput = URL(fileURLWithPath: "Resources/AppIcons")

/// Gradient (top left → bottom right) and arrow color of each icon variant.
struct Variant {
    var name: String
    var colors: [NSColor]
    var arrow: NSColor = .white
}

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let variants = [
    Variant(name: "Lavender", colors: [rgb(0x8C78FF), rgb(0xD485F2), rgb(0xFF8FA3)]),
    Variant(name: "Sunset", colors: [rgb(0xFF9A5C), rgb(0xFF6F91), rgb(0xC86DD7)]),
    Variant(name: "Ocean", colors: [rgb(0x2BC0E4), rgb(0x3F7FE0), rgb(0x5B4BE8)]),
    Variant(name: "Mint", colors: [rgb(0x7FE3B5), rgb(0x3DBFA0), rgb(0x2A9D8F)]),
    Variant(name: "Graphite", colors: [rgb(0x4A4A57), rgb(0x2C2C35), rgb(0x16161C)], arrow: rgb(0xE8E6FF)),
    Variant(name: "Paper", colors: [rgb(0xFFFFFF), rgb(0xF2F0F7), rgb(0xE6E3EE)], arrow: rgb(0x6D5BFF)),
]

func render(size: Int, variant: Variant = variants[0]) -> Data {
    let s = CGFloat(size)
    // Exact pixel size (NSImage.lockFocus would render at the screen's scale).
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with a continuous-corner squircle.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.2237
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03,
                      color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor.white.setFill()
    shape.fill()
    context.restoreGState()

    shape.addClip()
    let gradient = NSGradient(colors: variant.colors)!
    gradient.draw(in: body, angle: -45)

    // Soft highlight in the upper half.
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
    highlight.draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

    // Arrow pointing up-right.
    let unit = body.width / 10
    let center = CGPoint(x: body.midX, y: body.midY)
    let arrow = NSBezierPath()
    arrow.lineWidth = unit * 1.15
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: CGPoint(x: center.x - unit * 2.4, y: center.y - unit * 2.4))
    arrow.line(to: CGPoint(x: center.x + unit * 2.3, y: center.y + unit * 2.3))
    arrow.move(to: CGPoint(x: center.x - unit * 0.6, y: center.y + unit * 2.5))
    arrow.line(to: CGPoint(x: center.x + unit * 2.5, y: center.y + unit * 2.5))
    arrow.line(to: CGPoint(x: center.x + unit * 2.5, y: center.y - unit * 0.6))
    context.setShadow(offset: CGSize(width: 0, height: -unit * 0.15), blur: unit * 0.5,
                      color: NSColor(srgbRed: 0.3, green: 0.15, blue: 0.5, alpha: 0.35).cgColor)
    variant.arrow.setStroke()
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(size: pixels).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
try FileManager.default.createDirectory(at: variantsOutput, withIntermediateDirectories: true)
for variant in variants {
    try render(size: 512, variant: variant).write(to: variantsOutput.appendingPathComponent("\(variant.name).png"))
}
print("Wrote \(images.count) icon images and \(variants.count) variants")
