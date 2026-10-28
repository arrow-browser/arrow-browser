import AppKit
import ArrowKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Captures and downloaded images/videos (Library ▸ Media).
@MainActor
enum MediaLibrary {
    struct Item: Identifiable, Hashable {
        var id: URL { url }
        var url: URL
        var date: Date
        var isCapture: Bool
        var isVideo: Bool
    }

    static func capturesDirectory(_ store: BrowserStore) -> URL {
        store.dataDirectory.appendingPathComponent("Captures", isDirectory: true)
    }

    /// Keeps a copy of a capture, named after its page and time.
    static func saveCapture(_ image: NSImage, from tab: WebTab, in store: BrowserStore) {
        guard let data = image.pngData else { return }
        let directory = capturesDirectory(store)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let host = URLDisplay.short(tab.url).replacingOccurrences(of: "/", with: "-")
        let name = "Capture \(host) \(formatter.string(from: Date())).png"
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }

    static func items(_ store: BrowserStore) -> [Item] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .contentTypeKey]
        let captures = (try? FileManager.default.contentsOfDirectory(at: capturesDirectory(store), includingPropertiesForKeys: keys)) ?? []
        let downloads = store.downloads.items.filter { $0.state == .complete }.map(\.destination)
        var items: [Item] = []
        for (url, isCapture) in captures.map({ ($0, true) }) + downloads.map({ ($0, false) }) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard let type = values?.contentType, type.conforms(to: .image) || type.conforms(to: .movie) else { continue }
            items.append(Item(url: url, date: values?.contentModificationDate ?? .distantPast, isCapture: isCapture,
                              isVideo: type.conforms(to: .movie)))
        }
        return items.sorted { $0.date > $1.date }
    }
}

/// A capture or downloaded image/video in Library ▸ Media: thumbnail, name
/// and origin. Double-click opens it.
struct MediaRow: View {
    let item: MediaLibrary.Item
    /// Called once the file is moved to the Trash.
    let onDelete: () -> Void
    @Environment(\.palette) private var palette
    @State private var thumbnail: NSImage?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 36, alignment: .top)
                        .clipped()
                }
                if item.isVideo {
                    Image(systemName: "play.circle.fill").font(.system(size: 14)).foregroundStyle(.white).shadow(radius: 2)
                }
            }
            .frame(width: 56, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .task(id: item.url) { thumbnail = await Self.thumbnail(for: item.url) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.title)
                Text(item.isCapture ? "Capture" : "Download")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.subtitle)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isHovered ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([item.url as NSURL])
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Move to Trash", role: .destructive) {
                NSWorkspace.shared.recycle([item.url]) { _, _ in }
                onDelete()
            }
        }
        .padding(.horizontal, 12)
    }

    /// QuickLook thumbnail (images and videos), generated off the main thread.
    private static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 320, height: 220),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        return representation.nsImage
    }
}
