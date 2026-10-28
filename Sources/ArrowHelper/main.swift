// Entry point of the Chromium sub-processes (renderer, GPU, plugin, utility…).
//
// Mirrors CEF's CefScopedSandboxContext + CefScopedLibraryLoader in pure
// Swift: the macOS sandbox is entered first, then the CEF framework is loaded
// with dlopen so that no framework code runs outside of the sandbox.

import CEF
import Darwin
import MachO

private typealias SandboxInitialize = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> UnsafeMutableRawPointer?
private typealias SandboxDestroy = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias APIHash = @convention(c) (Int32, Int32) -> UnsafePointer<CChar>?
private typealias ExecuteProcess = @convention(c) (UnsafePointer<cef_main_args_t>?, UnsafeMutablePointer<cef_app_t>?, UnsafeMutableRawPointer?) -> Int32

private let frameworkRelativePath = "../../../Chromium Embedded Framework.framework"

private func executableDirectory() -> String? {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
    let path = String(cString: buffer)
    guard let slash = path.lastIndex(of: "/") else { return nil }
    return String(path[..<slash])
}

private func load(_ path: String) -> UnsafeMutableRawPointer? {
    guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST) else {
        fputs("dlopen \(path): \(String(cString: dlerror()))\n", stderr)
        return nil
    }
    return handle
}

private func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as _: T.Type) -> T? {
    guard let pointer = dlsym(handle, name) else {
        fputs("dlsym \(name): \(String(cString: dlerror()))\n", stderr)
        return nil
    }
    return unsafeBitCast(pointer, to: T.self)
}

guard let directory = executableDirectory() else {
    fputs("Arrow Helper does not have the expected bundle structure.\n", stderr)
    exit(1)
}
let framework = "\(directory)/\(frameworkRelativePath)"

// 1. Enter the sandbox before any CEF code is loaded.
guard let sandboxLibrary = load("\(framework)/Libraries/libcef_sandbox.dylib"),
      let sandboxInitialize = symbol(sandboxLibrary, "cef_sandbox_initialize", as: SandboxInitialize.self),
      let sandboxDestroy = symbol(sandboxLibrary, "cef_sandbox_destroy", as: SandboxDestroy.self),
      let sandboxContext = sandboxInitialize(CommandLine.argc, CommandLine.unsafeArgv)
else {
    exit(1)
}

// 2. Load the CEF framework and run the sub-process.
guard let cef = load("\(framework)/Chromium Embedded Framework"),
      let apiHash = symbol(cef, "cef_api_hash", as: APIHash.self),
      let executeProcess = symbol(cef, "cef_execute_process", as: ExecuteProcess.self)
else {
    sandboxDestroy(sandboxContext)
    exit(1)
}

// Configure the API version; must be the first call into libcef.
_ = apiHash(Int32(CEF_API_VERSION), 0)

var mainArgs = cef_main_args_t(argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
let exitCode = executeProcess(&mainArgs, nil, nil)

dlclose(cef)
sandboxDestroy(sandboxContext)
dlclose(sandboxLibrary)
exit(exitCode)
