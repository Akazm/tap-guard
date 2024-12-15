import AppKit

/// Represents prerequisites required to be satisfied before system-wide event processing can be enabled (`== .all`)
public struct HIDEventDispatcherEnabledPrerequisite: OptionSet, CustomDebugStringConvertible, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// The ``HIDEventDispatcher`` is enabled (see: ``HIDEventDispatcher/isEnabled()``)
    public static let enabled: Self = HIDEventDispatcherEnabledPrerequisite(rawValue: 1 << 0)
    /// The device's screens are not in sleep mode
    public static let screensAwake: Self = HIDEventDispatcherEnabledPrerequisite(rawValue: 1 << 1)
    /// The device is not in sleep mode
    public static let deviceAwake: Self = HIDEventDispatcherEnabledPrerequisite(rawValue: 1 << 2)
    /// Access to macOS Accessibility API has been enabled in System Settings.app
    public static let axGranted: Self = HIDEventDispatcherEnabledPrerequisite(rawValue: 1 << 3)
    /// There's at least one ``HIDEventReceiver`` present in the processing pipeline
    public static let hasReceivers: Self = HIDEventDispatcherEnabledPrerequisite(rawValue: 1 << 4)
    /// No *suspension* (see: ``HIDEventDispatcher/acquireSuspension()``) is present
    public static let allSuspensionsReleased: Self = HIDEventDispatcherEnabledPrerequisite(rawValue: 1 << 5)
    /// Equal to `[` ``HIDEventDispatcherEnabledPrerequisite/enabled``, ``HIDEventDispatcherEnabledPrerequisite/screensAwake``,
    /// ``HIDEventDispatcherEnabledPrerequisite/deviceAwake``, ``HIDEventDispatcherEnabledPrerequisite/axGranted``,
    /// ``HIDEventDispatcherEnabledPrerequisite/hasReceivers``,
    /// ``HIDEventDispatcherEnabledPrerequisite/allSuspensionsReleased`` `]`
    public static let all: Self = [
        enabled,
        screensAwake,
        deviceAwake,
        axGranted,
        hasReceivers,
        allSuspensionsReleased,
    ]

    /// Evaluates to `true` if `self` satisfies the conditions (`self == .all`)
    public var satisfied: Bool {
        self == .all
    }

    static var enabledDebugDescription: String {
        ".enabled"
    }

    static var screensAwakeDebugDescription: String {
        ".screensAwake"
    }

    static var deviceAwakeDebugDescription: String {
        ".deviceAwake"
    }

    static var axGrantedDebugDescription: String {
        ".axGranted"
    }

    static var hasReceiversDebugDescription: String {
        ".hasReceivers"
    }

    static var allSuspensionsReleasedDebugDescription: String {
        ".allSuspensionsReleased"
    }

    public var debugDescription: String {
        var remainingBits = rawValue
        var bitMask: RawValue = 1
        let options = AnySequence {
            AnyIterator {
                while remainingBits != 0 {
                    defer {
                        bitMask = bitMask &* 2
                    }
                    if remainingBits & bitMask != 0 {
                        remainingBits = remainingBits & ~bitMask
                        return Self(rawValue: bitMask)
                    }
                }
                return nil
            }
        }
        let rawValues = options.compactMap { value in
            return switch value {
                case .enabled:
                    Self.enabledDebugDescription
                case .screensAwake:
                    Self.screensAwakeDebugDescription
                case .deviceAwake:
                    Self.deviceAwakeDebugDescription
                case .axGranted:
                    Self.axGrantedDebugDescription
                case .hasReceivers:
                    Self.hasReceiversDebugDescription
                case .allSuspensionsReleased:
                    Self.allSuspensionsReleasedDebugDescription
                default:
                    nil
            }
        }
        return "[\(rawValues.joined(separator: ","))]"
    }
}
