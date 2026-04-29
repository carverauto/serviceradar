import Foundation

public enum FieldSurveyCaptureMode: String, Codable, Equatable, Sendable {
    case fullRoomScan
    case rfUpdate

    public var isRFUpdate: Bool {
        self == .rfUpdate
    }
}

public struct SurveySessionRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let createdAt: TimeInterval
    public let updatedAt: TimeInterval
    public let sampleCount: Int
    public let heatmapPointCount: Int
    public let manualLandmarkCount: Int
    public let roamEventCount: Int
    public let meshFilename: String?
    public let pointCloudFilename: String?
}

public struct FieldSurveySessionUploadMetadata: Codable, Equatable, Sendable {
    public let siteID: String?
    public let siteName: String?
    public let buildingID: String?
    public let buildingName: String?
    public let floorID: String?
    public let floorName: String?
    public let floorIndex: Int?
    public let tags: [String]
    public let metadata: [String: String]

    public init(
        siteID: String? = nil,
        siteName: String? = nil,
        buildingID: String? = nil,
        buildingName: String? = nil,
        floorID: String? = nil,
        floorName: String? = nil,
        floorIndex: Int? = nil,
        tags: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.siteID = Self.clean(siteID)
        self.siteName = Self.clean(siteName)
        self.buildingID = Self.clean(buildingID)
        self.buildingName = Self.clean(buildingName)
        self.floorID = Self.clean(floorID)
        self.floorName = Self.clean(floorName)
        self.floorIndex = floorIndex
        self.tags = tags.compactMap(Self.clean).reduce(into: []) { result, tag in
            guard !result.contains(tag) else { return }
            result.append(tag)
        }
        self.metadata = metadata.reduce(into: [:]) { result, entry in
            guard let key = Self.clean(entry.key), let value = Self.clean(entry.value) else { return }
            result[key] = value
        }
    }

    public var isEmpty: Bool {
        siteID == nil &&
            siteName == nil &&
            buildingID == nil &&
            buildingName == nil &&
            floorID == nil &&
            floorName == nil &&
            floorIndex == nil &&
            tags.isEmpty &&
            metadata.isEmpty
    }

    public func merged(record: SurveySessionRecord, snapshot: SurveySessionSnapshot? = nil) -> FieldSurveySessionUploadMetadata {
        var mergedMetadata = metadata
        mergedMetadata["session_name"] = record.name
        mergedMetadata["created_at_unix"] = String(record.createdAt)
        mergedMetadata["updated_at_unix"] = String(record.updatedAt)
        mergedMetadata["sample_count"] = String(record.sampleCount)
        mergedMetadata["heatmap_point_count"] = String(record.heatmapPointCount)
        mergedMetadata["manual_landmark_count"] = String(record.manualLandmarkCount)
        mergedMetadata["roam_event_count"] = String(record.roamEventCount)
        if let snapshot {
            mergedMetadata["spectrum_summary_count"] = String(snapshot.spectrumSummaries.count)
            mergedMetadata["floorplan_segment_count"] = String(snapshot.floorplanSegments.count)
        }

        let standardTags = ["ios", "fieldsurvey"]
        return FieldSurveySessionUploadMetadata(
            siteID: siteID,
            siteName: siteName,
            buildingID: buildingID,
            buildingName: buildingName,
            floorID: floorID,
            floorName: floorName,
            floorIndex: floorIndex,
            tags: tags + standardTags,
            metadata: mergedMetadata
        )
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(160))
    }
}

public struct SurveyRoamEventRecord: Codable, Equatable, Sendable {
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

public struct SurveySessionSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let record: SurveySessionRecord
    public let samples: [SurveySample]
    public let heatmapPoints: [WiFiHeatmapPoint]
    public let manualLandmarks: [ManualAPLandmark]
    public let roamEvents: [SurveyRoamEventRecord]
    public let spectrumSummaries: [SidekickSpectrumSummary]
    public let floorplanSegments: [SurveyFloorplanSegment]
    public let uploadMetadata: FieldSurveySessionUploadMetadata?

    public var id: String { record.id }

    public init(
        record: SurveySessionRecord,
        samples: [SurveySample],
        heatmapPoints: [WiFiHeatmapPoint],
        manualLandmarks: [ManualAPLandmark],
        roamEvents: [SurveyRoamEventRecord],
        spectrumSummaries: [SidekickSpectrumSummary] = [],
        floorplanSegments: [SurveyFloorplanSegment] = [],
        uploadMetadata: FieldSurveySessionUploadMetadata? = nil
    ) {
        self.record = record
        self.samples = samples
        self.heatmapPoints = heatmapPoints
        self.manualLandmarks = manualLandmarks
        self.roamEvents = roamEvents
        self.spectrumSummaries = spectrumSummaries
        self.floorplanSegments = floorplanSegments
        self.uploadMetadata = uploadMetadata
    }

    enum CodingKeys: String, CodingKey {
        case record
        case samples
        case heatmapPoints
        case manualLandmarks
        case roamEvents
        case spectrumSummaries
        case floorplanSegments
        case uploadMetadata
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
        self.floorplanSegments = try container.decodeIfPresent(
            [SurveyFloorplanSegment].self,
            forKey: .floorplanSegments
        ) ?? []
        self.uploadMetadata = try container.decodeIfPresent(
            FieldSurveySessionUploadMetadata.self,
            forKey: .uploadMetadata
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(record, forKey: .record)
        try container.encode(samples, forKey: .samples)
        try container.encode(heatmapPoints, forKey: .heatmapPoints)
        try container.encode(manualLandmarks, forKey: .manualLandmarks)
        try container.encode(roamEvents, forKey: .roamEvents)
        try container.encode(spectrumSummaries, forKey: .spectrumSummaries)
        try container.encode(floorplanSegments, forKey: .floorplanSegments)
        try container.encodeIfPresent(uploadMetadata, forKey: .uploadMetadata)
    }
}

public struct SurveySessionComparison: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let baselineName: String
    public let currentName: String
    public let overlapCount: Int
    public let averageRSSIDelta: Double
    public let improvedCount: Int
    public let degradedCount: Int
}
