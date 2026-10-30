#if os(Linux)
import CEF
import CX11
import Foundation

/// The X11 connection Arrow's own windows use. Chromium has its own; X11
/// window IDs are shared by every client of the server.
@MainActor
public enum CEFX11 {
    public static let display: OpaquePointer = {
        guard let display = XOpenDisplay(nil) else {
            fatalError("Cannot open the X11 display (DISPLAY=\(ProcessInfo.processInfo.environment["DISPLAY"] ?? ""))")
        }
        return display
    }()
}

/// X11 window hosting a Chromium browser. Keeps CEF's child window sized to
/// it. The app puts it in its own window with `attach(to:frame:)`.
@MainActor
public final class CEFHostWindow {
    public let handle: UInt
    private var size: (width: UInt32, height: UInt32)

    public init(frame: CGRect) {
        size = (UInt32(max(frame.width, 1)), UInt32(max(frame.height, 1)))
        handle = XCreateSimpleWindow(CEFX11.display, CEFParkingLot.window, 0, 0, size.width, size.height, 0, 0, 0)
        XMapWindow(CEFX11.display, handle)
        XFlush(CEFX11.display)
    }

    isolated deinit {
        XDestroyWindow(CEFX11.display, handle)
        XFlush(CEFX11.display)
    }

    /// Shows the browser in `parent` (an X11 window of the app).
    public func attach(to parent: UInt, frame: CGRect) {
        XReparentWindow(CEFX11.display, handle, parent, Int32(frame.minX), Int32(frame.minY))
        setFrame(frame)
    }

    /// Takes the browser out of the app's window; it keeps rendering.
    public func detach() {
        XReparentWindow(CEFX11.display, handle, CEFParkingLot.window, 0, 0)
        XFlush(CEFX11.display)
    }

    public func setFrame(_ frame: CGRect) {
        size = (UInt32(max(frame.width, 1)), UInt32(max(frame.height, 1)))
        XMoveResizeWindow(CEFX11.display, handle, Int32(frame.minX), Int32(frame.minY), size.width, size.height)
        for child in children() {
            XMoveResizeWindow(CEFX11.display, child, 0, 0, size.width, size.height)
        }
        XFlush(CEFX11.display)
    }

    private func children() -> [UInt] {
        var root: UInt = 0
        var parent: UInt = 0
        var list: UnsafeMutablePointer<UInt>?
        var count: UInt32 = 0
        guard XQueryTree(CEFX11.display, handle, &root, &parent, &list, &count) != 0, let list else { return [] }
        defer { XFree(list) }
        return Array(UnsafeBufferPointer(start: list, count: Int(count)))
    }

    /// Where CEF creates the browser: a child of this window.
    func windowInfo() -> cef_window_info_t {
        var windowInfo = cef_window_info_t()
        windowInfo.size = MemoryLayout<cef_window_info_t>.size
        windowInfo.parent_window = handle
        windowInfo.bounds = cef_rect_t(x: 0, y: 0, width: Int32(size.width), height: Int32(size.height))
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY
        return windowInfo
    }

    func leaveParkingLot() {}
}

/// Unmapped window holding browser windows that are not displayed, so
/// Chromium always has a parent window to create them in.
@MainActor
enum CEFParkingLot {
    static let window: UInt = XCreateSimpleWindow(
        CEFX11.display, XDefaultRootWindow(CEFX11.display), 0, 0, 1280, 800, 0, 0, 0)
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
        parent_window = info.parent_window
        bounds = info.bounds
        runtime_style = CEF_RUNTIME_STYLE_ALLOY
    }
}
#endif
