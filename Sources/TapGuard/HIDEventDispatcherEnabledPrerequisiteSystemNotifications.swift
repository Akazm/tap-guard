@preconcurrency import AppKit
import AsyncAlgorithms

struct ImmutableNotification: Sendable {
    let name: Notification.Name

    init(_ notification: Notification) {
        name = notification.name
    }
}

private func notifications(
    named name: Notification.Name,
    object: Any? = nil,
    notificationCenter: NotificationCenter = .default
) -> AsyncStream<ImmutableNotification> {
    return AsyncStream { continuation in
        let observer = notificationCenter.addObserver(
            forName: name,
            object: object,
            queue: nil
        ) { notification in
            continuation.yield(.init(notification))
        }
        continuation.onTermination = { @Sendable _ in
            notificationCenter.removeObserver(observer)
        }
    }
}

private extension NSAccessibility.Notification {
    static let isProcessTrusted = NSNotification.Name("com.apple.accessibility.api")
}

typealias NotificationToggleSequence = AsyncMerge2Sequence<
    AsyncMapSequence<AsyncStream<ImmutableNotification>, HIDEventDispatcherEnabledPrerequisite.Change>,
    AsyncMapSequence<AsyncStream<ImmutableNotification>, HIDEventDispatcherEnabledPrerequisite.Change>
>

typealias IsProcessTrustedNotifications = AsyncMapSequence<
    AsyncFlatMapSequence<AsyncSyncSequence<[Bool]>, AsyncScanSequence<AsyncStream<ImmutableNotification>, ()>>,
    HIDEventDispatcherEnabledPrerequisite.Change
>

extension HIDEventDispatcherEnabledPrerequisite {
    public enum Change: Sendable, Equatable {
        case add(HIDEventDispatcherEnabledPrerequisite)
        case remove(HIDEventDispatcherEnabledPrerequisite)
    }

    static var screensNotification: NotificationToggleSequence {
        merge(
            notifications(
                named: NSWorkspace.screensDidSleepNotification,
                notificationCenter: NSWorkspace.shared.notificationCenter
            )
            .map { _ in HIDEventDispatcherEnabledPrerequisite.Change.remove(.screensAwake) },
            notifications(
                named: NSWorkspace.screensDidSleepNotification,
                notificationCenter: NSWorkspace.shared.notificationCenter
            )
            .map { _ in HIDEventDispatcherEnabledPrerequisite.Change.add(.screensAwake) }
        )
    }

    static var workspaceNotifications: NotificationToggleSequence {
        merge(
            notifications(
                named: NSWorkspace.willSleepNotification, notificationCenter: DistributedNotificationCenter.default()
            )
            .map { _ in HIDEventDispatcherEnabledPrerequisite.Change.remove(.deviceAwake) },
            notifications(
                named: NSWorkspace.didWakeNotification, notificationCenter: DistributedNotificationCenter.default()
            )
            .map { _ in HIDEventDispatcherEnabledPrerequisite.Change.add(.deviceAwake) }
        )
    }

    static var isProcessTrustedNotifications: IsProcessTrustedNotifications {
        [AXIsProcessTrusted()]
            .async
            .flatMap { _ in
                notifications(
                    named: NSAccessibility.Notification.isProcessTrusted,
                    notificationCenter: DistributedNotificationCenter.default()
                ).scan(()) { _, _ in
                    ()
                }
            }
            .map {
                try? await Task.sleep(seconds: 0.15)
                return AXIsProcessTrusted()
                    ? HIDEventDispatcherEnabledPrerequisite.Change.add(.axGranted)
                    : HIDEventDispatcherEnabledPrerequisite.Change.remove(.axGranted)
            }
    }
}
