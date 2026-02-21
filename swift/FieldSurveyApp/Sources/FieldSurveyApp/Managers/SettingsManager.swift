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
    
    private init() {
        // Default to high-resolution 1.0 second polling if not previously set
        let storedRate = UserDefaults.standard.double(forKey: "sampleRateSeconds")
        self.sampleRateSeconds = storedRate > 0 ? storedRate : 1.0
    }
}
