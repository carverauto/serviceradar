import Foundation
import simd

/// Represents a single cyber-physical RF sample.
/// In production, this would be mapped directly to an Apache Arrow columnar layout.
public struct SurveySample: Identifiable, Codable, Equatable {
    public static let rfVectorDimensions = 64
    public static let bleVectorDimensions = 64
    public static let missingSignalValue = -100.0

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
    
    // Local Network Discovery (Subnet Sweeping)
    public let ipAddress: String
    public let hostname: String
    
    public init(id: UUID = UUID(), timestamp: TimeInterval = Date().timeIntervalSince1970, scannerDeviceId: String, bssid: String, ssid: String, rssi: Double, frequency: Int, securityType: String = "Unknown", isSecure: Bool = true, rfVector: [Double] = [], bleVector: [Double] = [], position: simd_float3, latitude: Double = 0.0, longitude: Double = 0.0, uncertainty: Float, ipAddress: String = "", hostname: String = "") {
        self.id = id
        self.timestamp = timestamp
        self.scannerDeviceId = scannerDeviceId
        self.bssid = bssid
        self.ssid = ssid
        self.rssi = rssi
        self.frequency = frequency
        self.securityType = securityType
        self.isSecure = isSecure
        self.rfVector = SurveySample.normalizeRFVector(rfVector)
        self.bleVector = SurveySample.normalizeBLEVector(bleVector)
        self.x = position.x
        self.y = position.y
        self.z = position.z
        self.latitude = latitude
        self.longitude = longitude
        self.uncertainty = uncertainty
        self.ipAddress = ipAddress
        self.hostname = hostname
    }

    public static func normalizeRFVector(_ input: [Double]) -> [Double] {
        normalize(input, to: rfVectorDimensions)
    }

    public static func normalizeBLEVector(_ input: [Double]) -> [Double] {
        normalize(input, to: bleVectorDimensions)
    }

    private static func normalize(_ input: [Double], to dimensions: Int) -> [Double] {
        let sanitized = input
            .filter { $0.isFinite }
            .map { max(-100.0, min(0.0, $0)) }

        if sanitized.count >= dimensions {
            return Array(sanitized.prefix(dimensions))
        }

        return sanitized + Array(repeating: missingSignalValue, count: dimensions - sanitized.count)
    }
}
