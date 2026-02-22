import Foundation

public struct SurveySessionRecord: Identifiable, Codable, Equatable {
    public let id: String
    public let name: String
    public let createdAt: TimeInterval
    public let updatedAt: TimeInterval
    public let sampleCount: Int
    public let heatmapPointCount: Int
    public let manualLandmarkCount: Int
    public let roamEventCount: Int
    public let meshFilename: String?
}

public struct SurveyRoamEventRecord: Codable, Equatable {
    public let timestamp: TimeInterval
    public let ssid: String
    public let fromBSSID: String
    public let toBSSID: String
    public let x: Float
    public let y: Float
    public let z: Float
    public let latitude: Double
    public let longitude: Double
}

public struct SurveySessionSnapshot: Codable, Equatable {
    public let record: SurveySessionRecord
    public let samples: [SurveySample]
    public let heatmapPoints: [WiFiHeatmapPoint]
    public let manualLandmarks: [ManualAPLandmark]
    public let roamEvents: [SurveyRoamEventRecord]
}

public struct SurveySessionComparison: Identifiable, Equatable {
    public let id = UUID()
    public let baselineName: String
    public let currentName: String
    public let overlapCount: Int
    public let averageRSSIDelta: Double
    public let improvedCount: Int
    public let degradedCount: Int
}
