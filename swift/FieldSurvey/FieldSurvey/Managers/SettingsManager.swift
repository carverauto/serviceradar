import Foundation
import Combine

/// Manages application-wide settings for the FieldSurvey app, persisting them to UserDefaults.
@MainActor
public class SettingsManager: ObservableObject {
    @MainActor public static let shared = SettingsManager()

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

    @Published public var sidekickURL: String {
        didSet {
            UserDefaults.standard.set(sidekickURL, forKey: "sidekickURL")
        }
    }

    @Published public var sidekickAuthToken: String {
        didSet {
            UserDefaults.standard.set(sidekickAuthToken, forKey: "sidekickAuthToken")
        }
    }

    @Published public var sidekickRadioConfig: String {
        didSet {
            UserDefaults.standard.set(sidekickRadioConfig, forKey: "sidekickRadioConfig")
        }
    }

    @Published public var sidekickUplinkInterface: String {
        didSet {
            UserDefaults.standard.set(sidekickUplinkInterface, forKey: "sidekickUplinkInterface")
        }
    }

    @Published public var sidekickUplinkSSID: String {
        didSet {
            UserDefaults.standard.set(sidekickUplinkSSID, forKey: "sidekickUplinkSSID")
        }
    }

    @Published public var sidekickUplinkCountryCode: String {
        didSet {
            UserDefaults.standard.set(sidekickUplinkCountryCode, forKey: "sidekickUplinkCountryCode")
        }
    }

    @Published public var sidekickSpectrumEnabled: Bool {
        didSet {
            UserDefaults.standard.set(sidekickSpectrumEnabled, forKey: "sidekickSpectrumEnabled")
        }
    }

    @Published public var sidekickSpectrumSDRID: String {
        didSet {
            UserDefaults.standard.set(sidekickSpectrumSDRID, forKey: "sidekickSpectrumSDRID")
        }
    }

    @Published public var sidekickSpectrumSerialNumber: String {
        didSet {
            UserDefaults.standard.set(sidekickSpectrumSerialNumber, forKey: "sidekickSpectrumSerialNumber")
        }
    }

    @Published public var sidekickSpectrumMinMHz: Int {
        didSet {
            UserDefaults.standard.set(sidekickSpectrumMinMHz, forKey: "sidekickSpectrumMinMHz")
        }
    }

    @Published public var sidekickSpectrumMaxMHz: Int {
        didSet {
            UserDefaults.standard.set(sidekickSpectrumMaxMHz, forKey: "sidekickSpectrumMaxMHz")
        }
    }

    @Published public var sidekickSpectrumBinWidthHz: Int {
        didSet {
            UserDefaults.standard.set(sidekickSpectrumBinWidthHz, forKey: "sidekickSpectrumBinWidthHz")
        }
    }

    @Published public var sidekickSpectrumLNAGainDB: Int {
        didSet {
            UserDefaults.standard.set(sidekickSpectrumLNAGainDB, forKey: "sidekickSpectrumLNAGainDB")
        }
    }

    @Published public var sidekickSpectrumVGAGainDB: Int {
        didSet {
            UserDefaults.standard.set(sidekickSpectrumVGAGainDB, forKey: "sidekickSpectrumVGAGainDB")
        }
    }

    @Published public var rfScanningEnabled: Bool {
        didSet {
            UserDefaults.standard.set(rfScanningEnabled, forKey: "rfScanningEnabled")
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
    
    private let scannerDeviceIdValue: String

    public var scannerDeviceId: String {
        if UserDefaults.standard.string(forKey: "scannerDeviceId") != scannerDeviceIdValue {
            UserDefaults.standard.set(scannerDeviceIdValue, forKey: "scannerDeviceId")
        }
        return scannerDeviceIdValue
    }
    
    private init() {
        self.rfScanningEnabled = UserDefaults.standard.object(forKey: "rfScanningEnabled") as? Bool ?? true
        self.showWiFiHeatmap = UserDefaults.standard.object(forKey: "showWiFiHeatmap") as? Bool ?? true
        self.arPriorityModeEnabled = UserDefaults.standard.object(forKey: "arPriorityModeEnabled") as? Bool ?? true
        
        self.apiURL = UserDefaults.standard.string(forKey: "apiURL") ?? "https://demo.serviceradar.cloud"
        self.authToken = UserDefaults.standard.string(forKey: "authToken") ?? ""
        let storedSidekickURL = UserDefaults.standard.string(forKey: "sidekickURL")
        self.sidekickURL = storedSidekickURL == "http://192.168.1.74:17321"
            ? "http://fieldsurvey-rpi.local:17321"
            : (storedSidekickURL ?? "http://fieldsurvey-rpi.local:17321")
        self.sidekickAuthToken = UserDefaults.standard.string(forKey: "sidekickAuthToken") ?? ""
        self.sidekickRadioConfig = UserDefaults.standard.string(forKey: "sidekickRadioConfig") ?? "auto"
        self.sidekickUplinkInterface = UserDefaults.standard.string(forKey: "sidekickUplinkInterface") ?? "wlan0"
        self.sidekickUplinkSSID = UserDefaults.standard.string(forKey: "sidekickUplinkSSID") ?? ""
        self.sidekickUplinkCountryCode = UserDefaults.standard.string(forKey: "sidekickUplinkCountryCode") ?? "US"
        self.sidekickSpectrumEnabled = UserDefaults.standard.object(forKey: "sidekickSpectrumEnabled") as? Bool ?? true
        self.sidekickSpectrumSDRID = UserDefaults.standard.string(forKey: "sidekickSpectrumSDRID") ?? "hackrf-0"
        self.sidekickSpectrumSerialNumber = UserDefaults.standard.string(forKey: "sidekickSpectrumSerialNumber") ?? "0000000000000000f77c60dc299165c3"
        self.sidekickSpectrumMinMHz = UserDefaults.standard.object(forKey: "sidekickSpectrumMinMHz") as? Int ?? 2400
        self.sidekickSpectrumMaxMHz = UserDefaults.standard.object(forKey: "sidekickSpectrumMaxMHz") as? Int ?? 2500
        self.sidekickSpectrumBinWidthHz = UserDefaults.standard.object(forKey: "sidekickSpectrumBinWidthHz") as? Int ?? 1_000_000
        self.sidekickSpectrumLNAGainDB = UserDefaults.standard.object(forKey: "sidekickSpectrumLNAGainDB") as? Int ?? 8
        self.sidekickSpectrumVGAGainDB = UserDefaults.standard.object(forKey: "sidekickSpectrumVGAGainDB") as? Int ?? 8
        
        // Persist a unique identifier for this specific device/scanner
        if let existingId = UserDefaults.standard.string(forKey: "scannerDeviceId") {
            self.scannerDeviceIdValue = existingId
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: "scannerDeviceId")
            self.scannerDeviceIdValue = newId
        }
    }

    public func setARPriorityLoadShedActive(_ active: Bool) {
        guard arPriorityLoadShedActive != active else { return }
        arPriorityLoadShedActive = active
    }
}
