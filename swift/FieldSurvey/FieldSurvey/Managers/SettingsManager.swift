import Foundation
import Combine

/// Manages application-wide settings for the FieldSurvey app, persisting them to UserDefaults.
@MainActor
public class SettingsManager: ObservableObject {
    @MainActor public static let shared = SettingsManager()
    
    // The rate (in seconds) at which the Wi-Fi scanner polls for new networks/RSSI updates.
    // Lower interval = higher resolution data, but higher battery drain.
    @Published public var sampleRateSeconds: Double {
        didSet {
            UserDefaults.standard.set(sampleRateSeconds, forKey: "sampleRateSeconds")
        }
    }
    
    @Published public var apiURL: String {
        didSet {
            UserDefaults.standard.set(apiURL, forKey: "apiURL")
        }
    }
    
    @Published public var authToken: String {
        didSet {
            UserDefaults.standard.set(authToken, forKey: "authToken")
        }
    }
    
    @Published public var showBLEBeacons: Bool {
        didSet {
            UserDefaults.standard.set(showBLEBeacons, forKey: "showBLEBeacons")
        }
    }

    @Published public var rfScanningEnabled: Bool {
        didSet {
            UserDefaults.standard.set(rfScanningEnabled, forKey: "rfScanningEnabled")
        }
    }

    @Published public var aiObjectDetectionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(aiObjectDetectionEnabled, forKey: "aiObjectDetectionEnabled")
        }
    }

    @Published public var showWiFiHeatmap: Bool {
        didSet {
            UserDefaults.standard.set(showWiFiHeatmap, forKey: "showWiFiHeatmap")
        }
    }

    @Published public var arPriorityModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(arPriorityModeEnabled, forKey: "arPriorityModeEnabled")
        }
    }

    @Published public private(set) var arPriorityLoadShedActive: Bool = false
    
    public let scannerDeviceId: String
    
    private init() {
        // Default to high-resolution 1.0 second polling if not previously set
        let storedRate = UserDefaults.standard.double(forKey: "sampleRateSeconds")
        self.sampleRateSeconds = storedRate > 0 ? storedRate : 1.0
        
        self.showBLEBeacons = UserDefaults.standard.bool(forKey: "showBLEBeacons") // Defaults false
        self.rfScanningEnabled = UserDefaults.standard.object(forKey: "rfScanningEnabled") as? Bool ?? true
        self.aiObjectDetectionEnabled = UserDefaults.standard.object(forKey: "aiObjectDetectionEnabled") as? Bool ?? true
        self.showWiFiHeatmap = UserDefaults.standard.object(forKey: "showWiFiHeatmap") as? Bool ?? true
        self.arPriorityModeEnabled = UserDefaults.standard.object(forKey: "arPriorityModeEnabled") as? Bool ?? true
        
        self.apiURL = UserDefaults.standard.string(forKey: "apiURL") ?? "https://demo.serviceradar.cloud"
        self.authToken = UserDefaults.standard.string(forKey: "authToken") ?? ""
        
        // Persist a unique identifier for this specific device/scanner
        if let existingId = UserDefaults.standard.string(forKey: "scannerDeviceId") {
            self.scannerDeviceId = existingId
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: "scannerDeviceId")
            self.scannerDeviceId = newId
        }
    }

    public func setARPriorityLoadShedActive(_ active: Bool) {
        guard arPriorityLoadShedActive != active else { return }
        arPriorityLoadShedActive = active
    }
}
