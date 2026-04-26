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

public struct SurveySessionSnapshot: Identifiable, Codable, Equatable {
    public let record: SurveySessionRecord
    public let samples: [SurveySample]
    public let heatmapPoints: [WiFiHeatmapPoint]
    public let manualLandmarks: [ManualAPLandmark]
    public let roamEvents: [SurveyRoamEventRecord]
    public let spectrumSummaries: [SidekickSpectrumSummary]

    public var id: String { record.id }

    public init(
        record: SurveySessionRecord,
        samples: [SurveySample],
        heatmapPoints: [WiFiHeatmapPoint],
        manualLandmarks: [ManualAPLandmark],
        roamEvents: [SurveyRoamEventRecord],
        spectrumSummaries: [SidekickSpectrumSummary] = []
    ) {
        self.record = record
        self.samples = samples
        self.heatmapPoints = heatmapPoints
        self.manualLandmarks = manualLandmarks
        self.roamEvents = roamEvents
        self.spectrumSummaries = spectrumSummaries
    }

    enum CodingKeys: String, CodingKey {
        case record
        case samples
        case heatmapPoints
        case manualLandmarks
        case roamEvents
        case spectrumSummaries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.record = try container.decode(SurveySessionRecord.self, forKey: .record)
        self.samples = try container.decode([SurveySample].self, forKey: .samples)
        self.heatmapPoints = try container.decode([WiFiHeatmapPoint].self, forKey: .heatmapPoints)
        self.manualLandmarks = try container.decode([ManualAPLandmark].self, forKey: .manualLandmarks)
        self.roamEvents = try container.decode([SurveyRoamEventRecord].self, forKey: .roamEvents)
        self.spectrumSummaries = try container.decodeIfPresent(
            [SidekickSpectrumSummary].self,
            forKey: .spectrumSummaries
        ) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(record, forKey: .record)
        try container.encode(samples, forKey: .samples)
        try container.encode(heatmapPoints, forKey: .heatmapPoints)
        try container.encode(manualLandmarks, forKey: .manualLandmarks)
        try container.encode(roamEvents, forKey: .roamEvents)
        try container.encode(spectrumSummaries, forKey: .spectrumSummaries)
    }
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
