import AllocatedUnfairLockShim
import CoreGraphics
import Foundation
@testable import TapGuard
import Testing

@Suite("HIDEventDispatcher Tests") struct HIDEventDispatcherTests {
    @Test("HIDEventDispatcher will be automatically re-enabled") func reenableDispatcher() async throws {
        let (dispatcher, eventSource, _) = makeTestDispatcher()
        var observedPrequisites = [HIDEventDispatcherEnabledPrerequisite]()
        let observationStream = AsyncStream<HIDEventDispatcherEnabledPrerequisite> { [weak dispatcher] continuation in
            guard let dispatcher else {
                return
            }
            var previouslySatisfiedPrequisites = dispatcher.dispatchingPrerequisites
            continuation.yield(previouslySatisfiedPrequisites)
            Task {
                while true {
                    let newPrequisites = dispatcher.dispatchingPrerequisites
                    if newPrequisites != previouslySatisfiedPrequisites {
                        continuation.yield(newPrequisites)
                        previouslySatisfiedPrequisites = newPrequisites
                    }
                }
            }
        }
        let receiver = dispatcher.addReceiver { _ in }
        let observationTask = Task {
            for await prequisite in observationStream {
                observedPrequisites.append(prequisite)
            }
        }
        try? await Task.sleep(seconds: 0.75)
        eventSource.raise(
            eventOfType: .tapDisabledByTimeout,
            event: .init(keyboardEventSource: nil, virtualKey: 16, keyDown: false)!
        )
        try? await Task.sleep(seconds: 0.75)
        let latestValues = observedPrequisites.suffix(2)
        #expect(latestValues.first?.contains(.enabled) == false)
        #expect(latestValues.last?.contains(.enabled) == true)
        receiver.remove()
        observationTask.cancel()
    }

    @Test("HIDEventReceiver proxy") func hidEventReceiverProxy() async throws {
        let (dispatcher, _, _) = makeTestDispatcher()
        final class Receiver: HIDEventReceiver {
            var hidEventProcessor: TapGuard.HIDEventProcessor {
                .sync { _ in
                    .pass
                }
            }

            var hidEventReceiverPriority: UInt64 {
                .zero
            }

            var hidEventReceiverEnabled: Bool {
                false
            }
        }
        let wrappedReceiver = Receiver()
        let receiver = dispatcher.addReceiver(wrappedReceiver)
        #expect(receiver.hidEventReceiverEnabled == wrappedReceiver.hidEventReceiverEnabled)
    }

    @Test("HIDEventDispatcherEnabledPrequisite debug description")
    func testHIDEventDispatcherEnabledPrequisiteDebugDescription() {
        let items: HIDEventDispatcherEnabledPrerequisite = [
            .enabled,
            .screensAwake,
            .deviceAwake,
            .axGranted,
            .hasReceivers,
            .allSuspensionsReleased,
        ]
        let debugDescriptionItems = [
            HIDEventDispatcherEnabledPrerequisite.enabledDebugDescription,
            HIDEventDispatcherEnabledPrerequisite.screensAwakeDebugDescription,
            HIDEventDispatcherEnabledPrerequisite.deviceAwakeDebugDescription,
            HIDEventDispatcherEnabledPrerequisite.axGrantedDebugDescription,
            HIDEventDispatcherEnabledPrerequisite.hasReceiversDebugDescription,
            HIDEventDispatcherEnabledPrerequisite.allSuspensionsReleasedDebugDescription,
        ]
        for debugDescriptionItem in debugDescriptionItems {
            #expect(items.debugDescription.contains(debugDescriptionItem))
        }
    }

    @Test("Async event stream finishes iteration on remove") func asyncStreamFinishesIteration() async throws {
        let (dispatcher, eventSource, _) = makeTestDispatcher()
        Task {
            for await event in dispatcher.stream() {
                #expect(event.value.getIntegerValueField(.keyboardEventKeycode) == 16)
            }
            #expect(dispatcher.getActiveReceivers().isEmpty)
        }
        try? await Task.sleep(seconds: 0.2)
        eventSource.raise(
            eventOfType: .keyUp,
            event: .init(keyboardEventSource: nil, virtualKey: 16, keyDown: false)!
        )
        eventSource.raise(
            eventOfType: .keyUp,
            event: .init(keyboardEventSource: nil, virtualKey: 16, keyDown: true)!
        )
        for receiver in dispatcher.getActiveReceivers() {
            receiver.remove()
        }
    }

    @Test("Async event stream removes receiver on task cancellation") func asyncStreamRemovesReceiver() async throws {
        let (dispatcher, eventSource, _) = makeTestDispatcher()
        let task = Task {
            for await event in dispatcher.stream() {
                #expect(event.value.getIntegerValueField(.keyboardEventKeycode) == 16)
            }
        }
        try? await Task.sleep(seconds: 0.2)
        eventSource.raise(
            eventOfType: .keyUp,
            event: .init(keyboardEventSource: nil, virtualKey: 16, keyDown: false)!
        )
        eventSource.raise(
            eventOfType: .keyUp,
            event: .init(keyboardEventSource: nil, virtualKey: 16, keyDown: true)!
        )
        task.cancel()
        try? await Task.sleep(seconds: 0.2)
        #expect(dispatcher.getActiveReceivers().isEmpty)
    }

    @Test("System prerequisites automatically change asynchronously on system notification") func measureEnabledToggle() async throws {
        let (dispatcher, eventSource, notifications) = makeTestDispatcher()
        _ = dispatcher.addReceiver { _ in }
        await notifications.send(.remove(.deviceAwake))
        while eventSource.isEnabled() {
            continue
        }
        #expect(!eventSource.isEnabled())
    }

    @Test("Release a dispatcher suspension") func releaseDispatcherSuspension() async throws {
        let (dispatcher, eventSource, _) = makeTestDispatcher()
        let lockedObservedEvents = AllocatedUnfairLock(uncheckedState: [String]())
        _ = dispatcher.addReceiver { _ in
            lockedObservedEvents.withLock {
                $0.append("receiverA")
            }
        }
        while !eventSource.isEnabled() {
            continue
        }
        let suspension = dispatcher.acquireSuspension()
        eventSource.raise(
            eventOfType: .keyUp,
            event: .init(keyboardEventSource: nil, virtualKey: 16, keyDown: false)!
        )
        suspension.release()
        eventSource.raise(
            eventOfType: .keyUp,
            event: .init(keyboardEventSource: nil, virtualKey: 16, keyDown: false)!
        )
        let observedEvents = lockedObservedEvents.withLock { $0 }
        #expect(observedEvents == ["receiverA"])
    }

    @Test("Suspend a dispatcher") func suspendDispatcher() async throws {
        let (dispatcher, eventSource, _) = makeTestDispatcher()
        let lockedObservedEvents = AllocatedUnfairLock(uncheckedState: [String]())
        _ = dispatcher.addReceiver { _ in
            lockedObservedEvents.withLock {
                $0.append("receiverA")
            }
        }
        let suspension = dispatcher.acquireSuspension()
        eventSource.raise(
            eventOfType: .keyUp,
            event: .init(keyboardEventSource: nil, virtualKey: 16, keyDown: false)!
        )
        let observedEvents = lockedObservedEvents.withLock { $0 }
        #expect(observedEvents.isEmpty)
        suspension.release()
    }

    @Test("Disable a receiver") func disableAReceiver() async throws {
        let (dispatcher, eventSource, _) = makeTestDispatcher()
        let lockedObservedEvents = AllocatedUnfairLock(uncheckedState: [String]())
        let receiverA = dispatcher.addReceiver { _ in
            lockedObservedEvents.withLock {
                $0.append("receiverA")
            }
        }
        while !eventSource.isEnabled() {
            continue
        }
        receiverA.hidEventReceiverEnabled = false
        eventSource.raise(
            eventOfType: .keyUp,
            event: .init(keyboardEventSource: nil, virtualKey: 16, keyDown: false)!
        )
        let observedEvents = lockedObservedEvents.withLock { $0 }
        #expect(observedEvents.isEmpty)
    }

    @Test("Set prioritization of receiver") func setPriotizationOfReceiver() async throws {
        let (dispatcher, _, _) = makeTestDispatcher()
        let receiverA = dispatcher.addReceiver { _ in
        }
        receiverA.hidEventReceiverPriority = .min
        #expect(receiverA.hidEventReceiverPriority == .min)
    }

    @Test("Prioritization of receivers changes processing order")
    func priotizationOfReceiversChangesOrder() async throws {
        let (dispatcher, eventSource, _) = makeTestDispatcher()
        let lockedObservedEvents = AllocatedUnfairLock(uncheckedState: [String]())
        let receiverA = dispatcher.addReceiver { _ in
            lockedObservedEvents.withLock {
                $0.append("receiverA")
            }
        }
        let receiverB = dispatcher.addReceiver { _ in
            lockedObservedEvents.withLock {
                $0.append("receiverB")
            }
        }
        receiverA.hidEventReceiverPriority = .min
        receiverB.hidEventReceiverPriority = .max
        while !eventSource.isEnabled() {
            continue
        }
        eventSource.raise(
            eventOfType: .keyUp,
            event: .init(keyboardEventSource: nil, virtualKey: 16, keyDown: false)!
        )
        let observedEvents = lockedObservedEvents.withLock { $0 }
        #expect(observedEvents == ["receiverB", "receiverA"])
    }

    @Test("Add a sync receiver") func addSyncReceiver() async throws {
        let (dispatcher, _, _) = makeTestDispatcher()
        final class Receiver: HIDEventReceiver {
            var hidEventProcessor: TapGuard.HIDEventProcessor {
                .sync { _ in
                    .pass
                }
            }

            var hidEventReceiverEnabled: Bool {
                true
            }
        }
        _ = dispatcher.addReceiver(Receiver())
        #expect(dispatcher.getActiveReceivers().count == 1)
    }

    @Test("Sync receiver enabled") func syncReceiverEnabled() async throws {
        let (dispatcher, _, _) = makeTestDispatcher()
        final class Receiver: HIDEventReceiver {
            var hidEventProcessor: TapGuard.HIDEventProcessor {
                .sync { _ in
                    .pass
                }
            }

            var hidEventReceiverPriority: UInt64 {
                .zero
            }

            var hidEventReceiverEnabled: Bool {
                true
            }
        }
        let receiver = dispatcher.addReceiver(Receiver())
        #expect(receiver.hidEventReceiverEnabled == true)
    }

    @Test("Sync receiver priority") func syncReceiverPriority() async throws {
        let (dispatcher, _, _) = makeTestDispatcher()
        final class Receiver: HIDEventReceiver {
            var hidEventProcessor: TapGuard.HIDEventProcessor {
                .sync { _ in
                    .pass
                }
            }

            var hidEventReceiverPriority: UInt64 {
                .zero
            }

            var hidEventReceiverEnabled: Bool {
                true
            }
        }
        let receiver = dispatcher.addReceiver(Receiver())
        #expect(receiver.hidEventReceiverPriority == .zero)
    }

    @Test("Sync receiver event processor") func syncReceiverEventProcessor() async throws {
        let (dispatcher, _, _) = makeTestDispatcher()
        final class Receiver: HIDEventReceiver {
            var hidEventProcessor: TapGuard.HIDEventProcessor {
                .sync { _ in
                    .pass
                }
            }

            var hidEventReceiverPriority: UInt64 {
                .zero
            }

            var hidEventReceiverEnabled: Bool {
                true
            }
        }
        let receiver = dispatcher.addReceiver(Receiver())
        let satisfiesTestConditions = if case .sync = receiver.hidEventProcessor { true } else { false }
        #expect(satisfiesTestConditions, "Expected `receiver` to provide a .sync hidEventProcessor")
    }

    @Test("Add an async closure void receiver") func addAsyncClosureVoidReceiver() async throws {
        let (dispatcher, _, _) = makeTestDispatcher()
        let receiver = dispatcher.addReceiver { _ in
            try? await Task.sleep(seconds: 0)
        }
        receiver.remove()
        #expect(dispatcher.getActiveReceivers().isEmpty)
    }

    @Test("Add a sync closure receiver") func addSyncClosureReceiver() throws {
        let (dispatcher, _, _) = makeTestDispatcher()
        _ = dispatcher.addReceiver { _ in
            .pass
        }
        #expect(!dispatcher.getActiveReceivers().isEmpty)
    }

    @Test("Add an async closure receiver") func addAsyncClosureReceiver() throws {
        let (dispatcher, _, _) = makeTestDispatcher()
        let receiver = dispatcher.addReceiver { _ in
            try? await Task.sleep(seconds: 0)
            return .pass
        }
        receiver.remove()
        #expect(dispatcher.getActiveReceivers().isEmpty)
    }

    @Test("Add a sync closure void receiver") func addSyncClosureVoidReceiver() throws {
        let (dispatcher, _, _) = makeTestDispatcher()
        _ = dispatcher.addReceiver { _ in }
        #expect(dispatcher.getActiveReceivers().count == 1)
    }

    @Test("Remove a sync closure void receiver") func removeSyncClosureVoidReceiver() throws {
        let (dispatcher, _, _) = makeTestDispatcher()
        let receiver = dispatcher.addReceiver { _ in }
        receiver.remove()
        #expect(dispatcher.getActiveReceivers().isEmpty)
    }

    @Test("Remove a sync closure receiver") func removeSyncClosureReceiver() throws {
        let (dispatcher, _, _) = makeTestDispatcher()
        let receiver = dispatcher.addReceiver { _ in
            .pass
        }
        receiver.remove()
        #expect(dispatcher.getActiveReceivers().isEmpty)
    }

    @Test("Auto-toggle event processing by adding and removing receivers") func toggleEventProcessing() async throws {
        let (dispatcher, eventSource, _) = makeTestDispatcher()
        let receiver = dispatcher.addReceiver { _ in
            .pass
        }
        #expect(dispatcher.dispatchingPrerequisites.contains(.hasReceivers))
        receiver.remove()
        #expect(!dispatcher.dispatchingPrerequisites.contains(.hasReceivers))

        while eventSource.isEnabled() {
            continue
        }
        #expect(!eventSource.isEnabled())
    }
}
