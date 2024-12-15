import CoreGraphics

/// A ``HIDEventDispatcher``'s source for Core Graphics events
protocol HIDEventDispatcherEventSource<Args>: Sendable {
    /// Additional arguments for required for protocol implementations
    associatedtype Args
    /// Initializes a new event source.
    ///
    /// - Parameters:
    ///   - args:
    ///     Additional arguments for implementations of this protocol.
    ///   - delegate:
    ///     A closure hat receives events.
    ///
    ///     This closure should usually be used as a delegate, for example to invoke a ``HIDEventDispatcher``s event processing pipeline.
    init(args: Args, delegate: @escaping @Sendable (_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>?)
    /// Enables or disables this event source
    func setEnabled(_ enabled: Bool)
    /// Indicates whether this event source is enabled or not
    func isEnabled() -> Bool
}
