import CMultitouchSupport
import Darwin
import IOKit

/// The private `MultitouchSupport.framework`, resolved at runtime.
///
/// Every function is optional: a macOS release dropping one leaves ``isAvailable`` false and the ``MultitouchDispatcher``
/// silent, rather than keeping the process from launching.
enum MultitouchSupport {
    private nonisolated(unsafe) static let framework = dlopen(
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY
    )

    static let createList = symbol("MTDeviceCreateList", as: CMTDeviceCreateListFunction.self)
    static let createFromService = symbol("MTDeviceCreateFromService", as: CMTDeviceCreateFromServiceFunction.self)
    static let registerContactFrameCallback = symbol(
        "MTRegisterContactFrameCallback", as: CMTRegisterContactFrameCallbackFunction.self
    )
    static let unregisterContactFrameCallback = symbol(
        "MTUnregisterContactFrameCallback", as: CMTUnregisterContactFrameCallbackFunction.self
    )
    static let start = symbol("MTDeviceStart", as: CMTDeviceStartFunction.self)
    static let stop = symbol("MTDeviceStop", as: CMTDeviceStopFunction.self)
    static let release = symbol("MTDeviceRelease", as: CMTDeviceReleaseFunction.self)
    static let isBuiltIn = symbol("MTDeviceIsBuiltIn", as: CMTDeviceIsBuiltInFunction.self)
    static let isRunning = symbol("MTDeviceIsRunning", as: CMTDeviceIsRunningFunction.self)
    static let sensorSurfaceDimensions = symbol(
        "MTDeviceGetSensorSurfaceDimensions", as: CMTDeviceGetSensorSurfaceDimensionsFunction.self
    )
    static let deviceID = symbol("MTDeviceGetDeviceID", as: CMTDeviceGetDeviceIDFunction.self)

    /// Whether the functions a ``MultitouchDispatcher`` cannot do without are present
    static var isAvailable: Bool {
        registerContactFrameCallback != nil
            && unregisterContactFrameCallback != nil
            && start != nil
            && stop != nil
            && (createList != nil || createFromService != nil)
    }

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let framework, let pointer = dlsym(framework, name) else {
            return nil
        }
        return unsafeBitCast(pointer, to: type)
    }
}
