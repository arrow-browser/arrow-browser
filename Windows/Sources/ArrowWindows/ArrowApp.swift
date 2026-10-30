import ArrowCEF
import ArrowKit
import CRT
import Foundation
import WinSDK
import WinUI

/// The app: one window per address passed on the command line, or one with
/// the start page.
///
///   Arrow [url…]          browses
///   Arrow --smoke [url]   loads the page, prints its title and quits with
///                         status 0, or 1 if it does not load (CI, with
///                         bootstrapc.exe as Arrow.exe)
@MainActor
final class ArrowApp {
    static let startPage = "data:text/html;charset=utf-8,"
        + "<title>Arrow</title><h1>Arrow</h1><p>Arrow for Windows: WinUI 3 and Chromium.</p>"
        .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!

    fileprivate static var current: ArrowApp?

    private let addresses: [String]
    private let smoke: Bool
    private let sandboxed: Bool
    private var windows: [BrowserWindow] = []
    private var succeeded = false

    private init(arguments: [String], sandboxed: Bool) {
        addresses = URLInput.commandLineAddresses(arguments)
        smoke = arguments.contains("--smoke")
        self.sandboxed = sandboxed
    }

    /// Runs a Chromium subprocess, or the browser process until its last
    /// window closes. Returns the exit status.
    static func run(sandboxInfo: UnsafeMutableRawPointer?) -> Int32 {
        let runtime = CEFRuntime.shared
        // Chromium's subprocesses relaunch Arrow.exe.
        let status = runtime.executeProcess(sandboxInfo: sandboxInfo)
        if status >= 0 { return status }

        do {
            try WindowsAppRuntime.initialize()
        } catch {
            print("arrow: \(error)")
            return 1
        }
        // WinUI runs in a single-threaded apartment.
        RoInitialize(RO_INIT_SINGLETHREADED)

        // WinUI runs the message loop.
        let pump = MessagePump()
        runtime.usesExternalMessagePump = true
        runtime.onScheduleMessagePumpWork = pump.schedule
        guard runtime.initialize(sandboxInfo: sandboxInfo) else {
            print("arrow: CEF failed to initialize")
            return 1
        }
        let app = ArrowApp(arguments: Array(CommandLine.arguments.dropFirst()), sandboxed: sandboxInfo != nil)
        current = app
        do {
            try Application.start { _ in _ = ArrowApplication() }
        } catch {
            print("arrow: WinUI failed to start: \(error)")
        }
        current = nil
        runtime.shutdown()
        pump.invalidate()
        return app.smoke && !app.succeeded ? 1 : 0
    }

    fileprivate func launched() {
        for address in addresses.isEmpty ? [Self.startPage] : addresses {
            do {
                open(try BrowserWindow(url: address))
            } catch {
                print("arrow: the window failed to open: \(error)")
            }
        }
        if smoke {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                print("arrow: the page did not load within 60 seconds")
                exit(1)
            }
        }
    }

    private func open(_ window: BrowserWindow) {
        windows.append(window)
        window.onClose = { [weak self, weak window] in
            self?.windows.removeAll { $0 === window }
        }
        guard smoke else { return }
        window.onLoad = { [weak self, weak window] url, httpStatusCode in
            guard let self, let window, !succeeded else { return }
            Task {
                // A DevTools round trip, which also checks that main actor
                // jobs run.
                let title = await window.browser.evaluateJavaScript("document.title")
                print("arrow: loaded \(url.prefix(60)) (HTTP \(httpStatusCode)), "
                    + "title: \(title.map { "\($0)" } ?? "none"), hosted: \(window.isBrowserHosted ? "yes" : "no"), "
                    + "sandbox: \(sandboxed ? "on" : "off")")
                succeeded = title != nil && window.isBrowserHosted
                window.close()
            }
        }
    }
}

/// WinUI's application object, which opens the first windows once WinUI has
/// started.
final class ArrowApplication: XamlApplication {
    override func launched() {
        // WinUI starts on the main thread.
        MainActor.assumeIsolated { ArrowApp.current?.launched() }
    }
}
