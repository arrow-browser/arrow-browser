// The smallest app on ArrowCEF: one window with one browser (see runShell).
#if os(Windows) || os(Linux)
import CEFShellCore
#if os(Windows)
import CRT
#endif
import Foundation

exit(MainActor.assumeIsolated { runShell(sandboxInfo: nil) })
#else
print("cef-shell runs on Windows and Linux. On macOS, run Arrow.")
#endif
