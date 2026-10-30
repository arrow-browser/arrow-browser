import AppKit
import ArrowCEF
import ArrowCore

// Arrow's entry point: the Chromium message loop drives NSApplication.

MainActor.assumeIsolated {
    let application = ArrowApplication.shared as! ArrowApplication // swiftlint:disable:this force_cast
    let runtime = CEFRuntime.shared
    if let extensions = ExtensionManager.loadExtensionArgument() {
        // Chromium ignores --load-extension unless this feature is disabled.
        runtime.browserSwitches = [
            ("load-extension", extensions),
            ("disable-features", "DisableLoadExtensionCommandLineSwitch"),
        ]
    }
    #if DEBUG
    // Debug builds are ad-hoc signed with a new signature at every build, so
    // the Keychain would ask again for "Arrow Safe Storage" each time. Release
    // builds keep encrypting cookies with the Keychain key.
    runtime.browserSwitches.append(("use-mock-keychain", nil))
    // For the same reason, Arrow's own Keychain items (saved passwords, cards)
    // written by a previous build fail to load instead of showing a Keychain
    // prompt. Looked up dynamically: the function is deprecated but has no
    // replacement for file-based keychains.
    typealias SetUserInteractionAllowed = @convention(c) (DarwinBoolean) -> OSStatus
    if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainSetUserInteractionAllowed") {
        _ = unsafeBitCast(symbol, to: SetUserInteractionAllowed.self)(false)
    }
    #endif

    guard runtime.initialize() else {
        // Also the normal path when Arrow is already running: Chromium hands
        // the launch over to the running instance (see onRelaunch).
        exit(0)
    }

    let delegate = AppDelegate()
    application.delegate = delegate
    application.terminationHandler = { delegate.shutdown() }

    runtime.runMessageLoop()

    delegate.didExitMessageLoop()
    runtime.shutdown()
}
exit(0)
