import CMultitouchSupport
import CoreGraphics
import Foundation

/// A trackpad, or another multitouch surface, delivering ``TouchFrame``s
public struct MultitouchDevice: Sendable, Hashable, Codable {
    /// The framework's identifier of the device, or the device's address where the framework has none
    public let id: UInt64
    /// Whether the device is the computer's own trackpad rather than an external one
    public let isBuiltIn: Bool
    /// The sensor's size in millimetres
    public let surfaceSize: CGSize

    public init(id: UInt64, isBuiltIn: Bool, surfaceSize: CGSize) {
        self.id = id
        self.isBuiltIn = isBuiltIn
        self.surfaceSize = surfaceSize
    }
}

/// How a contact relates to the surface. Frames list hovering contacts as well as touching ones.
public struct TouchStage: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let notTracking = Self(rawValue: Int32(CMTTouchStageNotTracking.rawValue))
    public static let startInRange = Self(rawValue: Int32(CMTTouchStageStartInRange.rawValue))
    public static let hoverInRange = Self(rawValue: Int32(CMTTouchStageHoverInRange.rawValue))
    /// The finger just landed
    public static let makeTouch = Self(rawValue: Int32(CMTTouchStageMakeTouch.rawValue))
    public static let touching = Self(rawValue: Int32(CMTTouchStageTouching.rawValue))
    /// The finger just lifted
    public static let breakTouch = Self(rawValue: Int32(CMTTouchStageBreakTouch.rawValue))
    public static let lingerInRange = Self(rawValue: Int32(CMTTouchStageLingerInRange.rawValue))
    public static let outOfRange = Self(rawValue: Int32(CMTTouchStageOutOfRange.rawValue))

    /// Whether the finger is on the surface
    public var isTouching: Bool {
        self == .makeTouch || self == .touching
    }
}

/// One contact of a ``TouchFrame``
public struct Touch: Sendable, Hashable, Codable {
    /// Stays the same for a finger from landing to lifting
    public let identifier: Int32
    public let stage: TouchStage
    /// In 0...1 of the surface's width and height, with the origin at the bottom left
    public let position: CGPoint
    /// In ``position``'s units per second
    public let velocity: CGPoint
    /// The contact's area, growing with pressure
    public let size: Float
    public let pressure: Float
    /// The contact ellipse
    public let angle: Float
    public let majorAxis: Float
    public let minorAxis: Float
    /// In millimetres, around the surface's centre
    public let absolutePosition: CGPoint

    public init(
        identifier: Int32,
        stage: TouchStage,
        position: CGPoint,
        velocity: CGPoint = .zero,
        size: Float = 0,
        pressure: Float = 0,
        angle: Float = 0,
        majorAxis: Float = 0,
        minorAxis: Float = 0,
        absolutePosition: CGPoint = .zero
    ) {
        self.identifier = identifier
        self.stage = stage
        self.position = position
        self.velocity = velocity
        self.size = size
        self.pressure = pressure
        self.angle = angle
        self.majorAxis = majorAxis
        self.minorAxis = minorAxis
        self.absolutePosition = absolutePosition
    }

    init(record: CMTTouch) {
        self.init(
            identifier: record.identifier,
            stage: TouchStage(rawValue: record.stage),
            position: CGPoint(x: CGFloat(record.normalized.position.x), y: CGFloat(record.normalized.position.y)),
            velocity: CGPoint(x: CGFloat(record.normalized.velocity.x), y: CGFloat(record.normalized.velocity.y)),
            size: record.total,
            pressure: record.pressure,
            angle: record.angle,
            majorAxis: record.majorAxis,
            minorAxis: record.minorAxis,
            absolutePosition: CGPoint(x: CGFloat(record.absolute.position.x), y: CGFloat(record.absolute.position.y))
        )
    }

    /// Whether the finger is on the surface
    public var isTouching: Bool {
        stage.isTouching
    }
}

/// Every contact on a device at one moment. Delivered while contacts exist, at the device's own rate: around 50 Hz over
/// Bluetooth, around 90 to 120 Hz for built-in trackpads.
public struct TouchFrame: Sendable, Hashable, Codable {
    public let device: MultitouchDevice
    /// The device's clock, in seconds
    public let timestamp: TimeInterval
    public let frameNumber: Int32
    /// Touching and hovering contacts alike
    public let touches: [Touch]

    public init(device: MultitouchDevice, timestamp: TimeInterval, frameNumber: Int32, touches: [Touch]) {
        self.device = device
        self.timestamp = timestamp
        self.frameNumber = frameNumber
        self.touches = touches
    }

    /// The contacts of fingers on the surface
    public var touchingTouches: [Touch] {
        touches.filter(\.isTouching)
    }
}
