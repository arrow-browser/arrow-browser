import CEF
import Synchronization

/// Blocks subresource requests (ad blocker). Consulted on Chromium's IO
/// thread, so the decision function is swapped atomically.
final class CEFResourceFilter: Sendable {
    typealias Decision = @Sendable (_ url: String, _ initiator: String?, _ isNavigation: Bool) -> Bool

    static let shared = CEFResourceFilter()

    private let decision = Mutex<Decision?>(nil)
    private let blockedCount = Atomic<Int>(0)
    /// Handler attached only to requests that must be cancelled.
    nonisolated(unsafe) private var cancellingHandler: CefHandler<cef_resource_request_handler_t>!

    private init() {
        cancellingHandler = CefHandler(owner: self) { handler in
            handler.on_before_resource_load = { handler, browser, frame, request, callback in
                cefRelease(browser)
                cefRelease(frame)
                cefRelease(request)
                cefRelease(callback)
                CefHandler.owner(of: handler, as: CEFResourceFilter.self)?.blockedCount.wrappingAdd(1, ordering: .relaxed)
                return RV_CANCEL
            }
        }
    }

    /// Installs (or removes, with nil) the blocking decision.
    func setDecision(_ decide: Decision?) {
        decision.withLock { $0 = decide }
    }

    /// Number of requests blocked since launch.
    var blocked: Int { blockedCount.load(ordering: .relaxed) }

    /// Answer to `get_resource_request_handler`: a cancelling handler for
    /// blocked requests, nil (default handling) otherwise.
    func resourceRequestHandler(url: String, initiator: String, isNavigation: Bool) -> UnsafeMutablePointer<cef_resource_request_handler_t>? {
        guard let decide = decision.withLock({ $0 }),
              decide(url, initiator.isEmpty ? nil : initiator, isNavigation) else { return nil }
        return cancellingHandler.retained()
    }
}
