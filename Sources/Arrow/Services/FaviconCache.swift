import AppKit
import ArrowKit

/// Favicons by host, in memory and on disk (used before a tab is loaded).
@MainActor
final class FaviconCache {
    static let shared = FaviconCache()

    private var images: [String: NSImage] = [:]
    private let directory: URL

    private init() {
        directory = CEFRuntime.shared.rootCachePath.appendingPathComponent("State/Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func key(for url: String) -> String? {
        URLDisplay.host(of: url)?.lowercased()
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    func image(for url: String) -> NSImage? {
        guard let key = key(for: url) else { return nil }
        if let image = images[key] { return image }
        guard let image = NSImage(contentsOf: fileURL(for: key)) else { return nil }
        images[key] = image
        return image
    }

    private var pendingHosts: Set<String> = []

    /// Fetches a favicon for a page that was never loaded, through the
    /// Google favicon service Arc also used.
    func fetch(for url: String) async -> NSImage? {
        guard let key = key(for: url), !pendingHosts.contains(key) else { return nil }
        pendingHosts.insert(key)
        defer { pendingHosts.remove(key) }
        var components = URLComponents(string: "https://www.google.com/s2/favicons")!
        // domain_url (rather than domain) keeps subdomain icons, e.g. Gmail's.
        components.queryItems = [URLQueryItem(name: "domain_url", value: "https://\(key)/"), URLQueryItem(name: "sz", value: "64")]
        guard let request = components.url,
              let (data, response) = try? await URLSession.shared.data(from: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data), image.size.width >= 16 else { return nil }
        store(image, for: url)
        return image
    }

    func store(_ image: NSImage, for url: String) {
        guard let key = key(for: url) else { return }
        images[key] = image
        let destination = fileURL(for: key)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        Task.detached(priority: .utility) {
            try? png.write(to: destination, options: .atomic)
        }
    }
}
