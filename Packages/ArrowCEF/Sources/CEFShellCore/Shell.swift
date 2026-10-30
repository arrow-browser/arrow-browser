#if os(Windows) || os(Linux)
import ArrowCEF
import ArrowEngine
#if os(Windows)
import CRT
#endif
import Foundation

/// A window showing one browser, which quits when the window is closed.
@MainActor
final class Shell: BrowserEngineDelegate {
    static let welcomePage = "data:text/html;charset=utf-8,"
        + "<title>Arrow CEF shell</title><h1>Arrow</h1><p>Chromium, embedded with ArrowCEF.</p>"
        .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!

    let smoke: Bool
    private let sandboxed: Bool
    private let browser: CEFBrowser
    private var window: ShellWindow?
    private(set) var succeeded = false

    init(smoke: Bool, sandboxed: Bool) {
        self.smoke = smoke
        self.sandboxed = sandboxed
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
            print("cef-shell: loaded \(url.prefix(60)) (HTTP \(httpStatusCode)), title: \(title.map { "\($0)" } ?? "none"), "
                + "sandbox: \(sandboxed ? "on" : "off")")
            succeeded = title != nil
            browser.close(force: true)
        }
    }

    func browser(_ engine: any BrowserEngine, didFailLoad url: String, errorCode: Int, errorText: String) {
        print("cef-shell: \(url.prefix(60)) failed to load: \(errorText) (\(errorCode))")
    }

    func browser(_ engine: any BrowserEngine, rendererDidTerminate status: TerminationStatus) {
        print("cef-shell: the renderer process ended: \(status)")
    }

    func browserDidClose(_ engine: any BrowserEngine) {
        window?.destroy()
        window = nil
        CEFRuntime.shared.quitMessageLoop()
    }
}
#endif
