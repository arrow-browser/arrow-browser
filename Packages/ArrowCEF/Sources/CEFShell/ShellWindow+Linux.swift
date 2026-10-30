#if os(Linux)
import ArrowCEF
import CX11
import Foundation

/// A top-level X11 window.
@MainActor
final class ShellWindow {
    let handle: UInt
    private(set) var contentBounds: CGRect
    private let onResize: (CGRect) -> Void
    private let onClose: () -> Void
    private var deleteAtom: Atom
    private var eventTimer: DispatchSourceTimer?

    init(title: String, width: Int, height: Int, onResize: @escaping (CGRect) -> Void, onClose: @escaping () -> Void) {
        let display = CEFX11.display
        contentBounds = CGRect(x: 0, y: 0, width: width, height: height)
        self.onResize = onResize
        self.onClose = onClose
        handle = XCreateSimpleWindow(display, XDefaultRootWindow(display), 0, 0, UInt32(width), UInt32(height),
                                     0, 0, 0xFFFFFF)
        XStoreName(display, handle, title)
        XSelectInput(display, handle, StructureNotifyMask)
        deleteAtom = XInternAtom(display, "WM_DELETE_WINDOW", 0)
        XSetWMProtocols(display, handle, &deleteAtom, 1)
        XMapWindow(display, handle)
        XFlush(display)

        // Events of Arrow's windows come on its own X11 connection, which
        // Chromium's loop does not read.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.processEvents() }
        }
        timer.resume()
        eventTimer = timer
    }

    func destroy() {
        eventTimer?.cancel()
        XDestroyWindow(CEFX11.display, handle)
        XFlush(CEFX11.display)
    }

    private func processEvents() {
        let display = CEFX11.display
        while XPending(display) > 0 {
            var event = XEvent()
            XNextEvent(display, &event)
            switch event.type {
            case ConfigureNotify where event.xconfigure.window == handle:
                let bounds = CGRect(x: 0, y: 0, width: Int(event.xconfigure.width), height: Int(event.xconfigure.height))
                if bounds != contentBounds {
                    contentBounds = bounds
                    onResize(bounds)
                }
            case ClientMessage where UInt(bitPattern: event.xclient.data.l.0) == deleteAtom:
                onClose()
            default:
                break
            }
        }
    }
}
#endif
