import Foundation
import simd

/// Represents a single cyber-physical RF sample.
/// In production, this would be mapped directly to an Apache Arrow columnar layout.
public struct SurveySample: Identifiable, Codable, Equatable {
    public let id: UUID
    public let timestamp: TimeInterval
    
    // Logical Identifiers
    public let scannerDeviceId: String
    public let bssid: String
    public let ssid: String
    
    // RF Metrics
    public let rssi: Double
    public let frequency: Int // MHz (e.g., 2412, 5180)
    public let securityType: String
    public let isSecure: Bool
    
    // RF Vector for KNN Fingerprinting
    // An array of RSSI values representing the local signal environment at the time of sampling.
    public let rfVector: [Double]
    public let bleVector: [Double]
    
    // Physical Coordinates (from LiDAR / ARKit)
    public let x: Float
    public let y: Float
    public let z: Float
    
    // GPS Coordinates
    public let latitude: Double
    public let longitude: Double
    
    // Derived Confidence/Uncertainty (0.0 to 1.0)
    public let uncertainty: Float
    
    public init(id: UUID = UUID(), timestamp: TimeInterval = Date().timeIntervalSince1970, scannerDeviceId: String, bssid: String, ssid: String, rssi: Double, frequency: Int, securityType: String = "Unknown", isSecure: Bool = true, rfVector: [Double] = [], bleVector: [Double] = [], position: simd_float3, latitude: Double = 0.0, longitude: Double = 0.0, uncertainty: Float) {
        self.id = id
        self.timestamp = timestamp
        self.scannerDeviceId = scannerDeviceId
        self.bssid = bssid
        self.ssid = ssid
        self.rssi = rssi
        self.frequency = frequency
        self.securityType = securityType
        self.isSecure = isSecure
        self.rfVector = rfVector
        self.bleVector = bleVector
        self.x = position.x
        self.y = position.y
        self.z = position.z
        self.latitude = latitude
        self.longitude = longitude
        self.uncertainty = uncertainty
    }
}
