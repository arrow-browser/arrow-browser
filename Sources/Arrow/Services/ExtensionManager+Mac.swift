import AppKit
import ArrowCore

extension ExtensionManager {
    func iconImage(for installed: Extension) -> NSImage? {
        iconURL(for: installed).flatMap(NSImage.init(contentsOf:))
    }

    /// Restarts Arrow so Chromium loads the new extension set.
    func relaunch() {
        let bundle = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"\(bundle)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
    }
}
