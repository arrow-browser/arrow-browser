import Foundation

/// An image of the web (favicon, page snapshot) as PNG data, the format the
/// engine produces. Each app decodes it once for its UI toolkit and keeps the
/// result in `decoded`.
@MainActor
public final class PageImage {
    public let data: Data
    /// The app's decoded image.
    public var decoded: AnyObject?

    public init(data: Data) {
        self.data = data
    }

    /// Size in pixels, read from the PNG header.
    public var pixelSize: (width: Int, height: Int)? {
        // Signature (8 bytes), then the IHDR chunk: length, type, width, height.
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= 24, Array(data.prefix(8)) == signature,
              data[data.startIndex + 12..<data.startIndex + 16].elementsEqual("IHDR".utf8) else { return nil }
        func integer(at offset: Int) -> Int {
            data[data.startIndex + offset..<data.startIndex + offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        return (integer(at: 16), integer(at: 20))
    }
}
