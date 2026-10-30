import CEF
import Foundation

/// Chromium tracing (Help ▸ Troubleshooting ▸ Record Trace).
@MainActor
public final class CEFTracing {
    public static let shared = CEFTracing()

    public private(set) var isRecording = false
    private var endCallback: CefHandler<cef_end_tracing_callback_t>?
    private var onFinish: ((URL) -> Void)?

    /// Starts recording Chromium's default categories.
    public func start() {
        guard !isRecording else { return }
        isRecording = withCefString("") { cef_begin_tracing($0, nil) } != 0
    }

    /// Stops recording and writes the trace (JSON, for chrome://tracing or Perfetto) to `url`.
    public func stop(writingTo url: URL, completion: @escaping (URL) -> Void) {
        guard isRecording else { return }
        onFinish = completion
        let callback = CefHandler<cef_end_tracing_callback_t>(owner: self) { callback in
            callback.on_end_tracing_complete = { callback, file in
                let path = String(cef: file)
                guard let tracing = CefHandler.owner(of: callback, as: CEFTracing.self) else { return }
                MainActor.assumeIsolated {
                    tracing.isRecording = false
                    tracing.onFinish?(URL(fileURLWithPath: path))
                    tracing.onFinish = nil
                }
            }
        }
        endCallback = callback
        if withCefString(url.cefPath, { cef_end_tracing($0, callback.retained()) }) == 0 {
            isRecording = false
            onFinish = nil
        }
    }
}
