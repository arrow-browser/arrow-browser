import CEF
import Foundation

/// Client of a Developer Tools window that selects one of its panels once
/// the frontend has loaded (`DevToolsAPI.showPanel`, the embedder API of
/// Chrome's DevTools).
final class CEFDevToolsPanel: @unchecked Sendable {
    private let panel: String
    private var client: CefHandler<cef_client_t>!
    private var loadHandler: CefHandler<cef_load_handler_t>!
    /// Openers wait for their window's first load.
    @MainActor private static var pending: [CEFDevToolsPanel] = []

    @MainActor
    static func client(showing panel: String) -> UnsafeMutablePointer<cef_client_t> {
        let opener = CEFDevToolsPanel(panel: panel)
        pending.append(opener)
        return opener.client.retained()
    }

    private init(panel: String) {
        self.panel = panel
        loadHandler = CefHandler(owner: self) { handler in
            handler.on_load_end = { handler, browser, frame, _ in
                defer {
                    cefRelease(browser)
                    cefRelease(frame)
                }
                guard let opener = CefHandler.owner(of: handler, as: CEFDevToolsPanel.self),
                      let frame, frame.pointee.is_main?(frame) == 1 else { return }
                // The frontend sets up InspectorFrontendAPI after its page has loaded.
                let script = """
                (function show(attempt) {
                  if (window.InspectorFrontendAPI) { setTimeout(() => DevToolsAPI.showPanel(\(String(reflecting: opener.panel))), 200); }
                  else if (attempt < 100) { setTimeout(() => show(attempt + 1), 100); }
                })(0);
                """
                withCefString(script) { code in
                    withCefString("devtools://devtools/arrow") { url in
                        frame.pointee.execute_java_script?(frame, code, url, 0)
                    }
                }
                MainActor.assumeIsolated { CEFDevToolsPanel.pending.removeAll { $0 === opener } }
            }
        }
        client = CefHandler(owner: self) { client in
            client.get_load_handler = { CefHandler.owner(of: $0, as: CEFDevToolsPanel.self)?.loadHandler.retained() }
        }
    }
}
