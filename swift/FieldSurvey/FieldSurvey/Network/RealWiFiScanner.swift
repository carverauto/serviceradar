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
    
    private var locationManager: CLLocationManager
    private var lastLocation: CLLocationCoordinate2D?
    private var timer: Timer?
    
    public override init() {
        self.locationManager = CLLocationManager()
        super.init()
        self.locationManager.delegate = self
        self.locationManager.requestWhenInUseAuthorization()
    }
    
    public var isScanning: Bool {
        return timer != nil
    }
    
    public func startScanning() {
        // Start CoreLocation to trigger base station updates and ensure precise spatial anchors
        locationManager.startUpdatingLocation()
        
        // Setup Hotspot Helper to capture network interfaces (Requires Apple Entitlement for Enterprise Use)
        let options: [String: NSObject] = [kNEHotspotHelperOptionDisplayName: "ServiceRadar Scanner" as NSObject]
        let queue = DispatchQueue(label: "com.serviceradar.wifi", attributes: .concurrent)
        
        NEHotspotHelper.register(options: options, queue: queue) { (cmd: NEHotspotHelperCommand) in
            if cmd.commandType == .evaluate || cmd.commandType == .filterScanList {
                if let networkList = cmd.networkList {
                    // Extract data into sendable structs
                    struct NetData: Sendable {
                        let bssid: String
                        let ssid: String
                        let signalStrength: Double
                        let isSecure: Bool
                    }
                    
                    let nets = networkList.map { NetData(bssid: $0.bssid, ssid: $0.ssid, signalStrength: $0.signalStrength, isSecure: $0.isSecure) }
                    
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        var newAPs = self.accessPoints
                        
                        let sortedNetworks = nets.sorted { $0.bssid < $1.bssid }
                        let currentVector: [Double] = sortedNetworks.map { -100.0 + ($0.signalStrength * 70.0) }
                        
                        for network in nets {
                            let mappedRssi = -100.0 + (network.signalStrength * 70.0)
                            
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
                                position: SIMD3<Float>(0, 0, 0),
                                latitude: self.lastLocation?.latitude ?? 0.0,
                                longitude: self.lastLocation?.longitude ?? 0.0,
                                uncertainty: 0.1
                            )
                            newAPs[network.bssid] = sample
                        }
                        self.accessPoints = newAPs
                    }
                }
                
                let response = cmd.createResponse(.success)
                response.deliver()
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
    
    public func stopScanning() {
        timer?.invalidate()
        timer = nil
        locationManager.stopUpdatingLocation()
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
                uncertainty: existing.uncertainty
            )
            accessPoints[bssid] = updated
        }
    }
    
    private func fetchCurrentNetwork() {
        // Ingest BLE Beacons as RF sources to guarantee map activity regardless of Hotspot Entitlements
        let blePeripherals = BLEScanner.shared.discoveredPeripherals
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            for (uuid, rssi) in blePeripherals {
                let bssid = uuid.uuidString
                let sample = SurveySample(
                    id: UUID(),
                    timestamp: Date().timeIntervalSince1970,
                    scannerDeviceId: SettingsManager.shared.scannerDeviceId,
                    bssid: bssid,
                    ssid: "BLE Beacon",
                    rssi: rssi,
                    frequency: 2402, // Standard BLE Frequency
                    securityType: "BLE",
                    isSecure: false,
                    rfVector: [],
                    bleVector: BLEScanner.shared.currentBleVector,
                    position: SIMD3<Float>(0, 0, 0), // Transformed by AR Session
                    latitude: self.lastLocation?.latitude ?? 0.0,
                    longitude: self.lastLocation?.longitude ?? 0.0,
                    uncertainty: 0.1
                )
                // Only overwrite if it doesn't have an AR spatial anchor yet to prevent map jitter
                if self.accessPoints[bssid] == nil || self.apPositions[bssid] == nil {
                    self.accessPoints[bssid] = sample
                }
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
                    position: SIMD3<Float>(0, 0, 0), // Will be transformed by AR Session Anchors
                    latitude: self.lastLocation?.latitude ?? 0.0,
                    longitude: self.lastLocation?.longitude ?? 0.0,
                    uncertainty: 0.1
                )
                
                self.accessPoints[bssid] = sample
            }
        }
    }
    
    // MARK: - CLLocationManagerDelegate
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // GPS locations sync with RoomPlan/LiDAR coordinate normalization (WGS84 -> SceneKit space)
        lastLocation = locations.last?.coordinate
    }
}
#endif
