/// Prevents ``HIDEventDispatcher`` from processing events until ``release()`` has been called.
public final class HIDEventDispatcherSuspension: Sendable {
    private let remove: @Sendable () -> Void

    init(remove: @Sendable @escaping () -> Void) {
        self.remove = remove
    }

    /// Releases the suspension
    public func release() {
        remove()
    }

    deinit {
        remove()
    }
}
