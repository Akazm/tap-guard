import class CoreGraphics.CGEvent

/// A distinct copy of a [CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent), instantiated for exactly
/// one ``HIDEventDispatcher`` (1:1).
public struct CopiedCGEvent: @unchecked Sendable {
    /// The copied, unique [CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent).
    public let value: CGEvent

    init(event: CGEvent) {
        value = event
    }
}
