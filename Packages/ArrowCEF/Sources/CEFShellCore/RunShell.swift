#if os(Windows) || os(Linux)
import ArrowCEF
import Foundation

/// Runs cef-shell: a Chromium subprocess, or the browser process until its
/// window closes. Returns the exit status.
///
///   cef-shell [url]          browses url (a built-in page by default)
///   cef-shell --smoke [url]  loads the page, prints its title and quits with
///                            status 0, or 1 if it does not load (CI)
///
/// `sandboxInfo` comes from CEF's bootstrap executable on Windows.
@MainActor
public func runShell(sandboxInfo: UnsafeMutableRawPointer?) -> Int32 {
    let runtime = CEFRuntime.shared
    // Chromium's subprocesses relaunch this executable.
    let status = runtime.executeProcess(sandboxInfo: sandboxInfo)
    if status >= 0 { return status }

    let arguments = CommandLine.arguments.dropFirst()
    let url = arguments.first { !$0.hasPrefix("-") } ?? Shell.welcomePage
    #if os(Windows)
    let sandboxed = sandboxInfo != nil
    #else
    let sandboxed = !arguments.contains("--no-sandbox")
    #endif

    runtime.rootCachePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("arrow-cef-shell", isDirectory: true)
    guard runtime.initialize(sandboxInfo: sandboxInfo) else {
        print("cef-shell: CEF failed to initialize")
        return 1
    }
    let shell = Shell(smoke: arguments.contains("--smoke"), sandboxed: sandboxed)
    shell.open(url)
    runtime.runMessageLoop()
    runtime.shutdown()
    return shell.smoke && !shell.succeeded ? 1 : 0
}
#endif
