import AppKit
import Mutex
@testable import TapGuard
import Testing

@Suite("System prerequisite notifications Tests", .serialized) struct SystemNotificationsTests {
    private func observedChanges<S: AsyncSequence & Sendable>(
        of sequence: S,
        afterPosting first: Notification.Name,
        then second: Notification.Name
    ) async throws -> (afterFirst: [HIDEventDispatcherEnabledPrerequisite.Change], afterSecond: [HIDEventDispatcherEnabledPrerequisite.Change])
        where S.Element == HIDEventDispatcherEnabledPrerequisite.Change {
        let changes = Mutex([HIDEventDispatcherEnabledPrerequisite.Change]())
        let observationTask = Task {
            for try await change in sequence {
                changes.withLock { $0.append(change) }
            }
        }
        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.post(name: first, object: nil)
        try await Task.sleep(seconds: 0.25)
        let afterFirst = changes.withLock { $0 }
        notificationCenter.post(name: second, object: nil)
        try await Task.sleep(seconds: 0.25)
        let afterSecond = changes.withLock { $0 }
        observationTask.cancel()
        return (afterFirst, afterSecond)
    }

    @Test("Screens sleeping removes and screens waking restores .screensAwake") func screensSleepAndWake() async throws {
        let (afterSleep, afterWake) = try await observedChanges(
            of: HIDEventDispatcherEnabledPrerequisite.screensNotification,
            afterPosting: NSWorkspace.screensDidSleepNotification,
            then: NSWorkspace.screensDidWakeNotification
        )
        #expect(afterSleep == [.remove(.screensAwake)])
        #expect(afterWake == [.remove(.screensAwake), .add(.screensAwake)])
    }

    @Test("Device sleeping removes and device waking restores .deviceAwake") func deviceSleepAndWake() async throws {
        let (afterSleep, afterWake) = try await observedChanges(
            of: HIDEventDispatcherEnabledPrerequisite.workspaceNotifications,
            afterPosting: NSWorkspace.willSleepNotification,
            then: NSWorkspace.didWakeNotification
        )
        #expect(afterSleep == [.remove(.deviceAwake)])
        #expect(afterWake == [.remove(.deviceAwake), .add(.deviceAwake)])
    }

    @Test("HIDEventDispatcher is re-enabled after screens wake up") func reenableAfterScreensWake() async throws {
        let (dispatcher, eventSource, channel) = makeTestDispatcher()
        let receiver = dispatcher.addReceiver { _ in }
        #expect(eventSource.isEnabled())
        await channel.send(.remove(.screensAwake))
        try await Task.sleep(seconds: 0.25)
        #expect(!eventSource.isEnabled())
        await channel.send(.add(.screensAwake))
        try await Task.sleep(seconds: 0.25)
        #expect(eventSource.isEnabled())
        receiver.remove()
    }
}
