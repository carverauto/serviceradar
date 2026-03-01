import Foundation
import simd

public struct WiFiHeatmapPoint: Identifiable, Codable, Equatable {
    public let id: UUID
    public let timestamp: TimeInterval
    public let bssid: String
    public let ssid: String
    public let rssi: Double
    public let x: Float
    public let y: Float
    public let z: Float

    public var position: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }

    public init(
        id: UUID = UUID(),
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        bssid: String,
        ssid: String,
        rssi: Double,
        position: SIMD3<Float>
    ) {
        self.id = id
        self.timestamp = timestamp
        self.bssid = bssid
        self.ssid = ssid
        self.rssi = rssi
        self.x = position.x
        self.y = position.y
        self.z = position.z
    }
}
