import Foundation
import LocalAuthentication

/// Asks for Touch ID or the Mac's password before showing a secret.
enum LocalAuthentication {
    static func confirm(_ reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
