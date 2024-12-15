import AllocatedUnfairLockShim
import CoreGraphics
import Foundation

/// Arguments required for ``HIDEventDispatcherEventTapSource``
public typealias EventTapSourceArgs = (eventsOfInterest: CGEventMask, eventTapLocation: CGEventTapLocation)

/// A ``HIDEventDispatcherEventSource`` with a backing
/// [CGEventTap](https://developer.apple.com/documentation/coregraphics/1454426-cgeventtapcreate)
final class HIDEventDispatcherEventTapSource: HIDEventDispatcherEventSource {
    private let eventsOfInterest: CGEventMask
    private let eventTapLocation: CGEventTapLocation
    private let eventTapState: AllocatedUnfairLock<EventTapState> = .init(initialState: .init())
    private let onCGEventClosure: @Sendable (_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>?

    init(
        args: EventTapSourceArgs,
        delegate: @escaping @Sendable (_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>?
    ) {
        eventsOfInterest = args.eventsOfInterest
        eventTapLocation = args.eventTapLocation
        onCGEventClosure = delegate
    }

    private func createTap() -> CFMachPort? {
        CGEvent.tapCreate(
            tap: eventTapLocation,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: { _, type, event, ptr in
                return if let ptr {
                    Unmanaged<HIDEventDispatcherEventTapSource>
                        .fromOpaque(ptr)
                        .takeUnretainedValue()
                        .onCGEventClosure(type, event)
                } else {
                    Unmanaged.passUnretained(event)
                }
            },
            userInfo: UnsafeMutableRawPointer(
                Unmanaged.passUnretained(self).toOpaque()
            )
        )
    }

    func setEnabled(_ enabled: Bool) {
        if enabled == eventTapState.withLock({ $0.enabled }) {
            return
        }
        if enabled {
            /*
              Using a designated thread for enabling the EventTap avoids priority inversions.
              See: https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early
             */
            let enableThread = Thread { [weak self] in
                guard let self else {
                    return
                }
                let boxedMachPort: UncheckedSendable<CFMachPort?> = .init(nil)
                let boxedRunLoop: UncheckedSendable<CFRunLoop?> = .init(nil)
                let boxedRunLoopSource: UncheckedSendable<CFRunLoopSource?> = .init(nil)
                let semaphore = DispatchSemaphore(value: 0)
                let eventTapThread = Thread { [weak self] in
                    guard let self, let eventTap = createTap() else {
                        semaphore.signal()
                        return
                    }
                    let runLoopSource = CFMachPortCreateRunLoopSource(
                        kCFAllocatorDefault,
                        eventTap,
                        0
                    )
                    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
                    boxedMachPort.value = eventTap
                    boxedRunLoop.value = CFRunLoopGetCurrent()
                    boxedRunLoopSource.value = runLoopSource
                    semaphore.signal()
                    CFRunLoopRun()
                }
                eventTapThread.qualityOfService = .userInteractive
                eventTapThread.start()
                _ = semaphore.wait(timeout: .distantFuture)
                if boxedRunLoop.value != nil {
                    eventTapState.withLock {
                        $0 = .init(
                            runLoop: boxedRunLoop.value!,
                            eventTap: boxedMachPort.value!,
                            runLoopSource: boxedRunLoopSource.value!
                        )
                    }
                    CGEvent.tapEnable(tap: boxedMachPort.value!, enable: true)
                }
            }
            enableThread.qualityOfService = .utility
            enableThread.start()
        } else {
            eventTapState.withLock {
                if let eventTap = $0.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: false)
                    if CFMachPortIsValid(eventTap) {
                        CFMachPortInvalidate(eventTap)
                    }
                }
                if let runLoopSrc = $0.runLoopSource, CFRunLoopSourceIsValid(runLoopSrc) {
                    CFRunLoopSourceInvalidate(runLoopSrc)
                }
                $0 = .init()
            }
        }
    }

    func isEnabled() -> Bool {
        eventTapState.withLock { $0.enabled }
    }
}

private struct EventTapState: @unchecked Sendable {
    let runLoop: CFRunLoop?
    let eventTap: CFMachPort?
    weak var runLoopSource: CFRunLoopSource?

    init(runLoop: CFRunLoop, eventTap: CFMachPort, runLoopSource: CFRunLoopSource) {
        self.runLoop = runLoop
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
    }

    init() {
        runLoop = nil
        eventTap = nil
        runLoopSource = nil
    }

    var enabled: Bool {
        runLoop != nil && eventTap != nil
    }
}
