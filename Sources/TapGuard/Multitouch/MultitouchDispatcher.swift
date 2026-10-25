import AppKit
import AsyncAlgorithms
import Atomics
import Foundation
import Mutex

/// A ``MultitouchDispatcher``'s receiver, removable from the dispatcher by calling ``remove``
public final class TouchFrameReceiver: DisposableHIDEventReceiver, Sendable {
    private let priority: Mutex<UInt64>
    private let enabled = Mutex(true)
    let closure: @Sendable (TouchFrame) -> PostProcessHIDEventInstruction
    /// See: ``DisposableHIDEventReceiver/remove``
    public let remove: @Sendable () -> Void

    init(
        priority: UInt64,
        closure: @escaping @Sendable (TouchFrame) -> PostProcessHIDEventInstruction,
        remove: @escaping @Sendable () -> Void
    ) {
        self.priority = .init(priority)
        self.closure = closure
        self.remove = remove
    }

    /// Receivers get frames in descending priority order (default: `UInt32.max`)
    public var receiverPriority: UInt64 {
        get {
            priority.withLock { $0 }
        }
        set {
            priority.withLock { $0 = newValue }
        }
    }

    /// A disabled receiver is skipped (default: `true`)
    public var receiverEnabled: Bool {
        get {
            enabled.withLock { $0 }
        }
        set {
            enabled.withLock { $0 = newValue }
        }
    }
}

/// Provides an API for thread-safe processing of the ``TouchFrame``s of every trackpad, the way ``HIDEventDispatcher`` does
/// for keyboard and mouse events.
///
/// Frames are observed, not intercepted: macOS keeps acting on its own gestures whatever a receiver returns. A receiver's
/// ``PostProcessHIDEventInstruction/retain`` only keeps the frame from receivers of lower priority.
///
/// Receivers run on the thread the trackpad's frames arrive on, in descending priority order. Streams buffer every frame.
public final class MultitouchDispatcher: Sendable {
    /// What has to hold for frames to be delivered: ``HIDEventDispatcherEnabledPrerequisite/all`` but
    /// ``HIDEventDispatcherEnabledPrerequisite/axGranted``, which touches do not need
    public static let requiredPrerequisites: HIDEventDispatcherEnabledPrerequisite = [
        .enabled, .screensAwake, .deviceAwake, .hasReceivers, .allSuspensionsReleased,
    ]

    private let systemPrerequisites = Mutex<HIDEventDispatcherEnabledPrerequisite>([.deviceAwake, .screensAwake])
    private let receivers = Mutex([TouchFrameReceiver]())
    private let enabledOverride: ManagedAtomic<Bool>
    private let suspensions = Mutex(Set<UUID>())
    private let source = Mutex<(any MultitouchDispatcherSource)?>(nil)

    init<SystemPrerequisiteNotifications: AsyncSequence & Sendable>(
        enabled: Bool,
        systemPrerequisiteNotifications: SystemPrerequisiteNotifications
    ) where SystemPrerequisiteNotifications.Element == HIDEventDispatcherEnabledPrerequisite.Change {
        enabledOverride = .init(enabled)
        observeAndApplySystemPrerequisites(usingStream: systemPrerequisiteNotifications)
    }

    /// Whether the private framework delivering touches is present on this macOS
    public static var isAvailable: Bool {
        MultitouchSupport.isAvailable
    }

    /// [AsyncStream](https://developer.apple.com/documentation/swift/asyncstream) of ``TouchFrame``s.
    ///
    /// The backing receiver is removed from the pipeline when the iteration is cancelled.
    public func stream(withPriority priority: UInt64 = .max) -> AsyncStream<TouchFrame> {
        .init(bufferingPolicy: .unbounded) { [weak self] continuation in
            let box = UncheckedWeakSendable<TouchFrameReceiver>(nil)
            let receiver = TouchFrameReceiver(priority: priority) { frame in
                continuation.yield(frame)
                return .pass
            } remove: { [weak self] in
                continuation.finish()
                if let receiver = box.value {
                    self?.removeReceiver(receiver)
                }
            }
            continuation.onTermination = { [weak receiver] _ in
                receiver?.remove()
            }
            box.value = receiver
            self?.attachReceiver(receiver)
        }
    }

    /// Adds a callback to the pipeline, run for every frame on the thread it arrives on.
    ///
    /// - Returns: An object that can be removed from the pipeline by calling ``TouchFrameReceiver/remove``
    public func addReceiver(
        withPriority priority: UInt64 = .max,
        _ receiver: @escaping @Sendable (TouchFrame) -> PostProcessHIDEventInstruction
    ) -> TouchFrameReceiver {
        let box = UncheckedWeakSendable<TouchFrameReceiver>(nil)
        let newReceiver = TouchFrameReceiver(priority: priority, closure: receiver) { [weak self] in
            if let newReceiver = box.value {
                self?.removeReceiver(newReceiver)
            }
        }
        box.value = newReceiver
        attachReceiver(newReceiver)
        return newReceiver
    }

    /// Adds a callback to the pipeline that passes every frame on.
    ///
    /// - Returns: An object that can be removed from the pipeline by calling ``TouchFrameReceiver/remove``
    public func addReceiver(
        withPriority priority: UInt64 = .max,
        _ receiver: @escaping @Sendable (TouchFrame) -> Void
    ) -> TouchFrameReceiver {
        addReceiver(withPriority: priority) { frame in
            receiver(frame)
            return .pass
        }
    }

    /// Acquires a *Suspension* on `self`. Frames are not delivered until all suspensions are released.
    ///
    /// See: ``HIDEventDispatcher/acquireSuspension()``
    public func acquireSuspension() -> HIDEventDispatcherSuspension {
        let uuid = UUID()
        suspensions.withLock { suspensions in
            suspensions = suspensions.union([uuid])
        }
        toggleSource()
        return HIDEventDispatcherSuspension { [weak self] in
            self?.removeSuspension(uuid)
        }
    }

    /// Disables (`false`) or enables (`true`) delivery
    public func setEnabled(_ value: Bool) {
        if value == enabledOverride.load(ordering: .sequentiallyConsistent) {
            return
        }
        enabledOverride.store(value, ordering: .sequentiallyConsistent)
        toggleSource()
    }

    public func isEnabled() -> Bool {
        enabledOverride.load(ordering: .sequentiallyConsistent)
    }

    public func isSuspended() -> Bool {
        !suspensions.withLock { $0 }.isEmpty
    }

    /// The current set of satisfied ``HIDEventDispatcherEnabledPrerequisite``s. Frames are delivered while they include
    /// ``requiredPrerequisites``.
    public var dispatchingPrerequisites: HIDEventDispatcherEnabledPrerequisite {
        systemPrerequisites.withLock { $0 }
            .union(isEnabled() ? [.enabled] : [])
            .union(!getReceivers().isEmpty ? [.hasReceivers] : [])
            .union(suspensions.withLock { $0 }.isEmpty ? [.allSuspensionsReleased] : [])
    }

    func setSource(_ source: (any MultitouchDispatcherSource)?) {
        self.source.withLock {
            $0 = source
        }
        toggleSource()
    }

    /// Hands a frame to the receivers, in descending priority order, until one retains it
    func onFrame(_ frame: TouchFrame) {
        for receiver in getActiveReceivers() {
            if receiver.closure(frame) == .retain {
                return
            }
        }
    }

    func getReceivers() -> [TouchFrameReceiver] {
        receivers.withLock { $0 }
    }

    func getActiveReceivers() -> [TouchFrameReceiver] {
        getReceivers()
            .filter(\.receiverEnabled)
            .sorted { $0.receiverPriority > $1.receiverPriority }
    }

    private func observeAndApplySystemPrerequisites<SystemPrerequisiteNotifications: AsyncSequence & Sendable>(
        usingStream stream: SystemPrerequisiteNotifications
    ) where SystemPrerequisiteNotifications.Element == HIDEventDispatcherEnabledPrerequisite.Change {
        Task { [weak self] in
            do {
                for try await change in stream {
                    guard let self else {
                        break
                    }
                    systemPrerequisites.withLock { prerequisites in
                        switch change {
                            case let .add(prerequisite):
                                prerequisites.formUnion(prerequisite)
                            case let .remove(prerequisite):
                                prerequisites.subtract(prerequisite)
                        }
                    }
                    toggleSource()
                }
            } catch {
                fatalError("systemPrerequisiteNotifications is not expected to throw any Error")
            }
        }
    }

    private func toggleSource() {
        let shouldEnable = dispatchingPrerequisites.isSuperset(of: Self.requiredPrerequisites)
        source.withLock { source in
            guard let source, source.isEnabled() != shouldEnable else {
                return
            }
            source.setEnabled(shouldEnable)
        }
    }

    private func removeSuspension(_ value: UUID) {
        suspensions.withLock { suspensions in
            suspensions = suspensions.filter { $0 != value }
        }
        toggleSource()
    }

    private func removeReceiver(_ receiver: TouchFrameReceiver) {
        receivers.withLock { receivers in
            receivers = receivers.filter { $0 !== receiver }
        }
        toggleSource()
    }

    private func attachReceiver(_ receiver: TouchFrameReceiver) {
        receivers.withLock { receivers in
            receivers = receivers + [receiver]
        }
        toggleSource()
    }
}

public extension MultitouchDispatcher {
    /// Creates a ``MultitouchDispatcher`` delivering the frames of every trackpad of the computer, those connecting later
    /// included. Delivery pauses while the computer or its screens sleep.
    ///
    /// - Parameter enabled: Enable or disable this dispatcher by default.
    static func systemDispatcher(enabled: Bool = true) -> MultitouchDispatcher {
        let dispatcher = MultitouchDispatcher(
            enabled: enabled,
            systemPrerequisiteNotifications: AsyncAlgorithms.merge(
                HIDEventDispatcherEnabledPrerequisite.screensNotification,
                HIDEventDispatcherEnabledPrerequisite.workspaceNotifications
            )
        )
        dispatcher.setSource(
            MultitouchDeviceSource { [weak dispatcher] frame in
                dispatcher?.onFrame(frame)
            }
        )
        return dispatcher
    }
}
