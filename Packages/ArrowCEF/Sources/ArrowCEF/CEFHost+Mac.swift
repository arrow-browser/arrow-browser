#if os(macOS)
import AppKit
import CEF

/// NSView hosting a Chromium browser view. Keeps CEF's child view sized to
/// its bounds and clips it (rounded corners of the content panel).
public final class CEFHostView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var isFlipped: Bool { true }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        for subview in subviews where subview.frame != bounds {
            subview.frame = bounds
        }
    }
}

/// Invisible window holding browser views that are not displayed.
///
/// Chromium needs its view to belong to a window when the browser is created
/// and while it renders in the background (tabs opened in the background,
/// switched-away tabs). Views are parked here instead of being orphaned.
@MainActor
public enum CEFParkingLot {
    private static let window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        return window
    }()

    public static func park(_ view: NSView) {
        guard let contentView = window.contentView, view.superview !== contentView else { return }
        let size = view.frame.size == .zero ? contentView.bounds.size : view.frame.size
        view.removeFromSuperview()
        view.frame = NSRect(origin: .zero, size: size)
        contentView.addSubview(view)
    }

    public static func isParked(_ view: NSView) -> Bool {
        view.superview === window.contentView
    }
}

extension CEFHostView {
    /// Where CEF creates the browser: this view, parked in a window if it
    /// has none.
    @MainActor
    func windowInfo() -> cef_window_info_t {
        if window == nil { CEFParkingLot.park(self) }
        var windowInfo = cef_window_info_t()
        windowInfo.size = MemoryLayout<cef_window_info_t>.size
        windowInfo.parent_view = Unmanaged.passUnretained(self).toOpaque()
        windowInfo.bounds = cef_rect_t(x: 0, y: 0, width: Int32(bounds.width), height: Int32(bounds.height))
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY
        return windowInfo
    }

    /// Destroys the browser view, which completes the browser's close.
    @MainActor
    func destroyBrowserView() {
        for subview in subviews {
            subview.removeFromSuperview()
        }
    }

    @MainActor
    func leaveParkingLot() {
        if CEFParkingLot.isParked(self) { removeFromSuperview() }
    }
}

extension cef_window_info_t {
    /// A window of its own (Developer Tools).
    static func topLevel(bounds: cef_rect_t) -> cef_window_info_t {
        var info = cef_window_info_t()
        info.size = MemoryLayout<cef_window_info_t>.size
        info.bounds = bounds
        info.runtime_style = CEF_RUNTIME_STYLE_ALLOY
        return info
    }

    /// A popup's window info, from the browser that will display it.
    mutating func adoptHost(of info: cef_window_info_t) {
        parent_view = info.parent_view
        bounds = info.bounds
        runtime_style = CEF_RUNTIME_STYLE_ALLOY
    }
}
#endif
