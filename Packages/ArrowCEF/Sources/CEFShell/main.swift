// The smallest app on ArrowCEF: one window with one browser.
//
//   cef-shell [url]          browses url (a built-in page by default)
//   cef-shell --smoke [url]  loads the page, prints its title and quits with
//                            status 0, or 1 if it does not load (CI)
#if os(Windows) || os(Linux)
import ArrowCEF
#if os(Windows)
import CRT
#endif
import Foundation

MainActor.assumeIsolated {
    let runtime = CEFRuntime.shared
    // Chromium's subprocesses relaunch this executable.
    let status = runtime.executeProcess()
    if status >= 0 { exit(status) }

    let arguments = CommandLine.arguments.dropFirst()
    let smoke = arguments.contains("--smoke")
    let url = arguments.first { !$0.hasPrefix("-") } ?? Shell.welcomePage

    runtime.rootCachePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("arrow-cef-shell", isDirectory: true)
    guard runtime.initialize() else {
        print("cef-shell: CEF failed to initialize")
        exit(1)
    }
    let shell = Shell(smoke: smoke)
    shell.open(url)
    runtime.runMessageLoop()
    runtime.shutdown()
    exit(smoke && !shell.succeeded ? 1 : 0)
}
#else
print("cef-shell runs on Windows and Linux. On macOS, run Arrow.")
#endif
