import AppKit

// Protocols Chromium checks on NSApp (base/mac/scoped_sending_event.h and
// include/cef_application_mac.h). Their Objective-C names must match.

@MainActor @objc(CrAppProtocol)
protocol CrAppProtocol: NSObjectProtocol {
    @objc func isHandlingSendEvent() -> Bool
}

@MainActor @objc(CrAppControlProtocol)
protocol CrAppControlProtocol: CrAppProtocol {
    @objc func setHandlingSendEvent(_ handlingSendEvent: Bool)
}

@MainActor @objc(CefAppProtocol)
protocol CefAppProtocol: CrAppControlProtocol {}

/// Application object required by Chromium: tracks event dispatch and routes
/// termination through a clean browser shutdown.
@objc(ArrowApplication)
final class ArrowApplication: NSApplication, CefAppProtocol {
    private var handlingSendEvent = false

    /// Performs the graceful shutdown (close browsers, then quit the loop).
    var terminationHandler: (() -> Void)?

    func isHandlingSendEvent() -> Bool {
        handlingSendEvent
    }

    func setHandlingSendEvent(_ handlingSendEvent: Bool) {
        self.handlingSendEvent = handlingSendEvent
    }

    override func sendEvent(_ event: NSEvent) {
        let previous = handlingSendEvent
        handlingSendEvent = true
        defer { handlingSendEvent = previous }
        super.sendEvent(event)
    }

    /// Chromium must close its browsers before the process exits, so the
    /// default `terminate:` (which calls exit()) is replaced.
    override func terminate(_ sender: Any?) {
        if let delegate, delegate.applicationShouldTerminate?(self) == .terminateCancel {
            return
        }
        if let terminationHandler {
            terminationHandler()
        } else {
            super.terminate(sender)
        }
    }
}
