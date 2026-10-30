import AppKit
import ArrowCore

extension PageImage {
    /// The image decoded for AppKit, once.
    var nsImage: NSImage? {
        if let image = decoded as? NSImage { return image }
        let image = NSImage(data: data)
        decoded = image
        return image
    }
}
