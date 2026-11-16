import Observation

/// Runs `update` now, and again after each change of the observable state it
/// read (ArrowCore's models): how the WinUI controls follow them.
@MainActor
func observe(_ update: @escaping @MainActor @Sendable () -> Void) {
    withObservationTracking(update) {
        // Called before the change is applied: update once it is.
        Task { @MainActor in observe(update) }
    }
}
