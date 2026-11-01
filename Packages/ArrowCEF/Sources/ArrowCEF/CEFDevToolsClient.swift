import CEF
import Foundation
#if os(Windows)
import WinSDK
#endif

/// Client of a Developer Tools window. It selects the panel asked for once
/// the frontend has loaded (`DevToolsAPI.showPanel`, the embedder API of
/// Chrome's DevTools). On Windows, where CEF leaves the window untitled at
/// the screen's top-left corner, it also names the window after the page
/// ("DevTools - example.com/"), gives it the app's icon and centers it on
/// the screen of the window it was opened from.
public final class CEFDevToolsClient: @unchecked Sendable {
    private var panel: String?
    #if os(Windows)
    private let openerWindow = GetForegroundWindow()
    private var window: HWND?
    #endif
    private var client: CefHandler<cef_client_t>!
    private var loadHandler: CefHandler<cef_load_handler_t>!
    private var lifeSpanHandler: CefHandler<cef_life_span_handler_t>!
    private var displayHandler: CefHandler<cef_display_handler_t>!
    /// Clients live as long as their window.
    @MainActor private static var open: [CEFDevToolsClient] = []

    @MainActor
    public static func client(showing panel: String?) -> UnsafeMutablePointer<cef_client_t> {
        let devTools = CEFDevToolsClient(panel: panel)
        open.append(devTools)
        return devTools.client.retained()
    }

    // swiftlint:disable:next function_body_length
    private init(panel: String?) {
        self.panel = panel
        loadHandler = CefHandler(owner: self) { handler in
            handler.on_load_end = { handler, browser, frame, _ in
                defer {
                    cefRelease(browser)
                    cefRelease(frame)
                }
                guard let devTools = CefHandler.owner(of: handler, as: CEFDevToolsClient.self), let panel = devTools.panel,
                      let frame, frame.pointee.is_main?(frame) == 1 else { return }
                devTools.panel = nil
                // The frontend sets up InspectorFrontendAPI after its page has loaded.
                let script = """
                (function show(attempt) {
                  if (window.InspectorFrontendAPI) { setTimeout(() => DevToolsAPI.showPanel(\(String(reflecting: panel))), 200); }
                  else if (attempt < 100) { setTimeout(() => show(attempt + 1), 100); }
                })(0);
                """
                withCefString(script) { code in
                    withCefString("devtools://devtools/arrow") { url in
                        frame.pointee.execute_java_script?(frame, code, url, 0)
                    }
                }
            }
        }
        lifeSpanHandler = CefHandler(owner: self) { handler in
            handler.on_after_created = { handler, browser in
                defer { cefRelease(browser) }
                #if os(Windows)
                guard let devTools = CefHandler.owner(of: handler, as: CEFDevToolsClient.self), let browser,
                      let host = CefRef(adopting: browser.pointee.get_host?(browser)),
                      let window = host.pointee.get_window_handle?(host.pointer) else { return }
                devTools.window = GetAncestor(window, UINT(GA_ROOT))
                MainActor.assumeIsolated { devTools.setUpWindow() }
                #endif
            }
            handler.on_before_close = { handler, browser in
                defer { cefRelease(browser) }
                guard let devTools = CefHandler.owner(of: handler, as: CEFDevToolsClient.self) else { return }
                MainActor.assumeIsolated { CEFDevToolsClient.open.removeAll { $0 === devTools } }
            }
        }
        displayHandler = CefHandler(owner: self) { handler in
            handler.on_title_change = { handler, browser, title in
                defer { cefRelease(browser) }
                #if os(Windows)
                guard let devTools = CefHandler.owner(of: handler, as: CEFDevToolsClient.self) else { return }
                nonisolated(unsafe) let window = devTools.window
                let text = Array(String(cef: title).utf16) + [0]
                MainActor.assumeIsolated {
                    guard let window else { return }
                    CEFDevToolsClient.titles[window] = text
                    SetWindowTextW(window, text)
                }
                #endif
            }
        }
        client = CefHandler(owner: self) { client in
            client.get_load_handler = { CefHandler.owner(of: $0, as: CEFDevToolsClient.self)?.loadHandler.retained() }
            client.get_life_span_handler = { CefHandler.owner(of: $0, as: CEFDevToolsClient.self)?.lifeSpanHandler.retained() }
            #if os(Windows)
            client.get_display_handler = { CefHandler.owner(of: $0, as: CEFDevToolsClient.self)?.displayHandler.retained() }
            #endif
        }
    }

    #if os(Windows)
    /// The page's title of each window, which Chromium would empty, and the
    /// window procedure `keepTitle` stands in front of.
    @MainActor fileprivate static var titles: [HWND: [UInt16]] = [:]
    @MainActor fileprivate static var procedures: [HWND: WNDPROC] = [:]

    @MainActor
    private func setUpWindow() {
        guard let window else { return }
        let previous = SetWindowLongPtrW(window, GWLP_WNDPROC, unsafeBitCast(keepTitle as WNDPROC, to: LONG_PTR.self))
        Self.procedures[window] = unsafeBitCast(previous, to: WNDPROC.self)
        let dpi = GetDpiForWindow(openerWindow ?? window)
        var monitor = MONITORINFO()
        monitor.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        GetMonitorInfoW(MonitorFromWindow(openerWindow ?? window, DWORD(MONITOR_DEFAULTTONEAREST)), &monitor)
        let area = monitor.rcWork
        let width = min(MulDiv(1000, Int32(dpi), 96), area.right - area.left)
        let height = min(MulDiv(720, Int32(dpi), 96), area.bottom - area.top)
        SetWindowPos(window, nil, area.left + (area.right - area.left - width) / 2, area.top + (area.bottom - area.top - height) / 2,
                     width, height, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        // CEF's bootstrap, which Arrow.exe is, names its icon IDI_APPLICATION.
        for (kind, metric) in [(ICON_BIG, SM_CXICON), (ICON_SMALL, SM_CXSMICON)] {
            let size = GetSystemMetricsForDpi(metric, dpi)
            if let icon = LoadImageW(GetModuleHandleW(nil), UnsafePointer(bitPattern: 32512), UINT(IMAGE_ICON), size, size, 0) {
                SendMessageW(window, UINT(WM_SETICON), WPARAM(kind), LPARAM(Int(bitPattern: icon)))
            }
        }
    }
    #endif
}

#if os(Windows)
/// Window procedure of Developer Tools windows: gives every title Chromium
/// sets (an empty one, after the page names the window) the page's title.
private func keepTitle(_ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    nonisolated(unsafe) let window = window
    return MainActor.assumeIsolated {
        guard let window, let procedure = CEFDevToolsClient.procedures[window] else {
            return DefWindowProcW(window, message, wParam, lParam)
        }
        switch Int32(message) {
        case WM_SETTEXT:
            if var title = CEFDevToolsClient.titles[window] {
                return title.withUnsafeMutableBufferPointer {
                    CallWindowProcW(procedure, window, message, wParam, LPARAM(Int(bitPattern: $0.baseAddress)))
                }
            }
        case WM_NCDESTROY:
            SetWindowLongPtrW(window, GWLP_WNDPROC, unsafeBitCast(procedure, to: LONG_PTR.self))
            CEFDevToolsClient.procedures[window] = nil
            CEFDevToolsClient.titles[window] = nil
        default:
            break
        }
        return CallWindowProcW(procedure, window, message, wParam, lParam)
    }
}
#endif
