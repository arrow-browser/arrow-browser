import CEF
import Foundation
#if os(Windows)
import WinSDK
#endif

/// Owns the Chromium (CEF) browser process: initialization, message loop and
/// shutdown.
public final class CEFRuntime: @unchecked Sendable {
    public static let shared = CEFRuntime()

    /// Directory holding every profile's data (cookies, cache, history…).
    /// Set before `initialize()` to use another one.
    public var rootCachePath: URL
    /// Called once the CEF context is ready (browsers may be created).
    public var onContextInitialized: (@MainActor () -> Void)?
    /// Arrow was launched again while running: receives the new launch's
    /// arguments (URLs to open). Chromium would otherwise open its own window.
    public var onRelaunch: (@MainActor (_ arguments: [String]) -> Void)?
    /// Extra command-line switches of the browser process (set before
    /// `initialize()`), e.g. `load-extension`.
    public var browserSwitches: [(name: String, value: String?)] = []

    private var app: CefHandler<cef_app_t>!
    private var browserProcessHandler: CefHandler<cef_browser_process_handler_t>!
    public private(set) var isInitialized = false

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootCachePath = support.appendingPathComponent("Arrow", isDirectory: true)

        app = CefHandler(owner: self) { app in
            app.on_before_command_line_processing = { app, processType, commandLine in
                defer { cefRelease(commandLine) }
                // Only the browser process (empty type) is customized.
                guard String(cef: processType).isEmpty, let commandLine,
                      let runtime = CefHandler.owner(of: app, as: CEFRuntime.self) else { return }
                // Picture-in-Picture for the automatic PiP of playing videos.
                CEFRuntime.appendSwitch(commandLine, "enable-features", value: "DocumentPictureInPictureAPI")
                // Cast device discovery (View ▸ Cast). Chromium otherwise waits for
                // a gesture in its own Cast dialog, which CEF doesn't include.
                CEFRuntime.appendSwitch(commandLine, "disable-features", value: "DelayMediaSinkDiscovery")
                #if os(Linux)
                // Browsers are hosted in X11 windows (XWayland under Wayland):
                // Chromium cannot embed its windows in a Wayland app's.
                CEFRuntime.appendSwitch(commandLine, "ozone-platform", value: "x11")
                #endif
                for item in runtime.browserSwitches {
                    CEFRuntime.appendSwitch(commandLine, item.name, value: item.value)
                }
            }
            app.get_browser_process_handler = { app in
                CefHandler.owner(of: app, as: CEFRuntime.self)?.browserProcessHandler.retained()
            }
        }

        browserProcessHandler = CefHandler(owner: self) { handler in
            handler.on_already_running_app_relaunch = { handler, commandLine, _ in
                defer { cefRelease(commandLine) }
                guard let runtime = CefHandler.owner(of: handler, as: CEFRuntime.self) else { return 1 }
                var arguments: [String] = []
                if let commandLine, let list = cef_string_list_alloc() {
                    commandLine.pointee.get_arguments?(commandLine, list)
                    arguments = cefStringList(list)
                    cef_string_list_free(list)
                }
                MainActor.assumeIsolated { runtime.onRelaunch?(arguments) }
                return 1
            }
            handler.on_context_initialized = { handler in
                guard let runtime = CefHandler.owner(of: handler, as: CEFRuntime.self) else { return }
                MainActor.assumeIsolated {
                    runtime.isInitialized = true
                    runtime.onContextInitialized?()
                }
            }
        }
    }

    private static func appendSwitch(_ commandLine: UnsafeMutablePointer<cef_command_line_t>, _ name: String, value: String? = nil) {
        withCefString(name) { name in
            if let value {
                withCefString(value) { value in
                    commandLine.pointee.append_switch_with_value?(commandLine, name, value)
                }
            } else {
                commandLine.pointee.append_switch?(commandLine, name)
            }
        }
    }

    /// Path of the default profile, which backs CEF's global request context.
    public var defaultProfilePath: URL {
        rootCachePath.appendingPathComponent("Default", isDirectory: true)
    }

    /// Runs this process as a Chromium subprocess (renderer, GPU…) if it is
    /// one, and returns its exit code; returns -1 in the browser process.
    /// On Windows and Linux, subprocesses relaunch the main executable, which
    /// calls this first. On macOS they are the helper apps.
    @MainActor
    public func executeProcess(sandboxInfo: UnsafeMutableRawPointer? = nil) -> Int32 {
        // Must be the first call into libcef.
        _ = cef_api_hash(Int32(CEF_API_VERSION), 0)
        var mainArgs = Self.mainArgs()
        return cef_execute_process(&mainArgs, app.retained(), sandboxInfo)
    }

    /// Initializes CEF in the browser process. Must be called on the main
    /// thread (on macOS, once the `NSApplication` subclass exists).
    /// `sandboxInfo` comes from CEF's bootstrap executable on Windows: without
    /// it, Windows subprocesses run unsandboxed.
    @MainActor
    public func initialize(sandboxInfo: UnsafeMutableRawPointer? = nil) -> Bool {
        // Must be the first call into libcef.
        _ = cef_api_hash(Int32(CEF_API_VERSION), 0)

        try? FileManager.default.createDirectory(at: defaultProfilePath, withIntermediateDirectories: true)
        #if os(macOS)
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Arrow", isDirectory: true)
        #else
        let logs = rootCachePath.appendingPathComponent("Logs", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        var settings = cef_settings_t()
        settings.size = MemoryLayout<cef_settings_t>.size
        #if os(Windows)
        settings.no_sandbox = sandboxInfo == nil ? 1 : 0
        #else
        settings.no_sandbox = 0
        #endif
        settings.persist_session_cookies = 1
        settings.log_severity = LOGSEVERITY_WARNING
        settings.background_color = 0xFFFF_FFFF
        settings.root_cache_path.set(rootCachePath.cefPath)
        settings.cache_path.set(defaultProfilePath.cefPath)
        settings.log_file.set(logs.appendingPathComponent("chromium.log").cefPath)
        settings.keychain_service_name.set("Arrow Safe Storage")
        settings.keychain_account_name.set("Arrow")
        #if os(macOS)
        if let frameworks = Bundle.main.privateFrameworksPath {
            settings.browser_subprocess_path.set("\(frameworks)/Arrow Helper.app/Contents/MacOS/Arrow Helper")
        }
        #endif
        settings.accept_language_list.set(Self.acceptLanguages)
        if let locale = Self.interfaceLocale {
            settings.locale.set(locale)
        }
        defer {
            settings.root_cache_path.clear()
            settings.cache_path.clear()
            settings.log_file.clear()
            settings.keychain_service_name.clear()
            settings.keychain_account_name.clear()
            settings.browser_subprocess_path.clear()
            settings.accept_language_list.clear()
            settings.locale.clear()
        }

        var mainArgs = Self.mainArgs()
        return cef_initialize(&mainArgs, &settings, app.retained(), sandboxInfo) != 0
    }

    private static func mainArgs() -> cef_main_args_t {
        #if os(Windows)
        cef_main_args_t(instance: GetModuleHandleW(nil))
        #else
        cef_main_args_t(argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
        #endif
    }

    /// Language of Chromium's own pages (Developer Tools, error pages, PDF
    /// viewer): the user's first language Chromium is translated into, named
    /// like its `.lproj` ("fr", "pt-BR").
    public static var interfaceLocale: String? {
        #if os(macOS)
        guard let frameworks = Bundle.main.privateFrameworksPath else { return nil }
        let resources = URL(fileURLWithPath: frameworks)
            .appendingPathComponent("Chromium Embedded Framework.framework/Resources", isDirectory: true)
        for identifier in Locale.preferredLanguages {
            let parts = identifier.split(separator: "-").map(String.init)
            for candidate in [parts.prefix(2).joined(separator: "_"), parts[0]] {
                if FileManager.default.fileExists(atPath: resources.appendingPathComponent("\(candidate).lproj").path) {
                    return candidate.replacingOccurrences(of: "_", with: "-")
                }
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    public static var acceptLanguages: String {
        let languages = Locale.preferredLanguages.flatMap { identifier -> [String] in
            let base = identifier.split(separator: "-").first.map(String.init) ?? identifier
            return base == identifier ? [identifier] : [identifier, base]
        }
        var seen = Set<String>()
        return languages.filter { seen.insert($0).inserted }.joined(separator: ",")
    }

    /// Runs the Chromium message loop (drives `NSApplication` on macOS) until
    /// `quitMessageLoop()` is called.
    @MainActor
    public func runMessageLoop() {
        #if !os(macOS)
        mainQueuePump.schedule()
        #endif
        cef_run_message_loop()
    }

    #if !os(macOS)
    private lazy var mainQueuePump = MainQueuePump()
    #endif

    @MainActor
    public func quitMessageLoop() {
        cef_quit_message_loop()
    }

    @MainActor
    public func shutdown() {
        cef_shutdown()
    }
}

#if !os(macOS)
/// Runs the main queue (main actor jobs, `DispatchQueue.main`) from a
/// repeating CEF task: on Windows and Linux, CEF's message loop does not run
/// Foundation's run loop, which does it on macOS.
private final class MainQueuePump: @unchecked Sendable {
    private var task: CefHandler<cef_task_t>!

    init() {
        task = CefHandler(owner: self) { task in
            task.execute = { task in
                guard let pump = CefHandler.owner(of: task, as: MainQueuePump.self) else { return }
                _ = RunLoop.main.run(mode: .default, before: Date())
                pump.schedule()
            }
        }
    }

    func schedule() {
        cef_post_delayed_task(TID_UI, task.retained(), 5)
    }
}
#endif
