#if os(Windows)
import CEF
import Foundation
import WinSDK

/// Child window hosting a Chromium browser. Keeps CEF's child window sized
/// to it. The app puts it in its own window with `attach(to:frame:)`.
@MainActor
public final class CEFHostWindow {
    public let handle: HWND
    /// Radius of the window's corners, in pixels: the app's rounded content
    /// panel. The browser is clipped to them.
    public var cornerRadius: Int32 = 0 {
        didSet {
            if cornerRadius != oldValue { updateShape() }
        }
    }

    public init(frame: CGRect) {
        handle = CEFHostWindow.create(
            style: DWORD(WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS),
            frame: frame, parent: CEFParkingLot.window)
    }

    isolated deinit {
        DestroyWindow(handle)
    }

    /// Shows the browser in `parent` (a window of the app).
    public func attach(to parent: HWND, frame: CGRect) {
        SetParent(handle, parent)
        setFrame(frame)
    }

    /// Takes the browser out of the app's window; it keeps rendering.
    public func detach() {
        SetParent(handle, CEFParkingLot.window)
    }

    /// Resizing the host resizes the browser (WM_SIZE).
    public func setFrame(_ frame: CGRect) {
        SetWindowPos(handle, nil, Int32(frame.minX), Int32(frame.minY), Int32(frame.width), Int32(frame.height),
                     UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        updateShape()
    }

    private func updateShape() {
        guard cornerRadius > 0 else {
            SetWindowRgn(handle, nil, true)
            return
        }
        var client = RECT()
        GetClientRect(handle, &client)
        // The window owns the region once it has it.
        let region = CreateRoundRectRgn(0, 0, client.right + 1, client.bottom + 1, cornerRadius * 2, cornerRadius * 2)
        SetWindowRgn(handle, region, true)
    }

    /// Where CEF creates the browser: a child of this window.
    func windowInfo() -> cef_window_info_t {
        var client = RECT()
        GetClientRect(handle, &client)
        var windowInfo = cef_window_info_t()
        windowInfo.size = MemoryLayout<cef_window_info_t>.size
        windowInfo.style = DWORD(WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS | WS_TABSTOP | WS_VISIBLE)
        windowInfo.parent_window = handle
        windowInfo.bounds = cef_rect_t(x: 0, y: 0, width: client.right - client.left, height: client.bottom - client.top)
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY
        return windowInfo
    }

    /// Destroys the browser's window, which completes the browser's close.
    func destroyBrowserView() {
        while let child = GetWindow(handle, UINT(GW_CHILD)), DestroyWindow(child) {}
    }

    func leaveParkingLot() {}

    // MARK: - Window class

    private static let className = Array("ArrowCEFHost".utf16) + [0]

    static func create(style: DWORD, frame: CGRect, parent: HWND?) -> HWND {
        registerClass()
        let instance = GetModuleHandleW(nil)
        return className.withUnsafeBufferPointer { name in
            CreateWindowExW(0, name.baseAddress, nil, style, Int32(frame.minX), Int32(frame.minY),
                            Int32(max(frame.width, 1)), Int32(max(frame.height, 1)), parent, nil, instance, nil)!
        }
    }

    private static let registerClass: () -> Void = {
        var windowClass = WNDCLASSEXW()
        windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        windowClass.lpfnWndProc = hostWindowProcedure
        windowClass.hInstance = GetModuleHandleW(nil)
        className.withUnsafeBufferPointer { name in
            windowClass.lpszClassName = name.baseAddress
            RegisterClassExW(&windowClass)
        }
        return {}
    }()
}

private func hostWindowProcedure(_ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch Int32(message) {
    case WM_SIZE:
        // Keep the browser window the size of the host.
        var client = RECT()
        GetClientRect(window, &client)
        if let child = GetWindow(window, UINT(GW_CHILD)) {
            SetWindowPos(child, nil, 0, 0, client.right - client.left, client.bottom - client.top,
                         UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        }
        return 0
    case WM_ERASEBKGND:
        // The browser paints the whole window.
        return 1
    default:
        return DefWindowProcW(window, message, wParam, lParam)
    }
}

/// Hidden window holding browser windows that are not displayed, so
/// Chromium always has a parent window to create them in.
@MainActor
enum CEFParkingLot {
    static let window: HWND = CEFHostWindow.create(
        style: DWORD(WS_OVERLAPPED | WS_CLIPCHILDREN), frame: CGRect(x: 0, y: 0, width: 1280, height: 800), parent: nil)
}

extension cef_window_info_t {
    /// A window of its own (Developer Tools).
    static func topLevel(bounds: cef_rect_t) -> cef_window_info_t {
        var info = cef_window_info_t()
        info.size = MemoryLayout<cef_window_info_t>.size
        // WS_OVERLAPPEDWINDOW is imported as UInt32, the other styles as Int32.
        info.style = DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN | WS_CLIPSIBLINGS | WS_VISIBLE)
        info.bounds = bounds
        info.runtime_style = CEF_RUNTIME_STYLE_ALLOY
        return info
    }

    /// A popup's window info, from the browser that will display it.
    mutating func adoptHost(of info: cef_window_info_t) {
        style = info.style
        ex_style = info.ex_style
        parent_window = info.parent_window
        bounds = info.bounds
        runtime_style = CEF_RUNTIME_STYLE_ALLOY
    }
}
#endif
