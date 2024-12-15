import AsyncAlgorithms
import Atomics
import CoreGraphics
@testable import TapGuard

struct HIDEventDispatcherTestEventSource: HIDEventDispatcherEventSource {
    private let enabled = ManagedAtomic(false)
    private let onCGEvent: @Sendable (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    init(args _: Void, delegate: @escaping @Sendable (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) {
        onCGEvent = delegate
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled.store(enabled, ordering: .sequentiallyConsistent)
    }

    func isEnabled() -> Bool {
        enabled.load(ordering: .sequentiallyConsistent)
    }

    func raise(eventOfType eventType: CGEventType, event: CGEvent) {
        if enabled.load(ordering: .acquiring) {
            let _ = onCGEvent(eventType, event)
        }
    }
}

func makeTestDispatcher() -> (
    dispatcher: HIDEventDispatcher,
    eventSource: HIDEventDispatcherTestEventSource,
    systemPrerequisiteNotificationsChannel: AsyncChannel<HIDEventDispatcherEnabledPrerequisite.Change>
) {
    let systemPrerequisiteNotifications = AsyncChannel<HIDEventDispatcherEnabledPrerequisite.Change>()
    let dispatcher = HIDEventDispatcher(
        enabled: true,
        systemPrerequisiteNotifications: systemPrerequisiteNotifications,
        isProcessTrusted: { true }
    )
    let eventSource = HIDEventDispatcherTestEventSource(args: ()) { @Sendable [weak dispatcher] type, event in
        return if let dispatcher {
            dispatcher.onCGEvent(type: type, event: event)
        } else {
            Unmanaged.passUnretained(event)
        }
    }
    dispatcher.setEventSource(eventSource)
    return (dispatcher, eventSource, systemPrerequisiteNotifications)
}
