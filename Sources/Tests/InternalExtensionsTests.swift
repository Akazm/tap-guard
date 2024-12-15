import class CoreGraphics.CGEvent
@testable import TapGuard
import Testing

@Suite("Test internal extensions") struct InternalExtensionsTests {
    private func someFun<T: Sendable>(_: T) async {
        try? await Task.sleep(seconds: 0.0)
    }

    @Test("Non sendable type is treated as Sendable") func nonSendableTreatedAsSendable() async throws {
        let e: CGEvent = .init(keyboardEventSource: nil, virtualKey: 16, keyDown: false)!
        await someFun(UncheckedSendable(e))
    }

    @Test("Non sendable weak reference is treated as Sendable") func sendableTreatedAsNonSendable() async throws {
        let e: CGEvent = .init(keyboardEventSource: nil, virtualKey: 16, keyDown: false)!
        await someFun(UncheckedWeakSendable(e))
    }
}
