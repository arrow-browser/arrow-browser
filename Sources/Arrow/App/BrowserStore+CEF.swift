import ArrowCEF
import ArrowCore
import Foundation

extension BrowserStore {
    /// The CEF request context of a profile, for macOS code that drives CEF
    /// directly (popups, site settings).
    func cefContext(for profileID: UUID) -> CEFRequestContext {
        guard let context = requestContext(for: profileID) as? CEFRequestContext else {
            preconditionFailure("The macOS app only runs CEF")
        }
        return context
    }
}
