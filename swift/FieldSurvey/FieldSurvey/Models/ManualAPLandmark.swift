import Foundation
import simd

public struct ManualAPLandmark: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var label: String
    public var confidence: Double
    public var source: String
    public var createdAt: TimeInterval
    public var updatedAt: TimeInterval
    public var x: Float
    public var y: Float
    public var z: Float

    public var position: SIMD3<Float> {
        get { SIMD3<Float>(x, y, z) }
        set {
            x = newValue.x
            y = newValue.y
            z = newValue.z
        }
    }

    public init(
        id: String,
        label: String,
        confidence: Double,
        source: String,
        createdAt: TimeInterval,
        updatedAt: TimeInterval,
        position: SIMD3<Float>
    ) {
        self.id = id
        self.label = label
        self.confidence = confidence
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.x = position.x
        self.y = position.y
        self.z = position.z
    }
}
