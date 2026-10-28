import AppKit

/// Alternate app icons (Settings ▸ General ▸ App Icon), as in Arc.
///
/// While Arrow runs the Dock shows `NSApp.applicationIconImage`; when it is
/// not running, `DockTilePlugIn.plugin` reads the same choice.
@MainActor
enum AppIcons {
    static let names = ["Lavender", "Sunset", "Ocean", "Mint", "Graphite", "Paper"]
    /// Shared with the Dock tile plug-in (same defaults domain).
    static let defaultsKey = "ArrowAppIcon"
    static let changedNotification = Notification.Name("com.euskadi31.arrow.appIconChanged")

    static var selected: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? names[0]
    }

    static func image(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "AppIcons") else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Icon drawn inside Arrow (welcome screen, banners). `NSApp.applicationIconImage`
    /// gives the generic icon until an alternate one is set.
    static var current: NSImage {
        if selected != names[0], let image = image(selected) { return image }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    /// Applies the saved icon at launch.
    static func apply() {
        guard selected != names[0], let image = image(selected) else { return }
        NSApp.applicationIconImage = image
    }

    static func select(_ name: String) {
        UserDefaults.standard.set(name, forKey: defaultsKey)
        // The default icon comes from the bundle; nil restores it.
        NSApp.applicationIconImage = name == names[0] ? nil : image(name)
        DistributedNotificationCenter.default().postNotificationName(changedNotification, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
    }
}
