#if os(iOS)
import Foundation
import Combine

@available(iOS 16.0, *)
@MainActor
public final class SurveySessionStore: ObservableObject {
    @Published public private(set) var sessions: [SurveySessionRecord] = []

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let diskWriter = SurveySessionDiskWriter()

    public init() {
        loadIndex()
    }

    public func saveCurrentSession(
        name: String?,
        roomScanner: RoomScanner,
        wifiScanner: RealWiFiScanner,
        spectrumSummaries: [SidekickSpectrumSummary] = []
    ) async throws -> SurveySessionRecord {
        try await saveCurrentSession(
            id: UUID().uuidString,
            name: name,
            roomScanner: roomScanner,
            wifiScanner: wifiScanner,
            spectrumSummaries: spectrumSummaries,
            includeMesh: true
        )
    }

    @discardableResult
    public func autosaveCurrentSession(
        id: String,
        name: String?,
        roomScanner: RoomScanner,
        wifiScanner: RealWiFiScanner,
        spectrumSummaries: [SidekickSpectrumSummary] = [],
        includeMesh: Bool = false
    ) async throws -> SurveySessionRecord {
        try await saveCurrentSession(
            id: id,
            name: name,
            roomScanner: roomScanner,
            wifiScanner: wifiScanner,
            spectrumSummaries: spectrumSummaries,
            includeMesh: includeMesh
        )
    }

    private func saveCurrentSession(
        id: String,
        name: String?,
        roomScanner: RoomScanner,
        wifiScanner: RealWiFiScanner,
        spectrumSummaries: [SidekickSpectrumSummary],
        includeMesh: Bool
    ) async throws -> SurveySessionRecord {
        try ensureDirectory()

        let now = Date().timeIntervalSince1970
        let existing = sessions.first { $0.id == id }
        let fallbackName = "Survey \(Self.sessionDateFormatter.string(from: Date()))"
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = (cleanName?.isEmpty == false) ? cleanName! : (existing?.name ?? fallbackName)

        let samples = Array(wifiScanner.accessPoints.values).sorted { $0.timestamp < $1.timestamp }
        let heatmapPoints = wifiScanner.heatmapPoints
        let manualLandmarks = wifiScanner.manualAPLandmarks
        let floorplanSegments = roomScanner.currentFloorplanSegments()
        let roamRecords = wifiScanner.roamEvents.map { roam in
            SurveyRoamEventRecord(
                timestamp: roam.timestamp,
                ssid: roam.ssid,
                fromBSSID: roam.fromBSSID,
                toBSSID: roam.toBSSID,
                x: roam.position.x,
                y: roam.position.y,
                z: roam.position.z,
                latitude: roam.latitude,
                longitude: roam.longitude
            )
        }

        let meshFilename: String?
        if includeMesh, let meshURL = try? roomScanner.exportCurrentRoomToUSDZ() {
            let targetName = "\(id).usdz"
            let targetURL = sessionsDirectoryURL().appendingPathComponent(targetName)
            if fileManager.fileExists(atPath: targetURL.path) {
                try? fileManager.removeItem(at: targetURL)
            }
            try? fileManager.copyItem(at: meshURL, to: targetURL)
            meshFilename = targetName
        } else {
            meshFilename = existing?.meshFilename
        }

        let record = SurveySessionRecord(
            id: id,
            name: sessionName,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            sampleCount: samples.count,
            heatmapPointCount: heatmapPoints.count,
            manualLandmarkCount: manualLandmarks.count,
            roamEventCount: roamRecords.count,
            meshFilename: meshFilename
        )

        let snapshot = SurveySessionSnapshot(
            record: record,
            samples: samples,
            heatmapPoints: heatmapPoints,
            manualLandmarks: manualLandmarks,
            roamEvents: roamRecords,
            spectrumSummaries: spectrumSummaries,
            floorplanSegments: floorplanSegments
        )

        try await diskWriter.writeSnapshot(snapshot, to: sessionFileURL(for: id))

        sessions.removeAll { $0.id == id }
        sessions.insert(record, at: 0)
        await saveIndex()
        return record
    }

    public func loadSession(id: String) -> SurveySessionSnapshot? {
        guard let data = try? Data(contentsOf: sessionFileURL(for: id)) else { return nil }
        return try? decoder.decode(SurveySessionSnapshot.self, from: data)
    }

    public func deleteSession(id: String) {
        sessions.removeAll { $0.id == id }
        try? fileManager.removeItem(at: sessionFileURL(for: id))
        let meshURL = sessionsDirectoryURL().appendingPathComponent("\(id).usdz")
        if fileManager.fileExists(atPath: meshURL.path) {
            try? fileManager.removeItem(at: meshURL)
        }
        Task { await saveIndex() }
    }

    public func compareAgainstCurrent(
        session: SurveySessionRecord,
        currentSamples: [SurveySample]
    ) -> SurveySessionComparison? {
        guard let snapshot = loadSession(id: session.id) else { return nil }

        let baselineByBSSID = meanRSSIByBSSID(snapshot.samples)
        let currentByBSSID = meanRSSIByBSSID(currentSamples)
        let overlap = Set(baselineByBSSID.keys).intersection(Set(currentByBSSID.keys))
        guard !overlap.isEmpty else {
            return SurveySessionComparison(
                baselineName: session.name,
                currentName: "Current Scan",
                overlapCount: 0,
                averageRSSIDelta: 0,
                improvedCount: 0,
                degradedCount: 0
            )
        }

        var deltaSum = 0.0
        var improved = 0
        var degraded = 0

        for bssid in overlap {
            guard let baseline = baselineByBSSID[bssid], let current = currentByBSSID[bssid] else { continue }
            let delta = current - baseline
            deltaSum += delta
            if delta > 2.0 {
                improved += 1
            } else if delta < -2.0 {
                degraded += 1
            }
        }

        let avgDelta = deltaSum / Double(max(overlap.count, 1))
        return SurveySessionComparison(
            baselineName: session.name,
            currentName: "Current Scan",
            overlapCount: overlap.count,
            averageRSSIDelta: avgDelta,
            improvedCount: improved,
            degradedCount: degraded
        )
    }

    private func meanRSSIByBSSID(_ samples: [SurveySample]) -> [String: Double] {
        var aggregate: [String: (sum: Double, count: Int)] = [:]
        for sample in samples {
            guard sample.frequency > 0, !sample.bssid.hasPrefix("manual-ap-"), !sample.bssid.hasPrefix("mdns-") else {
                continue
            }
            var slot = aggregate[sample.bssid] ?? (sum: 0, count: 0)
            slot.sum += sample.rssi
            slot.count += 1
            aggregate[sample.bssid] = slot
        }

        var result: [String: Double] = [:]
        for (bssid, slot) in aggregate where slot.count > 0 {
            result[bssid] = slot.sum / Double(slot.count)
        }
        return result
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexFileURL()) else {
            sessions = []
            return
        }

        if let decoded = try? decoder.decode([SurveySessionRecord].self, from: data) {
            sessions = decoded.sorted { $0.createdAt > $1.createdAt }
        } else {
            sessions = []
        }
    }

    private func saveIndex() async {
        try? ensureDirectory()
        try? await diskWriter.writeIndex(sessions.sorted { $0.createdAt > $1.createdAt }, to: indexFileURL())
    }

    private func ensureDirectory() throws {
        let dir = sessionsDirectoryURL()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func sessionsDirectoryURL() -> URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FieldSurveySessions", isDirectory: true)
    }

    private func indexFileURL() -> URL {
        sessionsDirectoryURL().appendingPathComponent("index.json")
    }

    private func sessionFileURL(for id: String) -> URL {
        sessionsDirectoryURL().appendingPathComponent("\(id).json")
    }

    private static let sessionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

private actor SurveySessionDiskWriter {
    private let encoder: JSONEncoder

    init() {
        encoder = JSONEncoder()
    }

    func writeSnapshot(_ snapshot: SurveySessionSnapshot, to url: URL) throws {
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    func writeIndex(_ sessions: [SurveySessionRecord], to url: URL) throws {
        let data = try encoder.encode(sessions)
        try data.write(to: url, options: .atomic)
    }
}
#endif
