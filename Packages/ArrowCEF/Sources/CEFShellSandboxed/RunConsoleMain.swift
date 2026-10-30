#if os(Windows)
import CEFShellCore

/// cef-shell as a DLL for CEF's bootstrapc.exe, which is renamed
/// cef-shell-sandboxed.exe, loads this DLL and hands it the sandbox.
@_cdecl("RunConsoleMain")
public func runConsoleMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                           _ sandboxInfo: UnsafeMutableRawPointer?, _ versionInfo: UnsafeMutableRawPointer?) -> Int32 {
    // The bootstrap calls this on the main thread.
    nonisolated(unsafe) let sandboxInfo = sandboxInfo
    return MainActor.assumeIsolated { runShell(sandboxInfo: sandboxInfo) }
}
#endif
