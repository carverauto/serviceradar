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

    @Published public var backendUsername: String {
        didSet {
            UserDefaults.standard.set(backendUsername, forKey: "backendUsername")
        }
    }

    @Published public var backendPassword: String {
        didSet {
            if backendPassword.isEmpty {
                KeychainStore.deleteString(for: Self.backendPasswordKeychainAccount)
            } else {
                KeychainStore.setString(backendPassword, for: Self.backendPasswordKeychainAccount)
            }
        }
    }

    @Published public var backendAuthenticatedAt: TimeInterval {
        didSet {
            UserDefaults.standard.set(backendAuthenticatedAt, forKey: "backendAuthenticatedAt")
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
    private static let offlineToken = "OFFLINE_MODE"
    private static let backendPasswordKeychainAccount = "serviceradar-backend-password"

    public var scannerDeviceId: String {
        if UserDefaults.standard.string(forKey: "scannerDeviceId") != scannerDeviceIdValue {
            UserDefaults.standard.set(scannerDeviceIdValue, forKey: "scannerDeviceId")
        }
        return scannerDeviceIdValue
    }

    public var backendUploadEnabled: Bool {
        let trimmedAPIURL = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedAPIURL.isEmpty && trimmedAPIURL != "offline" && !trimmedToken.isEmpty && trimmedToken != Self.offlineToken
    }

    public var isOfflineMode: Bool {
        authToken == Self.offlineToken
    }
    
    private init() {
        self.rfScanningEnabled = UserDefaults.standard.object(forKey: "rfScanningEnabled") as? Bool ?? true
        self.showWiFiHeatmap = UserDefaults.standard.object(forKey: "showWiFiHeatmap") as? Bool ?? true
        self.arPriorityModeEnabled = UserDefaults.standard.object(forKey: "arPriorityModeEnabled") as? Bool ?? true
        
        self.apiURL = UserDefaults.standard.string(forKey: "apiURL") ?? "https://demo.serviceradar.cloud"
        self.authToken = UserDefaults.standard.string(forKey: "authToken") ?? ""
        self.backendUsername = UserDefaults.standard.string(forKey: "backendUsername") ?? ""
        self.backendPassword = KeychainStore.string(for: Self.backendPasswordKeychainAccount)
        self.backendAuthenticatedAt = UserDefaults.standard.object(forKey: "backendAuthenticatedAt") as? TimeInterval ?? 0
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
        let storedSpectrumMin = UserDefaults.standard.object(forKey: "sidekickSpectrumMinMHz") as? Int
        let storedSpectrumMax = UserDefaults.standard.object(forKey: "sidekickSpectrumMaxMHz") as? Int
        let shouldMigrateWideSpectrumDefault =
            !UserDefaults.standard.bool(forKey: "sidekickSpectrumWideDefaultMigrated") &&
            (storedSpectrumMin == nil || storedSpectrumMin == 2400) &&
            (storedSpectrumMax == nil || storedSpectrumMax == 2500)
        let shouldMigrateFiveGHzSpectrumDefault =
            !UserDefaults.standard.bool(forKey: "sidekickSpectrumFiveGHzDefaultMigrated") &&
            (storedSpectrumMin == nil || storedSpectrumMin == 2400) &&
            (storedSpectrumMax == nil || storedSpectrumMax == 2500 || storedSpectrumMax == 5900)
        if shouldMigrateFiveGHzSpectrumDefault {
            self.sidekickSpectrumMinMHz = 5150
            self.sidekickSpectrumMaxMHz = 5900
            UserDefaults.standard.set(true, forKey: "sidekickSpectrumFiveGHzDefaultMigrated")
            UserDefaults.standard.set(true, forKey: "sidekickSpectrumWideDefaultMigrated")
            UserDefaults.standard.set(5150, forKey: "sidekickSpectrumMinMHz")
            UserDefaults.standard.set(5900, forKey: "sidekickSpectrumMaxMHz")
        } else if shouldMigrateWideSpectrumDefault {
            self.sidekickSpectrumMinMHz = 5150
            self.sidekickSpectrumMaxMHz = 5900
            UserDefaults.standard.set(true, forKey: "sidekickSpectrumWideDefaultMigrated")
            UserDefaults.standard.set(5150, forKey: "sidekickSpectrumMinMHz")
            UserDefaults.standard.set(5900, forKey: "sidekickSpectrumMaxMHz")
        } else {
            self.sidekickSpectrumMinMHz = storedSpectrumMin ?? 5150
            self.sidekickSpectrumMaxMHz = storedSpectrumMax ?? 5900
        }
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

    public func setAuthenticated(apiURL: String, token: String) {
        self.apiURL = apiURL
        self.authToken = token
        self.backendAuthenticatedAt = Date().timeIntervalSince1970
    }

    public func setAuthenticated(apiURL: String, token: String, username: String) {
        self.backendUsername = username
        setAuthenticated(apiURL: apiURL, token: token)
    }

    public func setOfflineMode() {
        if apiURL == "offline" || apiURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiURL = "https://demo.serviceradar.cloud"
        }
        authToken = Self.offlineToken
        backendAuthenticatedAt = 0
    }

    public func signOut() {
        authToken = ""
        backendAuthenticatedAt = 0
    }
}
