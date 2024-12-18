import AllocatedUnfairLockShim
import AppKit
import AsyncAlgorithms
import Atomics
import CoreGraphics

/// Provides an API for asynchronous, thread-safe processing of
/// [CGEvents](https://developer.apple.com/documentation/coregraphics/cgevent)
public final class HIDEventDispatcher: Sendable {
    private let systemPrerequisites: AllocatedUnfairLock<HIDEventDispatcherEnabledPrerequisite>
    private let receivers = AllocatedUnfairLock(initialState: [AnyHIDEventReceiver]())
    private let isProcessTrusted: @Sendable () -> Bool
    private let enabledOverride: ManagedAtomic<Bool>
    private let suspensions = AllocatedUnfairLock(initialState: Set<UUID>())
    private let eventSource = AllocatedUnfairLock<(any HIDEventDispatcherEventSource)?>(initialState: nil)

    init<SystemPrerequisiteNotifications: AsyncSequence & Sendable>(
        enabled: Bool,
        systemPrerequisiteNotifications: SystemPrerequisiteNotifications,
        isProcessTrusted: @escaping @Sendable () -> Bool
    ) where SystemPrerequisiteNotifications.Element == HIDEventDispatcherEnabledPrerequisite.Change {
        systemPrerequisites = .init(
            initialState: Self.defaultSystemPrerequisites(isProcessTrusted: isProcessTrusted())
        )
        enabledOverride = .init(enabled)
        self.isProcessTrusted = isProcessTrusted
        observeAndApplySystemPrerequisites(usingStream: systemPrerequisiteNotifications)
    }

    /// [AsyncStream](https://developer.apple.com/documentation/swift/asyncstream) of ``CopiedCGEvent``s.
    ///
    /// The backing ``HIDEventReceiver`` will automatically be removed from the event processing pipeline when the iteration is cancelled.
    public func stream(
        withPriority priority: UInt64 = .max
    ) -> AsyncStream<CopiedCGEvent> {
        .init { [weak self] continuation in
            let box = UncheckedWeakSendable<HIDEventReceiverClosure>(nil)
            let newReceiver = HIDEventReceiverClosure { event in
                continuation.yield(event)
                return .pass
            } remove: { [weak self] in
                continuation.finish()
                if let newReceiver = box.value {
                    self?.removeReceiver(newReceiver)
                }
            }
            newReceiver.hidEventReceiverPriority = priority
            continuation.onTermination = { [weak newReceiver] _ in
                newReceiver?.remove()
            }
            box.value = newReceiver
            self?.attachReceiver(newReceiver)
        }
    }

    /// Adds a sync callback with ``PostProcessHIDEventInstruction/pass`` behaviour to the event processing pipeline.
    ///
    /// - Parameters:
    ///    - behaviour: Instructs the ``HIDEventDispatcher`` how to postprocess a received event
    ///
    /// - Returns: An object that can be removed from this ``HIDEventDispatcher`` by calling ``HIDEventReceiverClosure/remove``
    public func addReceiver(
        withPostProcessBehaviour behaviour: PostProcessHIDEventInstruction = .pass,
        _ receiver: @escaping @Sendable (CopiedCGEvent) -> Void
    ) -> HIDEventReceiverClosure {
        addReceiver { event in
            receiver(event)
            return behaviour
        }
    }
    
    /// Adds an async callback to the event processing pipeline.
    ///
    /// - Parameters:
    ///    - behaviour: Instructs the ``HIDEventDispatcher`` how to postprocess a received event
    ///
    /// - Returns: Object that may be removed from this ``HIDEventDispatcher`` by calling ``HIDEventReceiverClosure/remove``
    public func addReceiver(
        withPostProcessBehaviour behaviour: PostProcessHIDEventInstruction = .pass,
        _ receiver: @escaping @Sendable (CopiedCGEvent) async -> Void
    ) -> HIDEventReceiverClosure {
        addReceiver { event in
            Task {
                await receiver(event)
            }
            return behaviour
        }
    }

    /// Adds a sync callback to the event processing pipeline.
    ///
    /// - Returns: Object that can may removed from this ``HIDEventDispatcher`` by calling ``HIDEventReceiverClosure/remove``
    public func addReceiver(
        _ receiver: @escaping @Sendable (CopiedCGEvent) -> PostProcessHIDEventInstruction
    ) -> HIDEventReceiverClosure {
        let box = UncheckedWeakSendable<HIDEventReceiverClosure>(nil)
        let newReceiver = HIDEventReceiverClosure(closure: receiver) { [weak self] in
            if let newReceiver = box.value {
                self?.removeReceiver(newReceiver)
            }
        }
        box.value = newReceiver
        attachReceiver(newReceiver)
        return newReceiver
    }

    /// Adds an async callback to the event processing pipeline.
    ///
    /// - Warning: Do not `await` *heavy* tasks. See: ``HIDEventProcessor/async(_:)``
    /// - Returns: Object that may be removed from this ``HIDEventDispatcher`` by calling ``HIDEventReceiverClosure/remove``
    public func addReceiver(
        _ receiver: @escaping @Sendable (CopiedCGEvent) async -> PostProcessHIDEventInstruction
    ) -> HIDEventReceiverClosure {
        let box = UncheckedWeakSendable<HIDEventReceiverClosure>(nil)
        let newReceiver = HIDEventReceiverClosure(closure: receiver) { [weak self] in
            if let newReceiver = box.value {
                self?.removeReceiver(newReceiver)
            }
        }
        box.value = newReceiver
        attachReceiver(newReceiver)
        return newReceiver
    }

    /// Adds a ``HIDEventReceiver`` to the event processing pipeline.
    ///
    /// - Returns: Proxy that may be removed from the event processing pipeline by calling ``DisposableHIDEventReceiver/remove``
    public func addReceiver(_ receiver: HIDEventReceiver & AnyObject) -> AnyHIDEventReceiver {
        let box = UncheckedWeakSendable<HIDEventReceiverProxy>(nil)
        let newReceiver = HIDEventReceiverProxy(actual: receiver) { [weak self] in
            if let newReceiver = box.value {
                self?.removeReceiver(newReceiver)
            }
        }
        box.value = newReceiver
        attachReceiver(newReceiver)
        return newReceiver
    }

    /// Acquires a *Suspension* on `self`. Event processing is suspended entirely until all suspensions are released.
    ///
    /// For example, a suspension might be required while the user records a new keyboard shortcut using some
    /// [firstResponder](https://developer.apple.com/documentation/appkit/nswindow/1419440-firstresponder) within your application.
    /// In such cases, it might be necessary to prevent previously assigned global keyboard shortcut actions from execution (i.e.: *suspend*) while the
    /// `firstResponder` status has not been resigned yet.
    ///
    /// Unlike toggling ``HIDEventDispatcher/setEnabled(_:)``, multiple suspensions *can* be acquired and held simultaneously and *can* be
    /// released independently from one another. Multiple components of an application can thus acquire suspensions without necessarily having
    /// *knowledge* of each other *__and__* without inadvertantly re-enabling the entire event processing pipeline.
    public func acquireSuspension() -> HIDEventDispatcherSuspension {
        let uuid = UUID()
        suspensions.withLock { suspensions in
            suspensions = suspensions.union([uuid])
        }
        toggleEventProcessing()
        return HIDEventDispatcherSuspension { [weak self] in
            self?.removeSuspension(uuid)
        }
    }

    /// Disables (`false`) or enables (`true`) event processing
    public func setEnabled(_ value: Bool) {
        if value == enabledOverride.load(ordering: .sequentiallyConsistent) {
            return
        }
        enabledOverride.store(value, ordering: .sequentiallyConsistent)
        toggleEventProcessing()
    }

    /// A Boolean value that determines whether the dispatcher is enabled.
    ///
    /// - Returns:`true` if event processing is enabled, `false` otherwise
    public func isEnabled() -> Bool {
        enabledOverride.load(ordering: .sequentiallyConsistent)
    }

    /// A Boolean value that determines whether the dispatcher is suspended.
    ///
    /// See also: ``HIDEventDispatcher/acquireSuspension()``
    ///
    /// - Returns: `true` if event processing is currently suspended, `false` otherwise
    public func isSuspended() -> Bool {
        !suspensions.withLock { $0 }.isEmpty
    }

    /// The current set of satisfied ``HIDEventDispatcherEnabledPrerequisite``s.
    ///
    /// A ``HIDEventDispatcher`` will automatically attempt to disable it's event source
    /// (see: ``HIDEventDispatcherEventSource/setEnabled(_:)``) when this property does not evaluate to
    /// ``HIDEventDispatcherEnabledPrerequisite/all``.
    public var dispatchingPrerequisites: HIDEventDispatcherEnabledPrerequisite {
        systemPrerequisites.withLock { $0 }
            .union(isEnabled() ? [.enabled] : [])
            .union(!getReceivers().isEmpty ? [.hasReceivers] : [])
            .union(suspensions.withLock { $0 }.isEmpty ? [.allSuspensionsReleased] : [])
    }

    func setEventSource(_ eventSource: (any HIDEventDispatcherEventSource)?) {
        self.eventSource.withLock {
            $0 = eventSource
        }
        toggleEventProcessing()
    }

    func onCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if [.tapDisabledByTimeout].contains(type) {
            Task {
                setEnabled(false)
                toggleEventProcessing()
                setEnabled(true)
                toggleEventProcessing()
            }
            return nil
        }
        var observers = getActiveReceivers()
        while let nextObserver = observers.popLast() {
            let eventCopy = if let copy = event.copy() {
                CopiedCGEvent(event: copy)
            } else {
                nil as CopiedCGEvent?
            }
            guard let eventCopy else {
                continue
            }
            var result: PostProcessHIDEventInstruction = .pass
            switch nextObserver.hidEventProcessor {
                case let .sync(closure):
                    result = closure(eventCopy)
                case let .async(closure):
                    let semaphore = DispatchSemaphore(value: 0)
                    let box = UncheckedSendable<PostProcessHIDEventInstruction?>(nil)
                    Task {
                        /*
                          Considered an anti-pattern in most cases, using a semaphore allows us to
                          1. process events on a designated background thread by default,
                          2. utilize modern Swift concurrency features, such as `async` or `actor`
                         */
                        box.value = await closure(eventCopy)
                        semaphore.signal()
                    }
                    _ = semaphore.wait(timeout: .distantFuture)
                    result = box.value ?? .pass
            }
            switch result {
                case .retain:
                    return nil
                case .bypass:
                    return Unmanaged.passUnretained(event)
                default:
                    break
            }
        }
        return Unmanaged.passUnretained(event)
    }

    func getReceivers() -> [AnyHIDEventReceiver] {
        receivers.withLock { $0 }
    }

    func getActiveReceivers() -> [AnyHIDEventReceiver] {
        getReceivers()
            .filter(\.hidEventReceiverEnabled)
            .sorted { $0.hidEventReceiverPriority < $1.hidEventReceiverPriority }
    }

    private func observeAndApplySystemPrerequisites<SystemPrerequisiteNotifications: AsyncSequence & Sendable>(
        usingStream stream: SystemPrerequisiteNotifications
    ) where SystemPrerequisiteNotifications.Element == HIDEventDispatcherEnabledPrerequisite.Change {
        let stream = stream
            .scan(Self.defaultSystemPrerequisites(isProcessTrusted: isProcessTrusted())) { result, change in
                switch change {
                    case .add(.axGranted):
                        result.union(.axGranted)
                    case .add(.deviceAwake):
                        result.union(.deviceAwake)
                    case .add(.screensAwake):
                        result.union(.screensAwake)
                    case .remove(.axGranted):
                        result.subtracting(.axGranted)
                    case .remove(.deviceAwake):
                        result.subtracting(.deviceAwake)
                    case .remove(.screensAwake):
                        result.subtracting(.screensAwake)
                    default:
                        result
                }
            }
            .removeDuplicates()
        Task { [weak self] in
            do {
                for try await newConditions in stream {
                    guard let self else {
                        break
                    }
                    systemPrerequisites.withLock {
                        $0 = newConditions
                    }
                    toggleEventProcessing()
                }
            } catch {
                fatalError("systemPrerequisiteNotifications is not expexted to throw any Error")
            }
        }
    }

    private func toggleEventProcessing() {
        let shouldEnable = dispatchingPrerequisites.satisfied
        eventSource.withLock { eventSource in
            guard let eventSource else {
                return
            }
            let isEnabled = eventSource.isEnabled()
            if shouldEnable != isEnabled {
                eventSource.setEnabled(shouldEnable)
            }
        }
    }

    private func removeSuspension(_ value: UUID) {
        suspensions.withLock { suspensions in
            suspensions = suspensions.filter { $0 != value }
        }
        toggleEventProcessing()
    }

    private func removeReceiver<R: AnyHIDEventReceiver>(_ receiver: R) {
        receivers.withLock { receivers in
            receivers = receivers.filter { $0 !== receiver }
        }
        toggleEventProcessing()
    }

    private func attachReceiver<R: AnyHIDEventReceiver>(_ receiver: R) {
        receivers.withLock { receivers in
            receivers = receivers + [receiver]
        }
        toggleEventProcessing()
    }

    private static func defaultSystemPrerequisites(
        isProcessTrusted: Bool
    ) -> HIDEventDispatcherEnabledPrerequisite {
        HIDEventDispatcherEnabledPrerequisite([.deviceAwake, .screensAwake]).union(isProcessTrusted ? [.axGranted] : [])
    }
}

public extension HIDEventDispatcher {
    /// Create a new ``HIDEventDispatcher`` with a backing
    /// [CGEventTap](https://developer.apple.com/documentation/coregraphics/1454426-cgeventtapcreate)
    ///
    /// - Parameters:
    ///   - enabled:
    ///     Enable or disable this dispatcher by default.
    ///   - eventsOfInterest:
    ///     A bitmask of type [CGEventMask](https://developer.apple.com/documentation/coregraphics/cgeventmask) that specifies the
    ///     events to monitor.
    ///     For example, you can include events like key presses or mouse movements.
    ///     Combine multiple event masks using bitwise OR (`|`).
    ///   - eventTapLocation:
    ///     The location where the event tap should be installed, specified as a
    ///     [CGEventTapLocation](https://developer.apple.com/documentation/coregraphics/cgeventtaplocation).
    ///     Possible values include:
    ///       - `.cghidEventTap`: Captures HID (Human Interface Device) events.
    ///       - `.cgSessionEventTap`: Captures events at the session level.
    ///       - `.cgAnnotatedSessionEventTap`: Captures events after they are annotated.
    static func systemDispatcher(
        enabled: Bool = true, eventsOfInterest: CGEventMask, eventTapLocation: CGEventTapLocation = .cgSessionEventTap
    ) -> HIDEventDispatcher {
        let dispatcher = HIDEventDispatcher(
            enabled: enabled,
            systemPrerequisiteNotifications: AsyncAlgorithms.merge(
                HIDEventDispatcherEnabledPrerequisite.screensNotification,
                HIDEventDispatcherEnabledPrerequisite.workspaceNotifications,
                HIDEventDispatcherEnabledPrerequisite.isProcessTrustedNotifications
            ),
            isProcessTrusted: AXIsProcessTrusted
        )
        let eventSource = HIDEventDispatcherEventTapSource(
            args: (eventsOfInterest: eventsOfInterest, eventTapLocation: eventTapLocation)
        ) { @Sendable [weak dispatcher] type, event in
            return if let dispatcher {
                dispatcher.onCGEvent(type: type, event: event)
            } else {
                Unmanaged.passUnretained(event)
            }
        }
        dispatcher.setEventSource(eventSource)
        return dispatcher
    }
}
