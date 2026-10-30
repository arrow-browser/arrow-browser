import WinSDK

// Arrow.dll's entry points. CEF's bootstrap executable, renamed Arrow.exe,
// calls one on the main thread with the sandbox of Chromium's subprocesses:
// bootstrap.exe (the app) RunWinMain, bootstrapc.exe (a console, for CI and
// debugging) RunConsoleMain.

@_cdecl("RunWinMain")
public func runWinMain(_ instance: HINSTANCE?, _ commandLine: LPWSTR?, _ showCommand: Int32,
                       _ sandboxInfo: UnsafeMutableRawPointer?, _ versionInfo: UnsafeMutableRawPointer?) -> Int32 {
    nonisolated(unsafe) let sandboxInfo = sandboxInfo
    return MainActor.assumeIsolated { ArrowApp.run(sandboxInfo: sandboxInfo) }
}

@_cdecl("RunConsoleMain")
public func runConsoleMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                           _ sandboxInfo: UnsafeMutableRawPointer?, _ versionInfo: UnsafeMutableRawPointer?) -> Int32 {
    nonisolated(unsafe) let sandboxInfo = sandboxInfo
    return MainActor.assumeIsolated { ArrowApp.run(sandboxInfo: sandboxInfo) }
}
