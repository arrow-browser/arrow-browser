#if os(Windows) || os(Linux)
import ArrowCEF
import ArrowEngine
import Foundation

/// A window showing one browser, which quits when the window is closed.
@MainActor
final class Shell: BrowserEngineDelegate {
    static let welcomePage = "data:text/html;charset=utf-8,"
        + "<title>Arrow CEF shell</title><h1>Arrow</h1><p>Chromium, embedded with ArrowCEF.</p>"
        .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!

    private let smoke: Bool
    private let browser: CEFBrowser
    private var window: ShellWindow?
    private(set) var succeeded = false

    init(smoke: Bool) {
        self.smoke = smoke
        browser = CEFBrowser(requestContext: .global(), frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        browser.delegate = self
    }

    func open(_ url: String) {
        let window = ShellWindow(title: "Arrow", width: 1024, height: 768,
                                 onResize: { [browser] bounds in browser.hostWindow.setFrame(bounds) },
                                 onClose: { [browser] in browser.close(force: false) })
        self.window = window
        browser.hostWindow.attach(to: window.handle, frame: window.contentBounds)
        browser.create(url: url)
        if smoke {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                print("cef-shell: the page did not load within 60 seconds")
                exit(1)
            }
        }
    }

    func browser(_ engine: any BrowserEngine, didFinishLoad url: String, httpStatusCode: Int) {
        guard smoke, !succeeded else { return }
        Task {
            // A DevTools round trip, which also checks that main actor jobs run.
            let title = await browser.evaluateJavaScript("document.title")
            print("cef-shell: loaded \(url.prefix(60)) (HTTP \(httpStatusCode)), title: \(title.map { "\($0)" } ?? "none")")
            succeeded = title != nil
            browser.close(force: true)
        }
    }

    func browserDidClose(_ engine: any BrowserEngine) {
        window?.destroy()
        window = nil
        CEFRuntime.shared.quitMessageLoop()
    }
}
#endif
