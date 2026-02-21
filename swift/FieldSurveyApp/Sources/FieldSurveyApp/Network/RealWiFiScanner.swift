import Foundation
import NetworkExtension
import CoreLocation
import simd

/// A real Wi-Fi scanner implementation integrating public APIs.
/// Uses `NEHotspotNetwork.fetchCurrent` combined with standard CoreLocation scanning for legitimate App Store/Enterprise apps.
/// Also provides the implementation for `NEHotspotHelper` which requires the `com.apple.developer.networking.HotspotHelper` entitlement to receive the full scan list.
public class RealWiFiScanner: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published public var accessPoints: [String: SurveySample] = [:]
    
    private var locationManager: CLLocationManager
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
        
        NEHotspotHelper.register(options: options, queue: queue) { [weak self] (cmd: NEHotspotHelperCommand) in
            guard let self = self else { return }
            
            if cmd.commandType == .evaluate || cmd.commandType == .filterScanList {
                if let networkList = cmd.networkList {
                    var newAPs = self.accessPoints
                    
                    // Build a sorted environmental vector representing the RF snapshot for pgvector KNN fingerprinting
                    let sortedNetworks = networkList.sorted { $0.bssid < $1.bssid }
                    let currentVector: [Double] = sortedNetworks.map { -100.0 + ($0.signalStrength * 70.0) }
                    
                    for network in networkList {
                        // In NEHotspotNetwork, signalStrength is a Double from 0.0 to 1.0. We map to standard RSSI scale
                        let mappedRssi = -100.0 + (network.signalStrength * 70.0)
                        
                        let sample = SurveySample(
                            id: UUID(),
                            timestamp: Date().timeIntervalSince1970,
                            scannerDeviceId: SettingsManager.shared.scannerDeviceId,
                            bssid: network.bssid,
                            ssid: network.ssid,
                            rssi: mappedRssi,
                            frequency: 5180, // Defaulting to 5GHz base assumption unless inferred by OUI
                            securityType: network.isSecure ? "Secure (WPA/WEP)" : "Open",
                            isSecure: network.isSecure,
                            rfVector: currentVector,
                            position: SIMD3<Float>(0, 0, 0), // Base relative spatial origin (updated by ARView)
                            uncertainty: 0.1
                        )
                        newAPs[network.bssid] = sample
                    }
                    
                    DispatchQueue.main.async {
                        self.accessPoints = newAPs
                    }
                }
                
                let response = cmd.createResponse(cmd.commandType)
                response.deliver()
            }
        }
        
        // Continuous poll for the currently connected network as a public API baseline
        let sampleRate = SettingsManager.shared.sampleRateSeconds
        timer = Timer.scheduledTimer(withTimeInterval: sampleRate, repeats: true) { [weak self] _ in
            self?.fetchCurrentNetwork()
        }
        fetchCurrentNetwork()
    }
    
    public func stopScanning() {
        timer?.invalidate()
        timer = nil
        locationManager.stopUpdatingLocation()
    }
    
    private func fetchCurrentNetwork() {
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            guard let self = self, let network = network else { return }
            
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
                position: SIMD3<Float>(0, 0, 0), // Will be transformed by AR Session Anchors
                uncertainty: 0.1
            )
            
            DispatchQueue.main.async {
                self.accessPoints[network.bssid] = sample
            }
        }
    }
    
    // MARK: - CLLocationManagerDelegate
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // GPS locations sync with RoomPlan/LiDAR coordinate normalization (WGS84 -> SceneKit space)
    }
}
