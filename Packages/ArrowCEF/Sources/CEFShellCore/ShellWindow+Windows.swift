#if os(Windows)
import Foundation
import WinSDK

/// A top-level Win32 window.
@MainActor
final class ShellWindow {
    let handle: HWND
    fileprivate let onResize: (CGRect) -> Void
    fileprivate let onClose: () -> Void
    fileprivate static var windows: [HWND: ShellWindow] = [:]

    init(title: String, width: Int, height: Int, onResize: @escaping (CGRect) -> Void, onClose: @escaping () -> Void) {
        self.onResize = onResize
        self.onClose = onClose
        Self.registerClass()
        let useDefault = Int32(bitPattern: 0x8000_0000)  // CW_USEDEFAULT
        let style = DWORD(WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX
            | WS_CLIPCHILDREN | WS_VISIBLE)
        let title = Array(title.utf16) + [0]
        handle = Self.className.withUnsafeBufferPointer { name in
            title.withUnsafeBufferPointer { title in
                CreateWindowExW(0, name.baseAddress, title.baseAddress, style, useDefault, useDefault,
                                Int32(width), Int32(height), nil, nil, GetModuleHandleW(nil), nil)!
            }
        }
        Self.windows[handle] = self
    }

    var contentBounds: CGRect {
        var client = RECT()
        GetClientRect(handle, &client)
        return CGRect(x: 0, y: 0, width: Int(client.right - client.left), height: Int(client.bottom - client.top))
    }

    func destroy() {
        Self.windows[handle] = nil
        DestroyWindow(handle)
    }

    private static let className = Array("ArrowCEFShell".utf16) + [0]

    private static let registerClass: () -> Void = {
        var windowClass = WNDCLASSEXW()
        windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        windowClass.lpfnWndProc = shellWindowProcedure
        windowClass.hInstance = GetModuleHandleW(nil)
        windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))  // IDC_ARROW
        className.withUnsafeBufferPointer { name in
            windowClass.lpszClassName = name.baseAddress
            RegisterClassExW(&windowClass)
        }
        return {}
    }()
}
private func shellWindowProcedure(_ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    // Window messages are dispatched on the main thread.
    nonisolated(unsafe) let window = window
    let handled: Bool = MainActor.assumeIsolated {
        guard let window, let shell = ShellWindow.windows[window] else { return false }
        switch Int32(message) {
        case WM_SIZE:
            shell.onResize(shell.contentBounds)
            return true
        case WM_CLOSE:
            // The window is destroyed once the browser has closed.
            shell.onClose()
            return true
        default:
            return false
        }
    }
    return handled ? 0 : DefWindowProcW(window, message, wParam, lParam)
}
#endif
