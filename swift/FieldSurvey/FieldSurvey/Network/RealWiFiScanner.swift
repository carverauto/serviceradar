#if os(iOS)
import Foundation
import Combine
import NetworkExtension
import CoreLocation
import simd

/// A real Wi-Fi scanner implementation integrating public APIs.
/// Uses `NEHotspotNetwork.fetchCurrent` combined with standard CoreLocation scanning for legitimate App Store/Enterprise apps.
/// Also provides the implementation for `NEHotspotHelper` which requires the `com.apple.developer.networking.HotspotHelper` entitlement to receive the full scan list.
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
    private var hotspotHelperRegistered = false
    private let apLocalizer = APPositionLocalizer()
    private var latestDevicePose: SIMD3<Float>?
    private let manualAPStoreKey = "manualAPLandmarks"
    private var lastHeatmapSampleByBSSID: [String: (timestamp: TimeInterval, position: SIMD3<Float>)] = [:]
    private let maxHeatmapPoints = 3200
    private var lastPoseHeatmapCaptureTime: TimeInterval = 0
    private var pendingPoseHeatmapPosition: SIMD3<Float>?
    private var poseHeatmapFlushScheduled = false
    
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
    
    public func startScanning() {
        guard SettingsManager.shared.rfScanningEnabled else { return }
        guard timer == nil else { return }
        restoreManualLandmarksToSamples()

        // Start CoreLocation to trigger base station updates and ensure precise spatial anchors
        locationManager.startUpdatingLocation()
        
        // Setup Hotspot Helper once to capture network interfaces (Requires Apple Entitlement for Enterprise Use)
        if !hotspotHelperRegistered {
            hotspotHelperRegistered = true
            let options: [String: NSObject] = [kNEHotspotHelperOptionDisplayName: "ServiceRadar Scanner" as NSObject]
            let queue = DispatchQueue(label: "com.serviceradar.wifi", attributes: .concurrent)
            
            NEHotspotHelper.register(options: options, queue: queue) { cmd in
                if cmd.commandType == .evaluate || cmd.commandType == .filterScanList {
                    if let networkList = cmd.networkList {
                        struct NetData: Sendable {
                            let bssid: String
                            let ssid: String
                            let signalStrength: Double
                            let isSecure: Bool
                        }
                        
                        let nets = networkList.map {
                            NetData(
                                bssid: $0.bssid,
                                ssid: $0.ssid,
                                signalStrength: $0.signalStrength,
                                isSecure: $0.isSecure
                            )
                        }
                        
                        Task { @MainActor [weak self] in
                            guard let self = self, SettingsManager.shared.rfScanningEnabled else { return }
                            var newAPs = self.accessPoints
                            
                            let sortedNetworks = nets.sorted { $0.bssid < $1.bssid }
                            let currentVector: [Double] = sortedNetworks.map { -100.0 + ($0.signalStrength * 70.0) }
                            
                            for network in nets {
                                let mappedRssi = -100.0 + (network.signalStrength * 70.0)
                                let measurementPosition = self.latestDevicePose ?? SIMD3<Float>(0, 0, 0)
                                
                                let sample = SurveySample(
                                    id: UUID(),
                                    timestamp: Date().timeIntervalSince1970,
                                    scannerDeviceId: SettingsManager.shared.scannerDeviceId,
                                    bssid: network.bssid,
                                    ssid: network.ssid,
                                    rssi: mappedRssi,
                                    frequency: 5180,
                                    securityType: network.isSecure ? "Secure (WPA/WEP)" : "Open",
                                    isSecure: network.isSecure,
                                    rfVector: currentVector,
                                    bleVector: BLEScanner.shared.currentBleVector,
                                    position: measurementPosition,
                                    latitude: self.lastLocation?.latitude ?? 0.0,
                                    longitude: self.lastLocation?.longitude ?? 0.0,
                                    uncertainty: 0.1
                                )
                                newAPs[network.bssid] = sample
                                self.appendHeatmapPoint(
                                    bssid: network.bssid,
                                    ssid: network.ssid,
                                    rssi: mappedRssi,
                                    position: measurementPosition
                                )
                            }
                            self.accessPoints = newAPs
                        }
                    }
                    
                    let response = cmd.createResponse(.success)
                    response.deliver()
                }
            }
        }
        
        // Continuous poll for the currently connected network as a public API baseline
        let sampleRate = SettingsManager.shared.sampleRateSeconds
        timer = Timer.scheduledTimer(withTimeInterval: sampleRate, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchCurrentNetwork()
            }
        }
        fetchCurrentNetwork()
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

    public func setBLEIngestionEnabled(_ enabled: Bool) {
        if !enabled {
            pruneBLESamples()
        }
    }

    public func updateDevicePose(position: SIMD3<Float>) {
        latestDevicePose = position
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
                    sample.securityType != "BLE" &&
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
    
    private func fetchCurrentNetwork() {
        guard SettingsManager.shared.rfScanningEnabled else { return }

        if SettingsManager.shared.showBLEBeacons {
            // Optional BLE ingest for environments where BLE context is needed.
            let blePeripherals = BLEScanner.shared.discoveredPeripherals
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                for (uuid, data) in blePeripherals {
                    let bssid = uuid.uuidString
                    let measurementPosition = self.latestDevicePose ?? SIMD3<Float>(0, 0, 0)
                    let sample = SurveySample(
                        id: UUID(),
                        timestamp: Date().timeIntervalSince1970,
                        scannerDeviceId: SettingsManager.shared.scannerDeviceId,
                        bssid: bssid,
                        ssid: data.name,
                        rssi: data.rssi,
                        frequency: 2402, // Standard BLE Frequency
                        securityType: "BLE",
                        isSecure: false,
                        rfVector: [],
                        bleVector: BLEScanner.shared.currentBleVector,
                        position: measurementPosition,
                        latitude: self.lastLocation?.latitude ?? 0.0,
                        longitude: self.lastLocation?.longitude ?? 0.0,
                        uncertainty: 0.1
                    )
                    self.accessPoints[bssid] = sample
                }
            }
        } else {
            pruneBLESamples()
        }
        
        // Ingest mDNS/Bonjour Subnet Devices
        let mdnsDevices = SubnetScanner.shared.discoveredDevices
        Task { @MainActor [weak self] in
            guard let self = self else { return }
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
                    bleVector: BLEScanner.shared.currentBleVector,
                    position: SIMD3<Float>(0, 0, 0), // Will be transformed by AR Session Anchors
                    latitude: self.lastLocation?.latitude ?? 0.0,
                    longitude: self.lastLocation?.longitude ?? 0.0,
                    uncertainty: 0.1,
                    ipAddress: data.ip,
                    hostname: data.hostname
                )
                self.accessPoints[pseudoBssid] = sample
            }
        }
        
        NEHotspotNetwork.fetchCurrent { network in
            guard let network = network else { return }
            
            // Extract non-Sendable properties before crossing actor boundary
            let bssid = network.bssid
            let ssid = network.ssid
            let signalStrength = network.signalStrength
            let isSecure = network.isSecure
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                let mappedRssi = -100.0 + (signalStrength * 70.0)
                let measurementPosition = self.latestDevicePose ?? SIMD3<Float>(0, 0, 0)
                
                let sample = SurveySample(
                    id: UUID(),
                    timestamp: Date().timeIntervalSince1970,
                    scannerDeviceId: SettingsManager.shared.scannerDeviceId,
                    bssid: bssid,
                    ssid: ssid,
                    rssi: mappedRssi,
                    frequency: 5180,
                    securityType: isSecure ? "Secure (WPA/WEP)" : "Open",
                    isSecure: isSecure,
                    rfVector: [],
                    bleVector: BLEScanner.shared.currentBleVector,
                    position: measurementPosition,
                    latitude: self.lastLocation?.latitude ?? 0.0,
                    longitude: self.lastLocation?.longitude ?? 0.0,
                    uncertainty: 0.1
                )
                
                self.accessPoints[bssid] = sample
                self.appendHeatmapPoint(
                    bssid: bssid,
                    ssid: ssid,
                    rssi: mappedRssi,
                    position: measurementPosition
                )

                let previousBSSID = self.connectedBSSID
                if previousBSSID != bssid {
                    if !previousBSSID.isEmpty {
                        let roamPosition = self.latestDevicePose ?? SIMD3<Float>(0, 0, 0)
                        let roam = WiFiRoamEvent(
                            timestamp: Date().timeIntervalSince1970,
                            ssid: ssid,
                            fromBSSID: previousBSSID,
                            toBSSID: bssid,
                            position: roamPosition,
                            latitude: self.lastLocation?.latitude ?? 0.0,
                            longitude: self.lastLocation?.longitude ?? 0.0
                        )
                        self.roamEvents.append(roam)
                        if self.roamEvents.count > 120 {
                            self.roamEvents.removeFirst(self.roamEvents.count - 120)
                        }
                    }
                    self.connectedBSSID = bssid
                }

                if let pose = self.latestDevicePose {
                    let observation = APPositionObservation(
                        timestamp: Date().timeIntervalSince1970,
                        bssid: bssid,
                        frequencyMHz: sample.frequency,
                        rssi: sample.rssi,
                        scannerPosition: pose
                    )

                    if let resolved = self.apLocalizer.addObservation(observation) {
                        self.resolvedAPLocations[bssid] = resolved
                        self.apPositions[bssid] = resolved.position
                    }
                }
            }
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
            bleVector: BLEScanner.shared.currentBleVector,
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

    private func pruneBLESamples() {
        let bleKeys = accessPoints.compactMap { (key, sample) in
            sample.securityType == "BLE" ? key : nil
        }

        guard !bleKeys.isEmpty else { return }
        let bleKeySet = Set(bleKeys)

        for key in bleKeys {
            accessPoints.removeValue(forKey: key)
            apPositions.removeValue(forKey: key)
            resolvedAPLocations.removeValue(forKey: key)
            lastHeatmapSampleByBSSID.removeValue(forKey: key)
        }
        heatmapPoints.removeAll { bleKeySet.contains($0.bssid) }
    }
}
#endif
