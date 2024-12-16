import AllocatedUnfairLockShim
import AppKit
import CoreGraphics

/// Wrapped event processing closure, distinguishing between either an async or sync implementation
public enum HIDEventProcessor: Sendable {
    /// Async processing of a distinct copy of the original CGEvent.
    ///
    /// - Warning: A semaphore will block the event processing thread until the closure returns. You should not use this to await time-intensive tasks, such as
    /// networking, File I/O or CPU-intensive workload. It is instead solely recommended to use async processing when thread safety - like switching actor
    /// boundaries - might be required.
    case async(@Sendable (_ event: CopiedCGEvent) async -> PostProcessHIDEventInstruction)
    /// Sync processing of a distinct copy of the original CGEvent.
    case sync(@Sendable (_ event: CopiedCGEvent) -> PostProcessHIDEventInstruction)
}

/// A ``HIDEventProcessor`` along with a designated event processing priority that might be disabled or enabled.
public protocol HIDEventReceiver: Sendable {
    /// Priority of this receiver in the event processing pipeline (default: `UInt32.max`). A ``HIDEventDispatcher`` processes events in descendant
    /// priority order  (higher ``hidEventReceiverPriority`` has higher precedence).
    var hidEventReceiverPriority: UInt64 { get }
    /// Enables or disables this observer (default: `true`).  A `HIDEventReceiver` will be skipped by ``HIDEventDispatcher`` in case
    /// ``hidEventReceiverEnabled`` is `false`.
    var hidEventReceiverEnabled: Bool { get }
    /// The wrapped event ``HIDEventProcessor``
    var hidEventProcessor: HIDEventProcessor { get }
}

/// A ``HIDEventReceiver`` with a mutable ``HIDEventReceiver/hidEventReceiverPriority``  and a mutable
/// ``HIDEventReceiver/hidEventReceiverEnabled``-property
public protocol MutableHIDEventReceiver: HIDEventReceiver {
    var hidEventReceiverPriority: UInt64 { get set }
    var hidEventReceiverEnabled: Bool { get set }
}

public extension HIDEventReceiver {
    var hidEventReceiverPriority: UInt64 {
        UInt64(UInt32.max)
    }

    var hidEventReceiverEnabled: Bool {
        true
    }
}

/// An event receiver that may be removed from a ``HIDEventDispatcher`` by calling ``DisposableHIDEventReceiver/remove``
public protocol DisposableHIDEventReceiver: Sendable {
    /// Removes this receiver's registration from the event processing pipeline
    var remove: @Sendable () -> Void { get }
}

/// Wraps a closure acting as a ``HIDEventDispatcher``
///
/// See also: ``HIDEventReceiver``
public final class HIDEventReceiverClosure: DisposableHIDEventReceiver, MutableHIDEventReceiver {
    private let eventReceiverPriority: AllocatedUnfairLock<UInt64> = .init(initialState: .init(UInt32.max))
    private let eventReceiverEnabled: AllocatedUnfairLock<Bool> = .init(initialState: true)
    /// See: ``HIDEventReceiver/hidEventProcessor``
    public let receiver: HIDEventProcessor
    /// See: ``DisposableHIDEventReceiver/remove``
    public let remove: @Sendable () -> Void

    init(
        closure: @escaping @Sendable (CopiedCGEvent) -> PostProcessHIDEventInstruction,
        remove: @escaping @Sendable () -> Void
    ) {
        receiver = .sync(closure)
        self.remove = remove
    }

    init(
        closure: @escaping @Sendable (CopiedCGEvent) async -> PostProcessHIDEventInstruction,
        remove: @escaping @Sendable () -> Void
    ) {
        receiver = .async(closure)
        self.remove = remove
    }

    /// Enables or disables this receiver (default: `true`). Thread safety is ensured by an
    /// [AllocatedUnfairLock](https://developer.apple.com/documentation/os/osallocatedunfairlock)
    public var hidEventReceiverEnabled: Bool {
        get {
            eventReceiverEnabled.withLock {
                $0
            }
        }
        set {
            eventReceiverEnabled.withLock {
                $0 = newValue
            }
        }
    }

    /// Priority of this receiver in the event processing pipeline (default: `UInt32.max`). Thread safety is ensured by an
    /// [AllocatedUnfairLock](https://developer.apple.com/documentation/os/osallocatedunfairlock)
    public var hidEventReceiverPriority: UInt64 {
        get {
            eventReceiverPriority.withLock {
                $0
            }
        }
        set {
            eventReceiverPriority.withLock {
                $0 = newValue
            }
        }
    }

    /// Wrapped event processing closure, distinguishing between either an async or sync implementation
    public var hidEventProcessor: HIDEventProcessor {
        receiver
    }
}

/// Proxies a ``HIDEventReceiver`` and extends it by providing conformance to ``DisposableHIDEventReceiver``.
final class HIDEventReceiverProxy: DisposableHIDEventReceiver, HIDEventReceiver {
    private let actual: HIDEventReceiver & AnyObject
    /// See: ``DisposableHIDEventReceiver/remove``
    public let remove: @Sendable () -> Void

    init(actual: HIDEventReceiver & AnyObject, remove: @Sendable @escaping () -> Void) {
        self.actual = actual
        self.remove = remove
    }

    /// See: ``HIDEventReceiver/hidEventReceiverPriority``
    public var hidEventReceiverPriority: UInt64 {
        actual.hidEventReceiverPriority
    }

    /// See: ``HIDEventReceiver/hidEventReceiverEnabled``
    public var hidEventReceiverEnabled: Bool {
        actual.hidEventReceiverEnabled
    }

    /// See: ``HIDEventReceiver/hidEventProcessor``
    public var hidEventProcessor: HIDEventProcessor {
        actual.hidEventProcessor
    }
}

public typealias AnyHIDEventReceiver =
    AnyObject &
    DisposableHIDEventReceiver &
    HIDEventReceiver &
    Sendable
