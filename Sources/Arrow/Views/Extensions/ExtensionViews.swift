import AppKit
import ArrowKit
import SwiftUI

/// Settings ▸ Extensions.
struct ExtensionsSettings: View {
    @State private var manager = ExtensionManager.shared
    @State private var reference = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Chrome Web Store link or extension ID", text: $reference)
                    Button("Add") { install() }
                        .disabled(reference.isEmpty || !manager.installing.isEmpty)
                    if !manager.installing.isEmpty { ProgressView().controlSize(.small) }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button("Open the Chrome Web Store") {
                    (NSApp.delegate as? AppDelegate)?.lastActiveBrowserWindow?.openNewTab("https://chromewebstore.google.com")
                }
            } header: {
                Text("Add an extension")
            } footer: {
                Text("Packages are downloaded from the Chrome Web Store and their signature is verified before installation.")
            }
            Section("Installed") {
                if manager.extensions.isEmpty {
                    Text("No extensions installed.").foregroundStyle(.secondary)
                }
                ForEach(manager.extensions) { item in
                    HStack(spacing: 10) {
                        if let icon = manager.iconImage(for: item) {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "puzzlepiece.extension").frame(width: 20, height: 20)
                        }
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text("Version \(item.version)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let options = manager.optionsURL(for: item) {
                            Button("Options") {
                                (NSApp.delegate as? AppDelegate)?.lastActiveBrowserWindow?.openNewTab(options)
                            }
                        }
                        Toggle("", isOn: Binding(get: { item.isEnabled }, set: { manager.setEnabled(item.id, $0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        Button(role: .destructive) { manager.remove(item.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            if manager.needsRelaunch {
                Section {
                    HStack {
                        Text("Relaunch Arrow to apply extension changes.")
                        Spacer()
                        Button("Relaunch") { manager.relaunch() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func install() {
        let value = reference
        Task {
            do {
                try await manager.install(value)
                reference = ""
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Extension actions available from the address field.
struct ExtensionsMenuButton: View {
    let controller: BrowserWindowController
    @State private var manager = ExtensionManager.shared

    var body: some View {
        let enabled = manager.extensions.filter(\.isEnabled)
        if !enabled.isEmpty {
            Menu {
                ForEach(enabled) { item in
                    Button(item.name) {
                        if let popup = manager.popupURL(for: item) {
                            ExtensionPopupController.show(url: popup, from: controller)
                        } else if let options = manager.optionsURL(for: item) {
                            controller.openNewTab(options)
                        }
                    }
                }
                Divider()
                Button("Manage Extensions…") { (NSApp.delegate as? AppDelegate)?.manageExtensions(nil) }
            } label: {
                Image(systemName: "puzzlepiece.extension")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Extensions")
        }
    }
}

/// Popover showing an extension's action popup, sized to its content.
@MainActor
final class ExtensionPopupController: NSObject, NSPopoverDelegate, CEFBrowserDelegate {
    private static var current: ExtensionPopupController?

    private let popover = NSPopover()
    private let engine: CEFBrowser

    static func show(url: String, from controller: BrowserWindowController) {
        current?.popover.close()
        guard let contentView = controller.window?.contentView else { return }
        let profileID = controller.selectedSpace?.profileID ?? controller.store.state.defaultProfile.id
        let popup = ExtensionPopupController(context: controller.store.requestContext(for: profileID))
        current = popup
        // Anchored under the sidebar address field.
        let width = controller.store.settings.sidebarWidth
        let top: CGFloat = 60
        let y = contentView.isFlipped ? top : contentView.bounds.height - top - 24
        let anchor = NSRect(x: width - 40, y: y, width: 24, height: 24)
        // Below the anchor: maxY is the bottom edge in a flipped view.
        popup.popover.show(relativeTo: anchor, of: contentView, preferredEdge: contentView.isFlipped ? .maxY : .minY)
        popup.engine.create(url: url)
        popup.engine.enableAutoResize(min: CGSize(width: 120, height: 60), max: CGSize(width: 800, height: 600))
    }

    private init(context: CEFRequestContext) {
        let size = CGSize(width: 360, height: 480)
        engine = CEFBrowser(requestContext: context, frame: CGRect(origin: .zero, size: size))
        super.init()
        engine.delegate = self
        let viewController = NSViewController()
        engine.hostView.autoresizingMask = [.width, .height]
        viewController.view = engine.hostView
        popover.contentViewController = viewController
        popover.contentSize = size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    func browser(_ browser: CEFBrowser, didAutoResize size: CGSize) {
        popover.contentSize = size
    }

    func browserWillClose(_ browser: CEFBrowser) {
        // window.close() from the popup page.
        if !browser.isClosing { popover.close() }
    }

    func popoverDidClose(_ notification: Notification) {
        engine.close(force: true)
        if Self.current === self { Self.current = nil }
    }
}

/// Banner offered on Chrome Web Store detail pages.
struct WebStoreBanner: View {
    let url: String
    @State private var manager = ExtensionManager.shared
    @State private var status: String?

    var body: some View {
        if url.contains("chromewebstore.google.com/detail/"), let id = ExtensionManager.extensionID(from: url) {
            let installed = manager.extensions.contains { $0.id == id }
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(.tint)
                Text(status ?? (installed ? "This extension is installed in Arrow." : "Install this extension in Arrow"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if manager.needsRelaunch {
                    Button("Relaunch") { manager.relaunch() }
                } else if !installed {
                    Button("Add to Arrow") {
                        Task {
                            do {
                                let item = try await manager.install(id)
                                status = "\(item.name) installed — relaunch to activate."
                            } catch {
                                status = error.localizedDescription
                            }
                        }
                    }
                    .disabled(manager.installing.contains(id))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(12)
            .frame(maxWidth: 560)
        }
    }
}
