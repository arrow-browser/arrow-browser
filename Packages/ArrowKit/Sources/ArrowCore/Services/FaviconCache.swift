import ArrowKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Favicons by host, in memory and on disk (used before a tab is loaded).
@MainActor
public final class FaviconCache {
    public static let shared = FaviconCache()

    private var images: [String: PageImage] = [:]
    private let directory: URL

    private init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Arrow/State/Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func key(for url: String) -> String? {
        URLDisplay.host(of: url)?.lowercased()
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    public func image(for url: String) -> PageImage? {
        guard let key = key(for: url) else { return nil }
        if let image = images[key] { return image }
        guard let data = try? Data(contentsOf: fileURL(for: key)) else { return nil }
        let image = PageImage(data: data)
        images[key] = image
        return image
    }

    private var pendingHosts: Set<String> = []

    /// Fetches a favicon for a page that was never loaded, through the
    /// Google favicon service Arc also used.
    public func fetch(for url: String) async -> PageImage? {
        guard let key = key(for: url), !pendingHosts.contains(key) else { return nil }
        pendingHosts.insert(key)
        defer { pendingHosts.remove(key) }
        var components = URLComponents(string: "https://www.google.com/s2/favicons")!
        // domain_url (rather than domain) keeps subdomain icons, e.g. Gmail's.
        components.queryItems = [URLQueryItem(name: "domain_url", value: "https://\(key)/"), URLQueryItem(name: "sz", value: "64")]
        guard let request = components.url,
              let (data, response) = try? await URLSession.shared.data(from: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let image = PageImage(data: data)
        guard let width = image.pixelSize?.width, width >= 16 else { return nil }
        store(image, for: url)
        return image
    }

    public func store(_ image: PageImage, for url: String) {
        guard let key = key(for: url) else { return }
        images[key] = image
        let destination = fileURL(for: key)
        let png = image.data
        Task.detached(priority: .utility) {
            try? png.write(to: destination, options: .atomic)
        }
    }
}
