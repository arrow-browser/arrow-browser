import AppKit
import ArrowCEF
import ArrowCore
import ArrowKit
import SwiftUI

/// Window of a sized `window.open()` popup (sign-in flows, payment…).
@MainActor
final class PopupWindowController: NSWindowController, NSWindowDelegate, BrowserEngineDelegate {
    let engine: CEFBrowser
    private weak var parent: BrowserWindowController?
    private weak var store: BrowserStore?

    init(context: CEFRequestContext, frame: CGRect, store: BrowserStore, parent: BrowserWindowController) {
        let size = NSSize(width: max(frame.width, 320), height: max(frame.height, 240))
        engine = CEFBrowser(requestContext: context, frame: CGRect(origin: .zero, size: size))
        self.parent = parent
        self.store = store
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        engine.delegate = self
        engine.hostView.autoresizingMask = [.width, .height]
        engine.hostView.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(engine.hostView)
        if let parentFrame = parent.window?.frame {
            window.setFrameOrigin(NSPoint(x: parentFrame.midX - size.width / 2, y: parentFrame.midY - size.height / 2))
        } else {
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !engine.isClosed else { return true }
        engine.close()
        return false
    }

    func browser(_ browser: any BrowserEngine, didChangeTitle title: String) {
        window?.title = title
    }

    func browser(_ browser: any BrowserEngine, didChangeAddress url: String) {
        window?.subtitle = URLDisplay.short(url)
    }

    func browser(_ browser: any BrowserEngine, createPopupFor url: String, disposition: WindowOpenDisposition,
                 userGesture: Bool, features: PopupFeatures) -> (any BrowserEngine)? {
        // Nested popups open as regular tabs of the parent window.
        parent?.openNewTab(url)
        return nil
    }

    func browserDidClose(_ browser: any BrowserEngine) {
        window?.close()
        parent?.popupClosed(self)
    }

    func browserWillClose(_ browser: any BrowserEngine) {
        if !browser.isClosing { window?.orderOut(nil) }
    }
}
