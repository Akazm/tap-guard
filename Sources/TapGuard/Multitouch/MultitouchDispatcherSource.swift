import Atomics
import CMultitouchSupport
import CoreFoundation
import Foundation
import IOKit
import Mutex

/// A ``MultitouchDispatcher``'s source of ``TouchFrame``s
protocol MultitouchDispatcherSource: Sendable {
    /// - Parameter delegate: Receives every frame, on whatever thread the source delivers on
    init(delegate: @escaping @Sendable (TouchFrame) -> Void)
    /// Enables or disables this source
    func setEnabled(_ enabled: Bool)
    /// Indicates whether this source is enabled or not
    func isEnabled() -> Bool
}

/// Delivers the frames of every multitouch device of the computer, trackpads connecting later included, through the private
/// `MultitouchSupport.framework`.
///
/// Devices are found through IOKit (`AppleMultitouchDevice`), which also tells when one appears or goes away: a Bluetooth
/// trackpad does so whenever it connects. The framework delivers frames on a thread of its own, which is where the delegate
/// runs.
final class MultitouchDeviceSource: MultitouchDispatcherSource, @unchecked Sendable {

    /// What the frame callback, which carries no context of its own, needs to know about a device
    private final class Registration: @unchecked Sendable {
        weak var source: MultitouchDeviceSource?
        let device: MultitouchDevice

        init(source: MultitouchDeviceSource, device: MultitouchDevice) {
            self.source = source
            self.device = device
        }
    }

    private struct Device {
        /// The framework's device, as an address so that the state stays `Sendable`
        let address: UInt
        /// The IOKit registry entry the device was made from, which the entry's termination refers to
        let registryEntryID: UInt64
        let description: MultitouchDevice

        var ref: CMTDeviceRef {
            CMTDeviceRef(bitPattern: address)!
        }
    }

    private struct State: Sendable {
        var devices = [Device]()
        /// The IOKit notification port, as an address so that the state stays `Sendable`
        var notificationPortAddress: UInt = 0
        var matchedIterator: io_iterator_t = 0
        var terminatedIterator: io_iterator_t = 0
    }

    private static let serviceClass = "AppleMultitouchDevice"
    /// Devices by the address of the framework's device, for the frame callback
    private static let registrations = Mutex([UInt: Registration]())
    private static let frameCallback: CMTContactCallback = { deviceRef, touches, count, timestamp, frame in
        guard let deviceRef, let touches else {
            return 0
        }
        let registration = registrations.withLock { registrations -> Registration? in
            if let registration = registrations[UInt(bitPattern: deviceRef)] {
                return registration
            }
            // The framework may hand the callback a device object of its own rather than the one registered with
            var id: UInt64 = 0
            if MultitouchSupport.deviceID?(deviceRef, &id) == 0, id != 0,
               let registration = registrations.values.first(where: { $0.device.id == id }) {
                return registration
            }
            return registrations.count == 1 ? registrations.values.first : nil
        }
        guard let registration, let source = registration.source else {
            return 0
        }
        let records = UnsafeBufferPointer(start: touches, count: Int(max(count, 0)))
        source.delegate(
            TouchFrame(
                device: registration.device,
                timestamp: timestamp,
                frameNumber: frame,
                touches: records.map(Touch.init(record:))
            )
        )
        return 0
    }

    private let delegate: @Sendable (TouchFrame) -> Void
    private let enabled = ManagedAtomic(false)
    private let state = Mutex(State())
    private let runLoop = Mutex<CFRunLoop?>(nil)

    init(delegate: @escaping @Sendable (TouchFrame) -> Void) {
        self.delegate = delegate
    }

    deinit {
        if let runLoop = runLoop.withLock({ $0 }) {
            CFRunLoopStop(runLoop)
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled.exchange(enabled, ordering: .sequentiallyConsistent) != enabled,
              MultitouchSupport.isAvailable else {
            return
        }
        perform { [self] in
            if enabled {
                startListening()
            } else {
                stopListening()
            }
        }
    }

    func isEnabled() -> Bool {
        enabled.load(ordering: .sequentiallyConsistent)
    }

    // MARK: - The listening thread

    /// Runs `block` on the source's own thread, whose run loop serves the IOKit notifications
    private func perform(_ block: @escaping @Sendable () -> Void) {
        let runLoop = runLoop.withLock { runLoop -> CFRunLoop in
            if let runLoop {
                return runLoop
            }
            let started = DispatchSemaphore(value: 0)
            let box = UncheckedSendable<CFRunLoop?>(nil)
            let thread = Thread {
                // A run loop without sources returns at once: a source that never fires keeps it running
                var context = CFRunLoopSourceContext()
                context.perform = { _ in }
                let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), keepAlive, .commonModes)
                box.value = CFRunLoopGetCurrent()
                started.signal()
                CFRunLoopRun()
            }
            thread.name = "TapGuard.Multitouch"
            thread.qualityOfService = .userInteractive
            thread.start()
            started.wait()
            runLoop = box.value
            return box.value!
        }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func startListening() {
        guard let port = IONotificationPortCreate(Self.mainPort) else {
            addDevices(fromListOf: MultitouchSupport.createList)
            return
        }
        state.withLock { $0.notificationPortAddress = UInt(bitPattern: port) }
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var matched: io_iterator_t = 0
        var terminated: io_iterator_t = 0
        // The notification only arms once its iterator has been drained, which lists the devices present now
        let matchedResult = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching(Self.serviceClass),
            { refcon, iterator in
                guard let refcon else {
                    return
                }
                Unmanaged<MultitouchDeviceSource>.fromOpaque(refcon).takeUnretainedValue().servicesMatched(iterator)
            },
            refcon,
            &matched
        )
        let terminatedResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching(Self.serviceClass),
            { refcon, iterator in
                guard let refcon else {
                    return
                }
                Unmanaged<MultitouchDeviceSource>.fromOpaque(refcon).takeUnretainedValue().servicesTerminated(iterator)
            },
            refcon,
            &terminated
        )
        state.withLock {
            $0.matchedIterator = matched
            $0.terminatedIterator = terminated
        }
        if matchedResult == KERN_SUCCESS, MultitouchSupport.createFromService != nil {
            servicesMatched(matched)
        } else {
            addDevices(fromListOf: MultitouchSupport.createList)
        }
        if terminatedResult == KERN_SUCCESS {
            servicesTerminated(terminated)
        }
    }

    private func stopListening() {
        let state = state.withLock { state in
            defer { state = State() }
            return state
        }
        for device in state.devices {
            remove(device)
        }
        if state.matchedIterator != 0 {
            IOObjectRelease(state.matchedIterator)
        }
        if state.terminatedIterator != 0 {
            IOObjectRelease(state.terminatedIterator)
        }
        if let port = IONotificationPortRef(bitPattern: state.notificationPortAddress) {
            IONotificationPortDestroy(port)
        }
    }

    // MARK: - Devices

    private func servicesMatched(_ iterator: io_iterator_t) {
        guard let createFromService = MultitouchSupport.createFromService else {
            return
        }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var registryEntryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryEntryID)
            if isEnabled(), let ref = createFromService(service) {
                add(ref, registryEntryID: registryEntryID)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private func servicesTerminated(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var registryEntryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryEntryID)
            let devices = state.withLock { state in
                let devices = state.devices.filter { $0.registryEntryID == registryEntryID }
                state.devices.removeAll { $0.registryEntryID == registryEntryID }
                return devices
            }
            devices.forEach(remove)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    /// Without IOKit, the framework's own list: the devices present now, with nothing said about later ones
    private func addDevices(fromListOf createList: CMTDeviceCreateListFunction?) {
        guard let list = createList?()?.takeRetainedValue() else {
            return
        }
        for index in 0 ..< CFArrayGetCount(list) {
            if let ref = CFArrayGetValueAtIndex(list, index) {
                add(CMTDeviceRef(mutating: ref), registryEntryID: 0)
            }
        }
    }

    private func add(_ ref: CMTDeviceRef, registryEntryID: UInt64) {
        let device = Device(address: UInt(bitPattern: ref), registryEntryID: registryEntryID, description: describe(ref))
        state.withLock { $0.devices.append(device) }
        Self.registrations.withLock {
            $0[device.address] = Registration(source: self, device: device.description)
        }
        _ = MultitouchSupport.registerContactFrameCallback?(ref, Self.frameCallback)
        MultitouchSupport.start?(ref, 0)
    }

    private func remove(_ device: Device) {
        Self.registrations.withLock { $0[device.address] = nil }
        _ = MultitouchSupport.unregisterContactFrameCallback?(device.ref, Self.frameCallback)
        MultitouchSupport.stop?(device.ref)
        MultitouchSupport.release?(device.ref)
    }

    private func describe(_ ref: CMTDeviceRef) -> MultitouchDevice {
        var id: UInt64 = 0
        if MultitouchSupport.deviceID?(ref, &id) != 0 || id == 0 {
            id = UInt64(UInt(bitPattern: ref))
        }
        var width: Int32 = 0
        var height: Int32 = 0
        _ = MultitouchSupport.sensorSurfaceDimensions?(ref, &width, &height)
        return MultitouchDevice(
            id: id,
            isBuiltIn: MultitouchSupport.isBuiltIn?(ref) ?? false,
            // Reported in hundredths of a millimetre
            surfaceSize: CGSize(width: Double(width) / 100, height: Double(height) / 100)
        )
    }

    /// IOKit's default main port, which `kIOMainPortDefault` stands for from macOS 12 on
    private static let mainPort: mach_port_t = 0
}
