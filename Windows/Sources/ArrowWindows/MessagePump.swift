import ArrowCEF
import Foundation
import WinSDK

/// Runs CEF's work, and the main queue, from whatever message loop the thread
/// runs: WinUI's, or the modal loop of a window being moved or resized. CEF
/// asks for work, from any thread, with a message to a hidden window; a timer
/// runs delayed work. cefclient's external message pump works the same way.
@MainActor
final class MessagePump {
    /// Hands CEF's requests for work to the pump: set as
    /// `CEFRuntime.onScheduleMessagePumpWork`.
    nonisolated let schedule: @Sendable (_ delay: Int64) -> Void

    private let window: HWND
    private var isWorking = false
    private var reentered = false
    private var timerPending = false

    fileprivate nonisolated static let haveWork = UINT(WM_USER + 1)
    /// The longest CEF's work waits, in milliseconds, as in cefclient.
    private static let maxDelay: Int64 = 1000 / 30
    /// Asks for a `maxDelay` timer unless one is pending.
    private static let idleDelay = Int64(Int32.max)
    fileprivate static var pumps: [HWND: MessagePump] = [:]

    init() {
        Self.registerClass()
        window = Self.className.withUnsafeBufferPointer { name in
            // A message-only window (HWND_MESSAGE).
            CreateWindowExW(0, name.baseAddress, nil, 0, 0, 0, 0, 0, HWND(bitPattern: -3), nil,
                            GetModuleHandleW(nil), nil)!
        }
        let target = UInt(bitPattern: window)
        schedule = { delay in
            PostMessageW(HWND(bitPattern: target), MessagePump.haveWork, 0, LPARAM(delay))
        }
        Self.pumps[window] = self
    }

    /// Stops the pump, once CEF has shut down.
    func invalidate() {
        killTimer()
        Self.pumps[window] = nil
        DestroyWindow(window)
    }

    fileprivate func workScheduled(delay: Int64) {
        if delay == Self.idleDelay, timerPending { return }
        killTimer()
        if delay <= 0 {
            doWork()
        } else {
            timerPending = true
            SetTimer(window, 1, UINT(min(delay, Self.maxDelay)), nil)
        }
    }

    fileprivate func timerFired() {
        killTimer()
        doWork()
    }

    private func doWork() {
        if performWork() {
            // A call made while working was skipped: run it now.
            schedule(0)
        } else if !timerPending {
            schedule(Self.idleDelay)
        }
    }

    /// Returns whether a call was skipped because work was already running
    /// (CEF's callbacks can pump messages).
    private func performWork() -> Bool {
        if isWorking {
            reentered = true
            return false
        }
        reentered = false
        isWorking = true
        CEFRuntime.shared.doMessageLoopWork()
        // No message loop runs Foundation's run loop on Windows: run main
        // actor jobs and DispatchQueue.main here.
        _ = RunLoop.main.run(mode: .default, before: Date())
        isWorking = false
        return reentered
    }

    private func killTimer() {
        guard timerPending else { return }
        KillTimer(window, 1)
        timerPending = false
    }

    private static let className = Array("ArrowMessagePump".utf16) + [0]

    private static let registerClass: () -> Void = {
        var windowClass = WNDCLASSEXW()
        windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        windowClass.lpfnWndProc = pumpWindowProcedure
        windowClass.hInstance = GetModuleHandleW(nil)
        className.withUnsafeBufferPointer { name in
            windowClass.lpszClassName = name.baseAddress
            RegisterClassExW(&windowClass)
        }
        return {}
    }()
}

private func pumpWindowProcedure(_ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    // Window messages are dispatched on the main thread.
    nonisolated(unsafe) let window = window
    let handled: Bool = MainActor.assumeIsolated {
        guard let window, let pump = MessagePump.pumps[window] else { return false }
        switch message {
        case MessagePump.haveWork:
            pump.workScheduled(delay: Int64(lParam))
            return true
        case UINT(WM_TIMER):
            pump.timerFired()
            return true
        default:
            return false
        }
    }
    return handled ? 0 : DefWindowProcW(window, message, wParam, lParam)
}
