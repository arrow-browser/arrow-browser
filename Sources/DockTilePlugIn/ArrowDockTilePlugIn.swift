import AppKit

/// Shows the app icon chosen in Arrow's settings in the Dock while Arrow is
/// not running (NSDockTilePlugIn, loaded by the Dock).
@objc(ArrowDockTilePlugIn)
final class ArrowDockTilePlugIn: NSObject, NSDockTilePlugIn {
    private static let defaultsDomain = "com.euskadi31.arrow"
    private static let defaultsKey = "ArrowAppIcon"
    private static let changedNotification = Notification.Name("com.euskadi31.arrow.appIconChanged")

    private var dockTile: NSDockTile?
    private var observer: NSObjectProtocol?

    func setDockTile(_ dockTile: NSDockTile?) {
        self.dockTile = dockTile
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
        guard dockTile != nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.update()
        }
        update()
    }

    private func update() {
        guard let dockTile else { return }
        // The plug-in lives in Arrow.app/Contents/PlugIns/.
        let appBundle = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let name = UserDefaults(suiteName: Self.defaultsDomain)?.string(forKey: Self.defaultsKey)
        let url = name.map { appBundle.appendingPathComponent("Contents/Resources/AppIcons/\($0).png") }
        guard let url, let image = NSImage(contentsOf: url) else {
            dockTile.contentView = nil
            dockTile.display()
            return
        }
        let view = NSImageView(frame: NSRect(origin: .zero, size: dockTile.size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        dockTile.contentView = view
        dockTile.display()
    }
}
