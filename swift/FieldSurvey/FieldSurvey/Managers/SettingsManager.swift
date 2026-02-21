import Foundation
import Combine

/// Manages application-wide settings for the FieldSurvey app, persisting them to UserDefaults.
public class SettingsManager: ObservableObject {
    public static let shared = SettingsManager()
    
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
    
    public let scannerDeviceId: String
    
    private init() {
        // Default to high-resolution 1.0 second polling if not previously set
        let storedRate = UserDefaults.standard.double(forKey: "sampleRateSeconds")
        self.sampleRateSeconds = storedRate > 0 ? storedRate : 1.0
        
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
}
