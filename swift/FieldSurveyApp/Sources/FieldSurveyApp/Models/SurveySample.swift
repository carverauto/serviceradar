import Foundation
import simd

/// Represents a single cyber-physical RF sample.
/// In production, this would be mapped directly to an Apache Arrow columnar layout.
public struct SurveySample: Identifiable, Codable {
    public let id: UUID
    public let timestamp: TimeInterval
    
    // Logical Identifiers
    public let bssid: String
    public let ssid: String
    
    // RF Metrics
    public let rssi: Double
    public let frequency: Int // MHz (e.g., 2412, 5180)
    public let securityType: String
    public let isSecure: Bool
    
    // Physical Coordinates (from LiDAR / ARKit)
    public let x: Float
    public let y: Float
    public let z: Float
    
    // Derived Confidence/Uncertainty (0.0 to 1.0)
    public let uncertainty: Float
    
    public init(id: UUID = UUID(), timestamp: TimeInterval = Date().timeIntervalSince1970, bssid: String, ssid: String, rssi: Double, frequency: Int, securityType: String = "Unknown", isSecure: Bool = true, position: simd_float3, uncertainty: Float) {
        self.id = id
        self.timestamp = timestamp
        self.bssid = bssid
        self.ssid = ssid
        self.rssi = rssi
        self.frequency = frequency
        self.securityType = securityType
        self.isSecure = isSecure
        self.x = position.x
        self.y = position.y
        self.z = position.z
        self.uncertainty = uncertainty
    }
}
