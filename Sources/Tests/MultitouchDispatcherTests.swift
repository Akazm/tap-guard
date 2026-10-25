import AsyncAlgorithms
import Atomics
import CMultitouchSupport
import CoreGraphics
import Foundation
import Mutex
@testable import TapGuard
import Testing

/// Feeds synthetic frames into a ``MultitouchDispatcher``
final class MultitouchTestSource: MultitouchDispatcherSource, @unchecked Sendable {
    private let enabled = ManagedAtomic(false)
    private let delegate: @Sendable (TouchFrame) -> Void

    init(delegate: @escaping @Sendable (TouchFrame) -> Void) {
        self.delegate = delegate
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled.store(enabled, ordering: .sequentiallyConsistent)
    }

    func isEnabled() -> Bool {
        enabled.load(ordering: .sequentiallyConsistent)
    }

    func raise(_ frame: TouchFrame) {
        if isEnabled() {
            delegate(frame)
        }
    }
}

private func makeTestMultitouchDispatcher() -> (
    dispatcher: MultitouchDispatcher,
    source: MultitouchTestSource,
    prerequisiteChanges: AsyncChannel<HIDEventDispatcherEnabledPrerequisite.Change>
) {
    let changes = AsyncChannel<HIDEventDispatcherEnabledPrerequisite.Change>()
    let dispatcher = MultitouchDispatcher(enabled: true, systemPrerequisiteNotifications: changes)
    let source = MultitouchTestSource { [weak dispatcher] frame in
        dispatcher?.onFrame(frame)
    }
    dispatcher.setSource(source)
    return (dispatcher, source, changes)
}

private let trackpad = MultitouchDevice(id: 1, isBuiltIn: false, surfaceSize: CGSize(width: 156, height: 110))

private func frame(_ number: Int32, fingers: Int) -> TouchFrame {
    TouchFrame(
        device: trackpad,
        timestamp: Double(number) / 100,
        frameNumber: number,
        touches: (0 ..< fingers).map {
            Touch(identifier: Int32($0), stage: .touching, position: CGPoint(x: 0.5, y: 0.5))
        }
    )
}

@Suite("MultitouchDispatcher Tests") struct MultitouchDispatcherTests {
    @Test("Receivers get frames in descending priority order, and retaining stops the lower ones") func priorityAndRetain() {
        let (dispatcher, source, _) = makeTestMultitouchDispatcher()
        let log = Mutex([String]())
        let low = dispatcher.addReceiver(withPriority: 1) { frame in
            log.withLock { $0.append("low \(frame.frameNumber)") }
        }
        let high = dispatcher.addReceiver(withPriority: 2) { frame in
            log.withLock { $0.append("high \(frame.frameNumber)") }
            return frame.touches.count == 2 ? .retain : .pass
        }
        source.raise(frame(1, fingers: 1))
        source.raise(frame(2, fingers: 2))
        #expect(log.withLock { $0 } == ["high 1", "low 1", "high 2"])
        low.remove()
        high.remove()
    }

    @Test("The source runs only with receivers and without suspensions") func sourceFollowsReceiversAndSuspensions() {
        let (dispatcher, source, _) = makeTestMultitouchDispatcher()
        #expect(!source.isEnabled())
        let receiver = dispatcher.addReceiver { _ in }
        #expect(source.isEnabled())
        let suspension = dispatcher.acquireSuspension()
        #expect(!source.isEnabled())
        #expect(dispatcher.isSuspended())
        suspension.release()
        #expect(source.isEnabled())
        dispatcher.setEnabled(false)
        #expect(!source.isEnabled())
        dispatcher.setEnabled(true)
        #expect(source.isEnabled())
        receiver.remove()
        #expect(!source.isEnabled())
    }

    @Test("Sleep stops the source and waking restarts it") func sleepAndWake() async throws {
        let (dispatcher, source, changes) = makeTestMultitouchDispatcher()
        let receiver = dispatcher.addReceiver { _ in }
        #expect(source.isEnabled())
        await changes.send(.remove(.deviceAwake))
        try await Task.sleep(seconds: 0.1)
        #expect(!source.isEnabled())
        #expect(!dispatcher.dispatchingPrerequisites.contains(.deviceAwake))
        await changes.send(.add(.deviceAwake))
        try await Task.sleep(seconds: 0.1)
        #expect(source.isEnabled())
        receiver.remove()
    }

    @Test("A stream delivers every frame and leaves the pipeline when cancelled") func stream() async throws {
        let (dispatcher, source, _) = makeTestMultitouchDispatcher()
        let received = Mutex([Int32]())
        let stream = dispatcher.stream()
        let iteration = Task {
            for await frame in stream {
                received.withLock { $0.append(frame.frameNumber) }
            }
        }
        try await Task.sleep(seconds: 0.1)
        #expect(source.isEnabled())
        source.raise(frame(1, fingers: 3))
        source.raise(frame(2, fingers: 3))
        try await Task.sleep(seconds: 0.1)
        #expect(received.withLock { $0 } == [1, 2])
        iteration.cancel()
        try await Task.sleep(seconds: 0.1)
        #expect(dispatcher.getReceivers().isEmpty)
        #expect(!source.isEnabled())
    }

    @Test("Touch records convert with their stage, position and velocity") func recordConversion() {
        var record = CMTTouch()
        record.identifier = 7
        record.stage = Int32(CMTTouchStageTouching.rawValue)
        record.normalized.position = CMTPoint(x: 0.25, y: 0.75)
        record.normalized.velocity = CMTPoint(x: 0.1, y: -0.5)
        record.total = 0.8
        record.absolute.position = CMTPoint(x: -12, y: 30)
        let touch = Touch(record: record)
        #expect(touch.identifier == 7)
        #expect(touch.isTouching)
        #expect(touch.position == CGPoint(x: 0.25, y: 0.75))
        #expect(touch.velocity == CGPoint(x: CGFloat(Float(0.1)), y: -0.5))
        #expect(touch.size == 0.8)
        #expect(touch.absolutePosition == CGPoint(x: -12, y: 30))
        record.stage = Int32(CMTTouchStageHoverInRange.rawValue)
        #expect(!Touch(record: record).isTouching)
        #expect(Touch(record: record).stage == .hoverInRange)
    }

    @Test("The touch record has the framework's 96 byte layout") func recordLayout() {
        #expect(MemoryLayout<CMTTouch>.size == 96)
        #expect(MemoryLayout<CMTTouch>.stride == 96)
    }

    @Test("Frames tell touching contacts from hovering ones") func touchingTouches() {
        let frame = TouchFrame(
            device: trackpad,
            timestamp: 1,
            frameNumber: 1,
            touches: [
                Touch(identifier: 1, stage: .touching, position: .zero),
                Touch(identifier: 2, stage: .hoverInRange, position: .zero),
                Touch(identifier: 3, stage: .makeTouch, position: .zero),
                Touch(identifier: 4, stage: .breakTouch, position: .zero),
            ]
        )
        #expect(frame.touchingTouches.map(\.identifier) == [1, 3])
    }
}
