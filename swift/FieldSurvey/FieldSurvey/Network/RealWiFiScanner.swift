#if os(iOS)
import Foundation
import Combine
import CoreLocation
import simd

/// Tracks survey pose/location and ingests RF observations from FieldSurvey Sidekick.
/// iPhone Wi-Fi radio data is intentionally not used for survey measurements.
@MainActor
public class RealWiFiScanner: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published public var accessPoints: [String: SurveySample] = [:]
    public var apPositions: [String: SIMD3<Float>] = [:]
    @Published public private(set) var connectedBSSID: String = ""
    @Published public private(set) var roamEvents: [WiFiRoamEvent] = []
    @Published public private(set) var resolvedAPLocations: [String: APResolvedLocation] = [:]
    @Published public private(set) var manualAPLandmarks: [ManualAPLandmark] = []
    @Published public private(set) var heatmapPoints: [WiFiHeatmapPoint] = []
    
    private var locationManager: CLLocationManager
    private var lastLocation: CLLocationCoordinate2D?
    private var timer: Timer?
    private let apLocalizer = APPositionLocalizer()
    private let sidekickAdapter = SidekickScannerAdapter()
    private var latestDevicePose: SIMD3<Float>?
    private let manualAPStoreKey = "manualAPLandmarks"
    private var lastHeatmapSampleByBSSID: [String: (timestamp: TimeInterval, position: SIMD3<Float>)] = [:]
    private let maxHeatmapPoints = 3200
    private var lastPoseHeatmapCaptureTime: TimeInterval = 0
    private var pendingPoseHeatmapPosition: SIMD3<Float>?
    private var poseHeatmapFlushScheduled = false
    private var poseBackendSink: FieldSurveyBackendArrowSink?
    private let poseArrowEncoder = PoseArrowEncoder()
    private var lastPoseStreamTime: TimeInterval = 0
    private let poseStreamMinInterval: TimeInterval = 0.1
    
    public override init() {
        self.locationManager = CLLocationManager()
        super.init()
        self.locationManager.delegate = self
        self.locationManager.requestWhenInUseAuthorization()
        loadManualAPLandmarks()
        restoreManualLandmarksToSamples()
    }
    
    public var isScanning: Bool {
        return timer != nil
    }

    public var isRFEnabled: Bool {
        SettingsManager.shared.rfScanningEnabled
    }

    public var currentDevicePose: SIMD3<Float>? {
        latestDevicePose
    }
    
    public func startScanning() {
        guard SettingsManager.shared.rfScanningEnabled else { return }
        guard timer == nil else { return }
        restoreManualLandmarksToSamples()

        // Keep location metadata current. RF observations come only from Sidekick.
        locationManager.startUpdatingLocation()

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSubnetDevices()
            }
        }
        refreshSubnetDevices()
    }
    
    public func stopScanning(clearData: Bool = false) {
        timer?.invalidate()
        timer = nil
        locationManager.stopUpdatingLocation()
        
        if clearData {
            accessPoints = accessPoints.filter { $0.key.hasPrefix("manual-ap-") }
            apPositions = apPositions.filter { $0.key.hasPrefix("manual-ap-") }
            resolvedAPLocations = resolvedAPLocations.filter { $0.key.hasPrefix("manual-ap-") }
            apLocalizer.clear()
            heatmapPoints.removeAll()
            lastHeatmapSampleByBSSID.removeAll()
        }
    }

    public func setRFScanning(enabled: Bool) {
        if enabled {
            startScanning()
        } else {
            stopScanning(clearData: false)
        }
    }

    public func updateDevicePose(position: SIMD3<Float>) {
        latestDevicePose = position
    }

    public func updateDevicePose(
        position: SIMD3<Float>,
        orientation: simd_quatf,
        monotonicTimestampSeconds: TimeInterval?,
        trackingQuality: String?
    ) {
        latestDevicePose = position
        streamPoseIfNeeded(
            position: position,
            orientation: orientation,
            monotonicTimestampSeconds: monotonicTimestampSeconds,
            trackingQuality: trackingQuality
        )
    }

    public func startPoseStreaming(sessionID: String) {
        stopPoseStreaming()
        guard SettingsManager.shared.authToken != "OFFLINE_MODE" else { return }

        poseBackendSink = FieldSurveyBackendArrowSink(
            baseURL: SettingsManager.shared.apiURL,
            authToken: SettingsManager.shared.authToken,
            sessionID: sessionID,
            stream: .poseSamples
        )
        lastPoseStreamTime = 0
    }

    public func stopPoseStreaming() {
        poseBackendSink?.close()
        poseBackendSink = nil
        lastPoseStreamTime = 0
    }

    public func queueHeatmapCaptureFromCurrentPose(position: SIMD3<Float>) {
        pendingPoseHeatmapPosition = position
        guard !poseHeatmapFlushScheduled else { return }
        poseHeatmapFlushScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.poseHeatmapFlushScheduled = false
            guard let pending = self.pendingPoseHeatmapPosition else { return }
            self.pendingPoseHeatmapPosition = nil
            self.recordHeatmapFromCurrentPose(position: pending)
        }
    }

    public func recordHeatmapFromCurrentPose(position: SIMD3<Float>) {
        let now = Date().timeIntervalSince1970
        if now - lastPoseHeatmapCaptureTime < 0.9 {
            return
        }
        lastPoseHeatmapCaptureTime = now

        let candidates = accessPoints.values
            .filter { sample in
                sample.frequency > 0 &&
                    !sample.bssid.hasPrefix("manual-ap-") &&
                    !sample.bssid.hasPrefix("mdns-")
            }
            .sorted { $0.rssi > $1.rssi }

        for sample in candidates.prefix(3) {
            appendHeatmapPoint(
                bssid: sample.bssid,
                ssid: sample.ssid,
                rssi: sample.rssi,
                position: position
            )
        }
    }

    public func ingestSidekickObservations(_ observations: [SidekickObservation]) {
        guard SettingsManager.shared.rfScanningEnabled else { return }
        guard !observations.isEmpty else { return }

        ingestSampleEvents(
            sidekickAdapter.events(
                from: observations,
                context: SidekickScannerAdapterContext(
                    scannerDeviceID: SettingsManager.shared.scannerDeviceId,
                    latestDevicePose: latestDevicePose,
                    location: lastLocation
                )
            )
        )
    }
    
    public func updatePosition(bssid: String, position: SIMD3<Float>) {
        if let existing = accessPoints[bssid] {
            let updated = SurveySample(
                id: existing.id,
                timestamp: existing.timestamp,
                scannerDeviceId: existing.scannerDeviceId,
                bssid: existing.bssid,
                ssid: existing.ssid,
                rssi: existing.rssi,
                frequency: existing.frequency,
                securityType: existing.securityType,
                isSecure: existing.isSecure,
                rfVector: existing.rfVector,
                bleVector: existing.bleVector,
                position: position,
                latitude: existing.latitude,
                longitude: existing.longitude,
                uncertainty: existing.uncertainty,
                ipAddress: existing.ipAddress,
                hostname: existing.hostname
            )
            accessPoints[bssid] = updated
        }
    }
    
    private func refreshSubnetDevices() {
        guard SettingsManager.shared.rfScanningEnabled else { return }

        // Ingest mDNS/Bonjour Subnet Devices
        let mdnsDevices = SubnetScanner.shared.discoveredDevices
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            var events: [SurveySampleIngestEvent] = []
            for (_, data) in mdnsDevices {
                let pseudoBssid = "mdns-\(data.ip)"
                let sample = SurveySample(
                    id: UUID(),
                    timestamp: Date().timeIntervalSince1970,
                    scannerDeviceId: SettingsManager.shared.scannerDeviceId,
                    bssid: pseudoBssid,
                    ssid: data.hostname,
                    rssi: -50.0, // Fixed pseudo-RSSI for wired/LAN devices
                    frequency: 0,
                    securityType: "mDNS Device",
                    isSecure: true,
                    rfVector: [],
                    position: SIMD3<Float>(0, 0, 0), // Will be transformed by AR Session Anchors
                    latitude: self.lastLocation?.latitude ?? 0.0,
                    longitude: self.lastLocation?.longitude ?? 0.0,
                    uncertainty: 0.1,
                    ipAddress: data.ip,
                    hostname: data.hostname
                )
                events.append(SurveySampleIngestEvent(source: .subnet, sample: sample))
            }
            self.ingestSampleEvents(events)
        }
    }
    
    // MARK: - CLLocationManagerDelegate
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // GPS locations sync with RoomPlan/LiDAR coordinate normalization (WGS84 -> SceneKit space)
        lastLocation = locations.last?.coordinate
    }

    public func addManualAccessPoint(
        label: String,
        position: SIMD3<Float>,
        confidence: Double = 0.9,
        source: String = "ai-label"
    ) {
        let boundedConfidence = min(max(confidence, 0.0), 1.0)
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLabel = trimmedLabel.isEmpty ? "AP Candidate" : trimmedLabel
        let now = Date().timeIntervalSince1970

        var landmarks = manualAPLandmarks
        if let existingIndex = nearestManualLandmarkIndex(to: position, maxDistance: 0.75, landmarks: landmarks) {
            var existing = landmarks[existingIndex]
            existing.label = cleanLabel
            existing.confidence = max(existing.confidence, boundedConfidence)
            existing.source = source
            existing.position = position
            existing.updatedAt = now
            landmarks[existingIndex] = existing
            manualAPLandmarks = landmarks
            persistManualAPLandmarks()
            upsertManualSample(from: existing)
            return
        }

        let landmark = ManualAPLandmark(
            id: UUID().uuidString,
            label: cleanLabel,
            confidence: boundedConfidence,
            source: source,
            createdAt: now,
            updatedAt: now,
            position: position
        )

        landmarks.append(landmark)
        manualAPLandmarks = landmarks
        persistManualAPLandmarks()
        upsertManualSample(from: landmark)
    }

    public func renameManualAccessPoint(id: String, newLabel: String) {
        guard let index = manualAPLandmarks.firstIndex(where: { $0.id == id }) else { return }
        let trimmedLabel = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLabel = trimmedLabel.isEmpty ? "AP Candidate" : trimmedLabel

        var updated = manualAPLandmarks[index]
        updated.label = cleanLabel
        updated.updatedAt = Date().timeIntervalSince1970
        manualAPLandmarks[index] = updated
        persistManualAPLandmarks()
        upsertManualSample(from: updated)
    }

    public func deleteManualAccessPoint(id: String) {
        guard let index = manualAPLandmarks.firstIndex(where: { $0.id == id }) else { return }
        let removed = manualAPLandmarks.remove(at: index)
        persistManualAPLandmarks()

        let key = manualBSSID(for: removed)
        accessPoints.removeValue(forKey: key)
        apPositions.removeValue(forKey: key)
        resolvedAPLocations.removeValue(forKey: key)
        heatmapPoints.removeAll { $0.bssid == key }
        lastHeatmapSampleByBSSID.removeValue(forKey: key)
    }

    public func loadSessionSnapshot(_ snapshot: SurveySessionSnapshot) {
        var rebuilt: [String: SurveySample] = [:]
        for sample in snapshot.samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            rebuilt[sample.bssid] = sample
        }
        accessPoints = rebuilt

        apPositions = [:]
        resolvedAPLocations = [:]
        for (bssid, sample) in rebuilt {
            let pos = SIMD3<Float>(sample.x, sample.y, sample.z)
            apPositions[bssid] = pos

            if bssid.hasPrefix("manual-ap-") {
                let confidence = Float(max(0.0, min(1.0, 1.0 - sample.uncertainty)))
                resolvedAPLocations[bssid] = APResolvedLocation(
                    position: pos,
                    confidence: confidence,
                    observationCount: 1,
                    residualErrorMeters: 0.0
                )
            }
        }

        heatmapPoints = snapshot.heatmapPoints
        lastHeatmapSampleByBSSID = [:]
        for point in snapshot.heatmapPoints.suffix(400) {
            lastHeatmapSampleByBSSID[point.bssid] = (timestamp: point.timestamp, position: point.position)
        }

        manualAPLandmarks = snapshot.manualLandmarks
        persistManualAPLandmarks()

        roamEvents = snapshot.roamEvents.map { record in
            WiFiRoamEvent(
                timestamp: record.timestamp,
                ssid: record.ssid,
                fromBSSID: record.fromBSSID,
                toBSSID: record.toBSSID,
                position: SIMD3<Float>(record.x, record.y, record.z),
                latitude: record.latitude,
                longitude: record.longitude
            )
        }

        connectedBSSID = rebuilt.values.sorted(by: { $0.timestamp < $1.timestamp }).last?.bssid ?? ""
    }

    private func nearestManualLandmarkIndex(
        to position: SIMD3<Float>,
        maxDistance: Float,
        landmarks: [ManualAPLandmark]
    ) -> Int? {
        landmarks.enumerated()
            .map { (idx: $0.offset, distance: simd_distance($0.element.position, position)) }
            .filter { $0.distance <= maxDistance }
            .min { $0.distance < $1.distance }?
            .idx
    }

    private func manualBSSID(for landmark: ManualAPLandmark) -> String {
        "manual-ap-\(landmark.id)"
    }

    private func loadManualAPLandmarks() {
        guard let data = UserDefaults.standard.data(forKey: manualAPStoreKey) else {
            manualAPLandmarks = []
            return
        }

        if let decoded = try? JSONDecoder().decode([ManualAPLandmark].self, from: data) {
            manualAPLandmarks = decoded
        } else {
            manualAPLandmarks = []
        }
    }

    private func persistManualAPLandmarks() {
        guard let data = try? JSONEncoder().encode(manualAPLandmarks) else { return }
        UserDefaults.standard.set(data, forKey: manualAPStoreKey)
    }

    private func restoreManualLandmarksToSamples() {
        for landmark in manualAPLandmarks {
            upsertManualSample(from: landmark)
        }
    }

    private func upsertManualSample(from landmark: ManualAPLandmark) {
        let key = manualBSSID(for: landmark)
        let boundedConfidence = min(max(landmark.confidence, 0.0), 1.0)
        let rssi = -65.0 + (boundedConfidence * 20.0)

        let sample = SurveySample(
            id: UUID(),
            timestamp: Date().timeIntervalSince1970,
            scannerDeviceId: SettingsManager.shared.scannerDeviceId,
            bssid: key,
            ssid: landmark.label,
            rssi: rssi,
            frequency: 5180,
            securityType: "Manual AP (\(landmark.source))",
            isSecure: true,
            rfVector: [],
            position: landmark.position,
            latitude: lastLocation?.latitude ?? 0.0,
            longitude: lastLocation?.longitude ?? 0.0,
            uncertainty: Float(1.0 - boundedConfidence)
        )

        accessPoints[key] = sample
        apPositions[key] = landmark.position
        resolvedAPLocations[key] = APResolvedLocation(
            position: landmark.position,
            confidence: Float(boundedConfidence),
            observationCount: 1,
            residualErrorMeters: 0.0
        )
    }

    private func ingestSampleEvents(_ events: [SurveySampleIngestEvent]) {
        guard !events.isEmpty else { return }
        var updatedAPs = accessPoints

        for event in events {
            updatedAPs[event.sample.bssid] = event.sample

            if let heatmapPosition = event.heatmapPosition {
                appendHeatmapPoint(
                    bssid: event.sample.bssid,
                    ssid: event.sample.ssid,
                    rssi: event.sample.rssi,
                    position: heatmapPosition
                )
            }

            if let localizationObservation = event.localizationObservation {
                ingestLocalizationObservation(localizationObservation)
            }
        }

        accessPoints = updatedAPs
    }

    private func ingestSampleEvent(_ event: SurveySampleIngestEvent) {
        ingestSampleEvents([event])
    }

    private func ingestLocalizationObservation(_ observation: APPositionObservation) {
        if let resolved = apLocalizer.addObservation(observation) {
            resolvedAPLocations[observation.bssid] = resolved
            apPositions[observation.bssid] = resolved.position
        }
    }

    private func appendHeatmapPoint(bssid: String, ssid: String, rssi: Double, position: SIMD3<Float>) {
        let now = Date().timeIntervalSince1970

        if let previous = lastHeatmapSampleByBSSID[bssid] {
            let elapsed = now - previous.timestamp
            let movement = simd_distance(position, previous.position)
            if elapsed < 0.7 && movement < 0.25 {
                return
            }
        }

        lastHeatmapSampleByBSSID[bssid] = (timestamp: now, position: position)
        heatmapPoints.append(
            WiFiHeatmapPoint(
                timestamp: now,
                bssid: bssid,
                ssid: ssid,
                rssi: rssi,
                position: position
            )
        )

        if heatmapPoints.count > maxHeatmapPoints {
            heatmapPoints.removeFirst(heatmapPoints.count - maxHeatmapPoints)
        }
    }

    private func streamPoseIfNeeded(
        position: SIMD3<Float>,
        orientation: simd_quatf,
        monotonicTimestampSeconds: TimeInterval?,
        trackingQuality: String?
    ) {
        guard let poseBackendSink else { return }

        let now = Date().timeIntervalSince1970
        guard now - lastPoseStreamTime >= poseStreamMinInterval else { return }
        lastPoseStreamTime = now

        let monotonicNanos = monotonicTimestampSeconds.map { seconds in
            UInt64(max(0, seconds * 1_000_000_000))
        }

        let sample = FieldSurveyPoseSample(
            scannerDeviceID: SettingsManager.shared.scannerDeviceId,
            capturedAtUnixNanos: Int64(now * 1_000_000_000),
            capturedAtMonotonicNanos: monotonicNanos,
            position: position,
            orientation: orientation,
            latitude: lastLocation?.latitude,
            longitude: lastLocation?.longitude,
            altitude: nil,
            accuracyMeters: nil,
            trackingQuality: trackingQuality
        )

        do {
            let payload = try poseArrowEncoder.encode(samples: [sample])
            Task { [poseBackendSink] in
                try? await poseBackendSink.send(payload)
            }
        } catch {
            // Keep AR capture hot; pose streaming errors are surfaced by backend stream diagnostics.
        }
    }

}
#endif
