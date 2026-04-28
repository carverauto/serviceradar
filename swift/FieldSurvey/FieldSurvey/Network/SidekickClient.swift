import Foundation

public enum SidekickClientError: Error, Equatable, LocalizedError {
    case invalidResponse
    case httpStatus(Int, String)
    case invalidWebSocketMessage
    case invalidStreamURL
    case sidekickStreamError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Sidekick returned an invalid response."
        case let .httpStatus(statusCode, message):
            let detail = Self.serverErrorMessage(from: message)
            if detail.isEmpty {
                return "Sidekick request failed with HTTP \(statusCode)."
            }
            return "Sidekick request failed with HTTP \(statusCode): \(detail)"
        case .invalidWebSocketMessage:
            return "Sidekick sent an invalid stream message."
        case .invalidStreamURL:
            return "Sidekick stream URL is invalid. Use a URL like http://192.168.1.77:17321."
        case let .sidekickStreamError(message):
            return "Sidekick stream failed: \(message)"
        }
    }

    private static func serverErrorMessage(from payload: String) -> String {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? String
        else {
            return payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return error
    }
}

public struct SidekickHealthResponse: Codable, Equatable {
    public let ok: Bool
}

public struct SidekickStatusResponse: Codable, Equatable {
    public let service: String
    public let version: String
    public let captureRunning: Bool
    public let activeStreams: [SidekickActiveCaptureStream]
    public let iwAvailable: Bool
    public let radios: [SidekickRadioInterface]
    public let adaptiveScan: SidekickAdaptiveScanSnapshot?

    enum CodingKeys: String, CodingKey {
        case service
        case version
        case captureRunning = "capture_running"
        case activeStreams = "active_streams"
        case iwAvailable = "iw_available"
        case radios
        case adaptiveScan = "adaptive_scan"
    }
}

public struct SidekickAdaptiveScanSnapshot: Codable, Equatable, Sendable {
    public let channelCount: Int
    public let observedBSSIDCount: Int
    public let channels: [SidekickAdaptiveScanChannel]

    enum CodingKeys: String, CodingKey {
        case channelCount = "channel_count"
        case observedBSSIDCount = "observed_bssid_count"
        case channels
    }
}

public struct SidekickAdaptiveScanChannel: Codable, Equatable, Identifiable, Sendable {
    public var id: Int { frequencyMHz }

    public let frequencyMHz: Int
    public let band: String
    public let channel: Int?
    public let weight: Int
    public let observed: Bool?
    public let spectrumScore: Int?
    public let averagePowerDBM: Float?
    public let peakPowerDBM: Float?
    public let observedBSSIDCount: Int
    public let strongestRSSIDBM: Int?
    public let spectrumAgeSecs: UInt64?
    public let rfAgeSecs: UInt64?

    enum CodingKeys: String, CodingKey {
        case frequencyMHz = "frequency_mhz"
        case band
        case channel
        case weight
        case observed
        case spectrumScore = "spectrum_score"
        case averagePowerDBM = "average_power_dbm"
        case peakPowerDBM = "peak_power_dbm"
        case observedBSSIDCount = "observed_bssid_count"
        case strongestRSSIDBM = "strongest_rssi_dbm"
        case spectrumAgeSecs = "spectrum_age_secs"
        case rfAgeSecs = "rf_age_secs"
    }
}

public struct SidekickActiveCaptureStream: Codable, Equatable, Identifiable {
    public var id: String { streamID }

    public let streamID: String
    public let streamType: String
    public let target: String
    public let startedAtUnixSecs: UInt64

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case streamType = "stream_type"
        case target
        case startedAtUnixSecs = "started_at_unix_secs"
    }
}

public struct SidekickRadioInterface: Codable, Equatable, Identifiable {
    public var id: String { name }

    public let name: String
    public let phy: String?
    public let driver: String?
    public let macAddress: String?
    public let operstate: String?
    public let supportedModes: [String]
    public let supportedFrequenciesMHz: [Int]?
    public let monitorSupported: Bool?
    public let usb: SidekickUSBDeviceInfo?

    enum CodingKeys: String, CodingKey {
        case name
        case phy
        case driver
        case macAddress = "mac_address"
        case operstate
        case supportedModes = "supported_modes"
        case supportedFrequenciesMHz = "supported_frequencies_mhz"
        case monitorSupported = "monitor_supported"
        case usb
    }
}

public struct SidekickUSBDeviceInfo: Codable, Equatable {
    public let speedMbps: Int?
    public let version: String?
    public let manufacturer: String?
    public let product: String?
    public let vendorID: String?
    public let productID: String?
    public let busPath: String?

    enum CodingKeys: String, CodingKey {
        case speedMbps = "speed_mbps"
        case version
        case manufacturer
        case product
        case vendorID = "vendor_id"
        case productID = "product_id"
        case busPath = "bus_path"
    }
}

public struct SidekickRadioConfiguration: Equatable, Identifiable, Sendable {
    public var id: String { interfaceName }

    public let interfaceName: String
    public let frequenciesMHz: [Int]
    public let hopIntervalMS: Int
    public var frequencyMHz: Int? { frequenciesMHz.first }

    public init(
        interfaceName: String,
        frequencyMHz: Int? = nil,
        frequenciesMHz: [Int] = [],
        hopIntervalMS: Int = 250
    ) {
        self.interfaceName = interfaceName
        self.hopIntervalMS = hopIntervalMS
        if let frequencyMHz {
            self.frequenciesMHz = [frequencyMHz] + frequenciesMHz.filter { $0 != frequencyMHz }
        } else {
            self.frequenciesMHz = frequenciesMHz
        }
    }

    public static func parseList(_ rawValue: String) -> [SidekickRadioConfiguration] {
        rawValue
            .split(separator: ",")
            .compactMap { rawEntry in
                let parts = rawEntry
                    .split(separator: ":", maxSplits: 1)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard let interfaceName = parts.first, !interfaceName.isEmpty else { return nil }
                let frequenciesMHz = parts.count > 1 ? Self.parseFrequencies(parts[1]) : []
                return SidekickRadioConfiguration(interfaceName: interfaceName, frequenciesMHz: frequenciesMHz)
            }
    }

    private static func parseFrequencies(_ rawValue: String) -> [Int] {
        rawValue
            .split { character in
                character == "|" || character == ";" || character == " " || character == "\t"
            }
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .reduce(into: [Int]()) { result, frequency in
                if !result.contains(frequency) {
                    result.append(frequency)
                }
            }
    }
}

public struct SidekickMonitorPrepareRequest: Codable, Equatable {
    public let interfaceName: String
    public let frequencyMHz: Int?
    public let dryRun: Bool

    public init(interfaceName: String, frequencyMHz: Int? = nil, dryRun: Bool = true) {
        self.interfaceName = interfaceName
        self.frequencyMHz = frequencyMHz
        self.dryRun = dryRun
    }

    enum CodingKeys: String, CodingKey {
        case interfaceName = "interface_name"
        case frequencyMHz = "frequency_mhz"
        case dryRun = "dry_run"
    }
}

public struct SidekickMonitorPrepareResponse: Codable, Equatable {
    public let plan: SidekickMonitorPreparePlan
}

public struct SidekickMonitorPrepareExecutionResponse: Codable, Equatable {
    public let result: SidekickMonitorPrepareExecution
}

public struct SidekickMonitorPreparePlan: Codable, Equatable {
    public let interfaceName: String
    public let commands: [SidekickCommandSpec]

    enum CodingKeys: String, CodingKey {
        case interfaceName = "interface_name"
        case commands
    }
}

public struct SidekickCommandSpec: Codable, Equatable {
    public let program: String
    public let args: [String]
    public let requiresRoot: Bool?

    enum CodingKeys: String, CodingKey {
        case program
        case args
        case requiresRoot = "requires_root"
    }
}

public struct SidekickMonitorPrepareExecution: Codable, Equatable {
    public let dryRun: Bool
    public let plan: SidekickMonitorPreparePlan
    public let executions: [SidekickCommandExecution]

    enum CodingKeys: String, CodingKey {
        case dryRun = "dry_run"
        case plan
        case executions
    }
}

public struct SidekickRuntimeConfig: Codable, Equatable {
    public let sidekickID: String
    public let radioPlans: [SidekickRadioPlanConfig]
    public let wifiUplink: SidekickWifiUplinkConfig?

    enum CodingKeys: String, CodingKey {
        case sidekickID = "sidekick_id"
        case radioPlans = "radio_plans"
        case wifiUplink = "wifi_uplink"
    }
}

public struct SidekickRuntimeConfigUpdateRequest: Codable, Equatable {
    public let sidekickID: String?
    public let radioPlans: [SidekickRadioPlanConfig]?
    public let wifiUplink: SidekickWifiUplinkConfig?

    public init(
        sidekickID: String? = nil,
        radioPlans: [SidekickRadioPlanConfig]? = nil,
        wifiUplink: SidekickWifiUplinkConfig? = nil
    ) {
        self.sidekickID = sidekickID
        self.radioPlans = radioPlans
        self.wifiUplink = wifiUplink
    }

    enum CodingKeys: String, CodingKey {
        case sidekickID = "sidekick_id"
        case radioPlans = "radio_plans"
        case wifiUplink = "wifi_uplink"
    }
}

public struct SidekickRadioPlanConfig: Codable, Equatable {
    public let interfaceName: String
    public let frequenciesMHz: [Int]
    public let hopIntervalMS: Int

    public init(interfaceName: String, frequenciesMHz: [Int], hopIntervalMS: Int = 250) {
        self.interfaceName = interfaceName
        self.frequenciesMHz = frequenciesMHz
        self.hopIntervalMS = hopIntervalMS
    }

    enum CodingKeys: String, CodingKey {
        case interfaceName = "interface_name"
        case frequenciesMHz = "frequencies_mhz"
        case hopIntervalMS = "hop_interval_ms"
    }
}

public struct SidekickWifiUplinkConfig: Codable, Equatable {
    public let interfaceName: String
    public let ssid: String
    public let countryCode: String?
    public let pskConfigured: Bool

    public init(interfaceName: String, ssid: String, countryCode: String? = nil, pskConfigured: Bool = false) {
        self.interfaceName = interfaceName
        self.ssid = ssid
        self.countryCode = countryCode
        self.pskConfigured = pskConfigured
    }

    enum CodingKeys: String, CodingKey {
        case interfaceName = "interface_name"
        case ssid
        case countryCode = "country_code"
        case pskConfigured = "psk_configured"
    }
}

public struct SidekickWifiUplinkRequest: Codable, Equatable {
    public let interfaceName: String
    public let ssid: String
    public let psk: String?
    public let countryCode: String?
    public let dryRun: Bool

    public init(
        interfaceName: String,
        ssid: String,
        psk: String? = nil,
        countryCode: String? = nil,
        dryRun: Bool = true
    ) {
        self.interfaceName = interfaceName
        self.ssid = ssid
        self.psk = psk
        self.countryCode = countryCode
        self.dryRun = dryRun
    }

    enum CodingKeys: String, CodingKey {
        case interfaceName = "interface_name"
        case ssid
        case psk
        case countryCode = "country_code"
        case dryRun = "dry_run"
    }
}

public struct SidekickWifiUplinkPlanResponse: Codable, Equatable {
    public let plan: SidekickWifiUplinkPlan
}

public struct SidekickWifiUplinkExecutionResponse: Codable, Equatable {
    public let result: SidekickWifiUplinkExecution
}

public struct SidekickCaptureStopResponse: Codable, Equatable {
    public let stopped: Bool
    public let generation: UInt64
}

public struct SidekickPairingClaimRequest: Codable, Equatable {
    public let deviceID: String
    public let deviceName: String?

    public init(deviceID: String, deviceName: String? = nil) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceName = "device_name"
    }
}

public struct SidekickPairingClaimResponse: Codable, Equatable {
    public let sidekickID: String
    public let deviceID: String
    public let deviceName: String?
    public let token: String
    public let pairedAtUnixSecs: UInt64

    enum CodingKeys: String, CodingKey {
        case sidekickID = "sidekick_id"
        case deviceID = "device_id"
        case deviceName = "device_name"
        case token
        case pairedAtUnixSecs = "paired_at_unix_secs"
    }
}

public struct SidekickWifiUplinkPlan: Codable, Equatable {
    public let commands: [SidekickCommandSpec]
}

public struct SidekickWifiUplinkExecution: Codable, Equatable {
    public let plan: SidekickWifiUplinkPlan
    public let dryRun: Bool
    public let executions: [SidekickCommandExecution]
    public let savedConfig: SidekickWifiUplinkConfig?

    enum CodingKeys: String, CodingKey {
        case plan
        case dryRun = "dry_run"
        case executions
        case savedConfig = "saved_config"
    }
}

public struct SidekickCommandExecution: Codable, Equatable {
    public let command: SidekickCommandSpec
    public let statusCode: Int32?
    public let stdout: String
    public let stderr: String
    public let success: Bool

    enum CodingKeys: String, CodingKey {
        case command
        case statusCode = "status_code"
        case stdout
        case stderr
        case success
    }
}

public struct SidekickObservation: Codable, Equatable, Sendable {
    public let sidekickID: String
    public let radioID: String
    public let interfaceName: String
    public let bssid: String
    public let ssid: String?
    public let hiddenSSID: Bool
    public let frameType: String
    public let rssiDBM: Int?
    public let noiseFloorDBM: Int?
    public let snrDB: Int?
    public let frequencyMHz: Int
    public let channel: Int?
    public let channelWidthMHz: Int?
    public let capturedAtUnixNanos: Int64
    public let capturedAtMonotonicNanos: Int64?
    public let parserConfidence: Double

    enum CodingKeys: String, CodingKey {
        case sidekickID = "sidekick_id"
        case radioID = "radio_id"
        case interfaceName = "interface_name"
        case bssid
        case ssid
        case hiddenSSID = "hidden_ssid"
        case frameType = "frame_type"
        case rssiDBM = "rssi_dbm"
        case noiseFloorDBM = "noise_floor_dbm"
        case snrDB = "snr_db"
        case frequencyMHz = "frequency_mhz"
        case channel
        case channelWidthMHz = "channel_width_mhz"
        case capturedAtUnixNanos = "captured_at_unix_nanos"
        case capturedAtMonotonicNanos = "captured_at_monotonic_nanos"
        case parserConfidence = "parser_confidence"
    }
}

public struct SidekickObservationBatch: Equatable {
    public let interfaceName: String
    public let radioID: String
    public let payload: Data
}

public struct SidekickSpectrumBatch: Equatable {
    public let sdrID: String
    public let payload: Data
}

public enum SidekickSpectrumStreamMessage: Equatable {
    case batch(SidekickSpectrumBatch)
    case summary(SidekickSpectrumSummary)
}

public struct SidekickSpectrumSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(sdrID)-\(sweepID)" }

    public let sidekickID: String
    public let sdrID: String
    public let deviceKind: String
    public let serialNumber: String?
    public let sweepID: UInt64
    public let capturedAtUnixNanos: Int64
    public let startFrequencyHz: UInt64
    public let stopFrequencyHz: UInt64
    public let binWidthHz: Float
    public let sampleCount: UInt32
    public let averagePowerDBM: Float
    public let peakPowerDBM: Float
    public let peakFrequencyHz: UInt64
    public let sweepRateHz: Float?
    public let channelScores: [SidekickSpectrumChannelScore]

    public var peakFrequencyMHz: Double {
        Double(peakFrequencyHz) / 1_000_000.0
    }

    enum CodingKeys: String, CodingKey {
        case sidekickID = "sidekick_id"
        case sdrID = "sdr_id"
        case deviceKind = "device_kind"
        case serialNumber = "serial_number"
        case sweepID = "sweep_id"
        case capturedAtUnixNanos = "captured_at_unix_nanos"
        case startFrequencyHz = "start_frequency_hz"
        case stopFrequencyHz = "stop_frequency_hz"
        case binWidthHz = "bin_width_hz"
        case sampleCount = "sample_count"
        case averagePowerDBM = "average_power_dbm"
        case peakPowerDBM = "peak_power_dbm"
        case peakFrequencyHz = "peak_frequency_hz"
        case sweepRateHz = "sweep_rate_hz"
        case channelScores = "channel_scores"
    }
}

public struct SidekickSpectrumChannelScore: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(band)-\(channel)" }

    public let band: String
    public let channel: UInt16
    public let centerFrequencyMHz: UInt16
    public let averagePowerDBM: Float
    public let peakPowerDBM: Float
    public let interferenceScore: UInt8
    public let sampleCount: UInt32

    enum CodingKeys: String, CodingKey {
        case band
        case channel
        case centerFrequencyMHz = "center_frequency_mhz"
        case averagePowerDBM = "average_power_dbm"
        case peakPowerDBM = "peak_power_dbm"
        case interferenceScore = "interference_score"
        case sampleCount = "sample_count"
    }
}

private struct SidekickStreamControlMessage: Codable {
    let error: String?
    let event: String?
}

public final class SidekickClient: @unchecked Sendable {
    private let baseURL: URL
    private let apiToken: String
    private let session: URLSession
    private let jsonDecoder: JSONDecoder
    private let jsonEncoder: JSONEncoder

    public init(baseURL: URL, apiToken: String = "", session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiToken = apiToken
        self.session = session
        self.jsonDecoder = JSONDecoder()
        self.jsonEncoder = JSONEncoder()
    }

    @MainActor
    public convenience init(session: URLSession = .shared) {
        self.init(settings: .shared, session: session)
    }

    @MainActor
    public convenience init(settings: SettingsManager, session: URLSession = .shared) {
        let configuredURL = Self.normalizedBaseURL(from: settings.sidekickURL)
            ?? URL(string: "http://fieldsurvey-rpi.local:17321")!
        self.init(baseURL: configuredURL, apiToken: settings.sidekickAuthToken, session: session)
    }

    static func normalizedBaseURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()
        let hasExplicitWebScheme = lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("ws://")
            || lowercased.hasPrefix("wss://")
        let candidate = hasExplicitWebScheme ? trimmed : "http://\(trimmed)"

        guard var components = URLComponents(string: candidate) else { return nil }
        if components.scheme == "ws" {
            components.scheme = "http"
        } else if components.scheme == "wss" {
            components.scheme = "https"
        }
        guard components.host != nil else { return nil }
        return components.url
    }

    static func baseURLCandidates(from rawValue: String) -> [URL] {
        let rawCandidates = [
            rawValue,
            "http://172.20.10.2:17321",
            "http://172.20.10.3:17321",
            "http://172.20.10.4:17321",
            "http://172.20.10.5:17321",
            "http://172.20.10.6:17321"
        ]

        return rawCandidates.reduce(into: [URL]()) { result, rawCandidate in
            guard let url = normalizedBaseURL(from: rawCandidate),
                  !result.contains(url) else {
                return
            }
            result.append(url)
        }
    }

    public func health() async throws -> SidekickHealthResponse {
        try await send(path: "/healthz", method: "GET", body: Optional<Data>.none, authenticated: false)
    }

    public func status() async throws -> SidekickStatusResponse {
        try await send(path: "/status", method: "GET", body: Optional<Data>.none, authenticated: false)
    }

    public func monitorPlan(_ request: SidekickMonitorPrepareRequest) async throws -> SidekickMonitorPrepareResponse {
        let body = try jsonEncoder.encode(request)
        return try await send(path: "/radios/monitor-plan", method: "POST", body: body, authenticated: false)
    }

    public func prepareMonitor(_ request: SidekickMonitorPrepareRequest) async throws -> SidekickMonitorPrepareExecutionResponse {
        let body = try jsonEncoder.encode(request)
        return try await send(path: "/radios/prepare-monitor", method: "POST", body: body, authenticated: true)
    }

    public func runtimeConfig() async throws -> SidekickRuntimeConfig {
        try await send(path: "/config", method: "GET", body: Optional<Data>.none, authenticated: true)
    }

    public func updateRuntimeConfig(_ request: SidekickRuntimeConfigUpdateRequest) async throws -> SidekickRuntimeConfig {
        let body = try jsonEncoder.encode(request)
        return try await send(path: "/config", method: "PUT", body: body, authenticated: true)
    }

    public func wifiUplinkPlan(_ request: SidekickWifiUplinkRequest) async throws -> SidekickWifiUplinkPlanResponse {
        let body = try jsonEncoder.encode(request)
        return try await send(path: "/wifi/uplink-plan", method: "POST", body: body, authenticated: true)
    }

    public func configureWifiUplink(_ request: SidekickWifiUplinkRequest) async throws -> SidekickWifiUplinkExecutionResponse {
        let body = try jsonEncoder.encode(request)
        return try await send(path: "/wifi/configure-uplink", method: "POST", body: body, authenticated: true)
    }

    public func stopCapture() async throws -> SidekickCaptureStopResponse {
        try await send(path: "/capture/stop", method: "POST", body: Optional<Data>.none, authenticated: true)
    }

    public func claimPairing(_ request: SidekickPairingClaimRequest) async throws -> SidekickPairingClaimResponse {
        let body = try jsonEncoder.encode(request)
        return try await send(path: "/pairing/claim", method: "POST", body: body, authenticated: true)
    }

    public func observationBatches(
        interfaceName: String,
        sidekickID: String,
        radioID: String,
        frequenciesMHz: [Int] = [],
        hopIntervalMS: Int = 250,
        scanMode: String = "adaptive"
    ) -> AsyncThrowingStream<SidekickObservationBatch, Error> {
        AsyncThrowingStream { continuation in
            guard let url = streamURL(
                interfaceName: interfaceName,
                sidekickID: sidekickID,
                radioID: radioID,
                frequenciesMHz: frequenciesMHz,
                hopIntervalMS: hopIntervalMS,
                scanMode: scanMode
            ) else {
                continuation.finish(throwing: SidekickClientError.invalidStreamURL)
                return
            }

            var request = URLRequest(url: url)
            if !apiToken.isEmpty {
                request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
            }

            let task = session.webSocketTask(with: request)
            task.resume()

            receiveNextObservationBatch(
                task: task,
                interfaceName: interfaceName,
                radioID: radioID,
                continuation: continuation
            )

            continuation.onTermination = { _ in
                task.cancel(with: .normalClosure, reason: nil)
            }
        }
    }

    public func spectrumBatches(
        sidekickID: String,
        sdrID: String,
        serialNumber: String? = nil,
        frequencyMinMHz: Int = 5150,
        frequencyMaxMHz: Int = 5900,
        binWidthHz: Int = 1_000_000,
        lnaGainDB: Int = 8,
        vgaGainDB: Int = 8
    ) -> AsyncThrowingStream<SidekickSpectrumBatch, Error> {
        AsyncThrowingStream { continuation in
            guard let url = spectrumStreamURL(
                sidekickID: sidekickID,
                sdrID: sdrID,
                serialNumber: serialNumber,
                frequencyMinMHz: frequencyMinMHz,
                frequencyMaxMHz: frequencyMaxMHz,
                binWidthHz: binWidthHz,
                lnaGainDB: lnaGainDB,
                vgaGainDB: vgaGainDB
            ) else {
                continuation.finish(throwing: SidekickClientError.invalidStreamURL)
                return
            }

            var request = URLRequest(url: url)
            if !apiToken.isEmpty {
                request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
            }

            let task = session.webSocketTask(with: request)
            task.resume()

            receiveNextSpectrumBatch(task: task, sdrID: sdrID, continuation: continuation)

            continuation.onTermination = { _ in
                task.cancel(with: .normalClosure, reason: nil)
            }
        }
    }

    public func spectrumMessages(
        sidekickID: String,
        sdrID: String,
        serialNumber: String? = nil,
        frequencyMinMHz: Int = 5150,
        frequencyMaxMHz: Int = 5900,
        binWidthHz: Int = 1_000_000,
        lnaGainDB: Int = 8,
        vgaGainDB: Int = 8
    ) -> AsyncThrowingStream<SidekickSpectrumStreamMessage, Error> {
        AsyncThrowingStream { continuation in
            guard let url = spectrumStreamURL(
                sidekickID: sidekickID,
                sdrID: sdrID,
                serialNumber: serialNumber,
                frequencyMinMHz: frequencyMinMHz,
                frequencyMaxMHz: frequencyMaxMHz,
                binWidthHz: binWidthHz,
                lnaGainDB: lnaGainDB,
                vgaGainDB: vgaGainDB
            ) else {
                continuation.finish(throwing: SidekickClientError.invalidStreamURL)
                return
            }

            var request = URLRequest(url: url)
            if !apiToken.isEmpty {
                request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
            }

            let task = session.webSocketTask(with: request)
            task.resume()

            receiveNextSpectrumMessage(task: task, sdrID: sdrID, continuation: continuation)

            continuation.onTermination = { _ in
                task.cancel(with: .normalClosure, reason: nil)
            }
        }
    }

    public func spectrumSummaries(
        sidekickID: String,
        sdrID: String,
        serialNumber: String? = nil,
        frequencyMinMHz: Int = 5150,
        frequencyMaxMHz: Int = 5900,
        binWidthHz: Int = 1_000_000,
        lnaGainDB: Int = 8,
        vgaGainDB: Int = 8
    ) -> AsyncThrowingStream<SidekickSpectrumSummary, Error> {
        AsyncThrowingStream { continuation in
            guard let url = spectrumStreamURL(
                path: "/spectrum/summary-stream",
                sidekickID: sidekickID,
                sdrID: sdrID,
                serialNumber: serialNumber,
                frequencyMinMHz: frequencyMinMHz,
                frequencyMaxMHz: frequencyMaxMHz,
                binWidthHz: binWidthHz,
                lnaGainDB: lnaGainDB,
                vgaGainDB: vgaGainDB
            ) else {
                continuation.finish(throwing: SidekickClientError.invalidStreamURL)
                return
            }

            var request = URLRequest(url: url)
            if !apiToken.isEmpty {
                request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
            }

            let task = session.webSocketTask(with: request)
            task.resume()

            receiveNextSpectrumSummary(task: task, continuation: continuation)

            continuation.onTermination = { _ in
                task.cancel(with: .normalClosure, reason: nil)
            }
        }
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        body: Data?,
        authenticated: Bool
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if authenticated, !apiToken.isEmpty {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SidekickClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw SidekickClientError.httpStatus(httpResponse.statusCode, message)
        }

        return try jsonDecoder.decode(Response.self, from: data)
    }

    private func streamURL(
        interfaceName: String,
        sidekickID: String,
        radioID: String,
        frequenciesMHz: [Int],
        hopIntervalMS: Int,
        scanMode: String
    ) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let originalScheme = components?.scheme
        components?.scheme = streamScheme(for: originalScheme)
        components?.path = "/observations/stream"
        var queryItems = [
            URLQueryItem(name: "interface_name", value: interfaceName),
            URLQueryItem(name: "sidekick_id", value: sidekickID),
            URLQueryItem(name: "radio_id", value: radioID)
        ]

        if frequenciesMHz.count > 1 {
            queryItems.append(URLQueryItem(
                name: "frequencies_mhz",
                value: frequenciesMHz.map(String.init).joined(separator: ",")
            ))
            queryItems.append(URLQueryItem(name: "hop_interval_ms", value: String(hopIntervalMS)))
        }

        if !scanMode.isEmpty {
            queryItems.append(URLQueryItem(name: "scan_mode", value: scanMode))
        }

        components?.queryItems = queryItems
        return components?.url
    }

    private func spectrumStreamURL(
        path: String = "/spectrum/stream",
        sidekickID: String,
        sdrID: String,
        serialNumber: String?,
        frequencyMinMHz: Int,
        frequencyMaxMHz: Int,
        binWidthHz: Int,
        lnaGainDB: Int,
        vgaGainDB: Int
    ) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let originalScheme = components?.scheme
        components?.scheme = streamScheme(for: originalScheme)
        components?.path = path

        var queryItems = [
            URLQueryItem(name: "sidekick_id", value: sidekickID),
            URLQueryItem(name: "sdr_id", value: sdrID),
            URLQueryItem(name: "frequency_min_mhz", value: String(frequencyMinMHz)),
            URLQueryItem(name: "frequency_max_mhz", value: String(frequencyMaxMHz)),
            URLQueryItem(name: "bin_width_hz", value: String(binWidthHz)),
            URLQueryItem(name: "lna_gain_db", value: String(lnaGainDB)),
            URLQueryItem(name: "vga_gain_db", value: String(vgaGainDB))
        ]

        if let serialNumber, !serialNumber.isEmpty {
            queryItems.append(URLQueryItem(name: "serial_number", value: serialNumber))
        }

        components?.queryItems = queryItems
        return components?.url
    }

    private func streamScheme(for scheme: String?) -> String {
        switch scheme?.lowercased() {
        case "https", "wss":
            return "wss"
        default:
            return "ws"
        }
    }

    private func receiveNextObservationBatch(
        task: URLSessionWebSocketTask,
        interfaceName: String,
        radioID: String,
        continuation: AsyncThrowingStream<SidekickObservationBatch, Error>.Continuation
    ) {
        task.receive { [weak self] result in
            guard let self else { return }
            do {
                let message = try result.get()
                switch message {
                case .data(let messageData):
                    continuation.yield(SidekickObservationBatch(
                        interfaceName: interfaceName,
                        radioID: radioID,
                        payload: messageData
                    ))
                case .string(let text):
                    if try handleStreamControlText(text, continuation: continuation) {
                        return
                    }
                    throw SidekickClientError.sidekickStreamError(text)
                @unknown default:
                    throw SidekickClientError.invalidWebSocketMessage
                }

                self.receiveNextObservationBatch(
                    task: task,
                    interfaceName: interfaceName,
                    radioID: radioID,
                    continuation: continuation
                )
            } catch {
                finishStream(continuation, error: error)
            }
        }
    }

    private func receiveNextSpectrumBatch(
        task: URLSessionWebSocketTask,
        sdrID: String,
        continuation: AsyncThrowingStream<SidekickSpectrumBatch, Error>.Continuation
    ) {
        task.receive { [weak self] result in
            guard let self else { return }
            do {
                let message = try result.get()
                switch message {
                case .data(let messageData):
                    continuation.yield(SidekickSpectrumBatch(sdrID: sdrID, payload: messageData))
                case .string(let text):
                    if try handleStreamControlText(text, continuation: continuation) {
                        return
                    }
                    if (try? self.jsonDecoder.decode(SidekickSpectrumSummary.self, from: Data(text.utf8))) != nil {
                        break
                    }
                    throw SidekickClientError.sidekickStreamError(text)
                @unknown default:
                    throw SidekickClientError.invalidWebSocketMessage
                }

                self.receiveNextSpectrumBatch(task: task, sdrID: sdrID, continuation: continuation)
            } catch {
                finishStream(continuation, error: error)
            }
        }
    }

    private func receiveNextSpectrumMessage(
        task: URLSessionWebSocketTask,
        sdrID: String,
        continuation: AsyncThrowingStream<SidekickSpectrumStreamMessage, Error>.Continuation
    ) {
        task.receive { [weak self] result in
            guard let self else { return }
            do {
                let message = try result.get()
                switch message {
                case .data(let messageData):
                    continuation.yield(.batch(SidekickSpectrumBatch(sdrID: sdrID, payload: messageData)))
                case .string(let text):
                    let messageData = Data(text.utf8)
                    if try handleStreamControlText(text, continuation: continuation) {
                        return
                    }
                    let summary = try self.jsonDecoder.decode(SidekickSpectrumSummary.self, from: messageData)
                    continuation.yield(.summary(summary))
                @unknown default:
                    throw SidekickClientError.invalidWebSocketMessage
                }

                self.receiveNextSpectrumMessage(task: task, sdrID: sdrID, continuation: continuation)
            } catch {
                finishStream(continuation, error: error)
            }
        }
    }

    private func receiveNextSpectrumSummary(
        task: URLSessionWebSocketTask,
        continuation: AsyncThrowingStream<SidekickSpectrumSummary, Error>.Continuation
    ) {
        task.receive { [weak self] result in
            guard let self else { return }
            do {
                let message = try result.get()
                let messageData: Data

                switch message {
                case .data(let data):
                    messageData = data
                case .string(let text):
                    messageData = Data(text.utf8)
                @unknown default:
                    throw SidekickClientError.invalidWebSocketMessage
                }

                if let control = try? self.jsonDecoder.decode(SidekickStreamControlMessage.self, from: messageData) {
                    if let error = control.error {
                        throw SidekickClientError.sidekickStreamError(error)
                    }
                    if control.event == "capture_stopped" {
                        continuation.finish()
                        return
                    }
                }

                let summary = try self.jsonDecoder.decode(SidekickSpectrumSummary.self, from: messageData)
                continuation.yield(summary)
                self.receiveNextSpectrumSummary(task: task, continuation: continuation)
            } catch {
                finishStream(continuation, error: error)
            }
        }
    }

    private func handleStreamControlText<Element>(
        _ text: String,
        continuation: AsyncThrowingStream<Element, Error>.Continuation
    ) throws -> Bool {
        let messageData = Data(text.utf8)
        guard let control = try? jsonDecoder.decode(SidekickStreamControlMessage.self, from: messageData) else {
            return false
        }

        if let error = control.error {
            throw SidekickClientError.sidekickStreamError(error)
        }

        if control.event == "capture_stopped" {
            continuation.finish()
            return true
        }

        return false
    }

    private func finishStream<Element>(
        _ continuation: AsyncThrowingStream<Element, Error>.Continuation,
        error: Error
    ) {
        if isCancellation(error) {
            continuation.finish()
        } else {
            continuation.finish(throwing: error)
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
