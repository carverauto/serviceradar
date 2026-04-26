import Foundation
import Combine
import os.log

public enum SidekickRelayStatus: Equatable {
    case idle
    case connecting
    case streaming(radios: Int, spectrum: Bool)
    case failed(String)
}

public enum FieldSurveyBackendStream: String {
    case rfObservations = "rf-observations"
    case poseSamples = "pose-samples"
    case spectrumObservations = "spectrum-observations"
}

public final class FieldSurveyBackendArrowSink: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let logger: Logger

    public init?(
        baseURL: String,
        authToken: String,
        sessionID: String,
        stream: FieldSurveyBackendStream,
        urlSession: URLSession = .shared
    ) {
        let trimmedBaseURL = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "http://", with: "ws://")
            .replacingOccurrences(of: "https://", with: "wss://")

        guard let url = URL(string: "\(trimmedBaseURL)/v1/field-survey/\(sessionID)/\(stream.rawValue)") else {
            return nil
        }

        var request = URLRequest(url: url)
        if !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        self.task = urlSession.webSocketTask(with: request)
        self.logger = Logger(subsystem: "com.serviceradar.fieldsurvey", category: "FieldSurveyBackendArrowSink")
        self.task.resume()
    }

    public func send(_ payload: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(.data(payload)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
        logger.debug("Closed FieldSurvey backend Arrow sink")
    }
}

@MainActor
public final class SidekickRelay: ObservableObject {
    private static let twoGHzSurveyFrequenciesMHz = [
        2412, 2417, 2422, 2427, 2432, 2437, 2442, 2447, 2452, 2457, 2462
    ]
    private static let fiveGHzSurveyFrequenciesMHz = [
        5180, 5200, 5220, 5240,
        5260, 5280, 5300, 5320,
        5500, 5520, 5540, 5560, 5580, 5600, 5620, 5640, 5660, 5680, 5700,
        5745, 5765, 5785, 5805, 5825
    ]

    @Published public private(set) var status: SidekickRelayStatus = .idle
    @Published public private(set) var rfBatchCount: Int = 0
    @Published public private(set) var spectrumBatchCount: Int = 0
    @Published public private(set) var latestSpectrumSummary: SidekickSpectrumSummary?
    @Published public private(set) var spectrumSummaries: [SidekickSpectrumSummary] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var spectrumWarning: String?

    private let logger = Logger(subsystem: "com.serviceradar.fieldsurvey", category: "SidekickRelay")
    private let observationDecoder = SidekickObservationArrowDecoder()
    private var tasks: [Task<Void, Never>] = []
    private var sinks: [FieldSurveyBackendArrowSink] = []
    private var pendingRFBatchCount = 0
    private var pendingSpectrumBatchCount = 0
    private var lastRFCountPublishTime: TimeInterval = 0
    private var lastSpectrumCountPublishTime: TimeInterval = 0
    private var lastPreviewIngestTime: TimeInterval = 0
    private var latestSpectrumScoresByChannel: [String: SidekickSpectrumChannelScore] = [:]

    public init() {}

    public func start(
        sessionID: String,
        wifiScanner: RealWiFiScanner? = nil,
        forwardToBackend: Bool = true
    ) {
        stop()
        status = .connecting
        rfBatchCount = 0
        spectrumBatchCount = 0
        latestSpectrumSummary = nil
        spectrumSummaries = []
        latestSpectrumScoresByChannel = [:]
        pendingRFBatchCount = 0
        pendingSpectrumBatchCount = 0
        lastRFCountPublishTime = 0
        lastSpectrumCountPublishTime = 0
        lastPreviewIngestTime = 0
        lastError = nil
        spectrumWarning = nil

        let settings = SettingsManager.shared
        let sidekickBaseURLs = SidekickClient.baseURLCandidates(from: settings.sidekickURL)
        let sidekickAuthToken = settings.sidekickAuthToken
        let sidekickID = "fieldsurvey-sidekick"

        let rfSink: FieldSurveyBackendArrowSink?
        if forwardToBackend {
            guard let sink = FieldSurveyBackendArrowSink(
                baseURL: settings.apiURL,
                authToken: settings.authToken,
                sessionID: sessionID,
                stream: .rfObservations
            ) else {
                status = .failed("Invalid ServiceRadar RF ingest URL")
                return
            }
            rfSink = sink
            sinks.append(sink)
        } else {
            rfSink = nil
        }

        let bootstrapTask = Task { [weak self, rfSink] in
            do {
                let (sidekickClient, statusResponse) = try await Self.firstReachableSidekick(
                    baseURLs: sidekickBaseURLs,
                    apiToken: sidekickAuthToken
                )
                let radioConfigs = Self.radioConfigurations(
                    from: settings.sidekickRadioConfig,
                    status: statusResponse,
                    uplinkInterfaceName: settings.sidekickUplinkInterface
                )

                await MainActor.run {
                    self?.status = .streaming(
                        radios: radioConfigs.count,
                        spectrum: settings.sidekickSpectrumEnabled
                    )
                }

                for radioConfig in radioConfigs {
                    self?.startRadioRelay(
                        sidekickClient: sidekickClient,
                        backendSink: rfSink,
                        wifiScanner: wifiScanner,
                        sidekickID: sidekickID,
                        radioConfig: radioConfig
                    )
                }

                if settings.sidekickSpectrumEnabled {
                    self?.startSpectrumRelay(
                        sidekickClient: sidekickClient,
                        sessionID: sessionID,
                        sidekickID: sidekickID,
                        forwardToBackend: forwardToBackend
                    )
                }
            } catch {
                await MainActor.run {
                    self?.lastError = "Sidekick setup: \(error.localizedDescription)"
                    self?.status = .failed(self?.lastError ?? error.localizedDescription)
                }
            }
        }

        tasks.append(bootstrapTask)
    }

    nonisolated private static func firstReachableSidekick(
        baseURLs: [URL],
        apiToken: String
    ) async throws -> (SidekickClient, SidekickStatusResponse) {
        var lastError: Error?

        for baseURL in baseURLs {
            let client = SidekickClient(baseURL: baseURL, apiToken: apiToken)
            do {
                let status = try await client.status()
                return (client, status)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SidekickClientError.invalidStreamURL
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        sinks.forEach { $0.close() }
        sinks.removeAll()
        status = .idle
        lastError = nil
        spectrumWarning = nil
    }

    private func startRadioRelay(
        sidekickClient: SidekickClient,
        backendSink: FieldSurveyBackendArrowSink?,
        wifiScanner: RealWiFiScanner?,
        sidekickID: String,
        radioConfig: SidekickRadioConfiguration
    ) {
        let task = Task { [weak self, sidekickClient, backendSink, weak wifiScanner] in
            var attempt = 0

            while !Task.isCancelled {
                do {
                    if let frequencyMHz = radioConfig.frequencyMHz {
                        _ = try await sidekickClient.prepareMonitor(
                            SidekickMonitorPrepareRequest(
                                interfaceName: radioConfig.interfaceName,
                                frequencyMHz: frequencyMHz,
                                dryRun: false
                            )
                        )
                    }

                    let stream = sidekickClient.observationBatches(
                        interfaceName: radioConfig.interfaceName,
                        sidekickID: sidekickID,
                        radioID: radioConfig.interfaceName,
                        frequenciesMHz: radioConfig.frequenciesMHz,
                        hopIntervalMS: radioConfig.hopIntervalMS
                    )

                    for try await batch in stream {
                        try Task.checkCancellation()
                        if let backendSink {
                            try await backendSink.send(batch.payload)
                        }
                        self?.ingestPreviewBatch(batch.payload, wifiScanner: wifiScanner)
                        attempt = 0
                        await MainActor.run {
                            self?.lastError = nil
                            self?.spectrumWarning = nil
                            self?.recordRFBatch()
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    attempt += 1
                    await MainActor.run {
                        if attempt >= 3 {
                            self?.lastError = nil
                            self?.spectrumWarning = "RF \(radioConfig.interfaceName) reconnecting: \(error.localizedDescription)"
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: Self.retryDelayNanos(for: attempt))
            }
        }

        tasks.append(task)
    }

    private func ingestPreviewBatch(_ payload: Data, wifiScanner: RealWiFiScanner?) {
        guard let wifiScanner else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastPreviewIngestTime >= 0.35 else { return }
        lastPreviewIngestTime = now

        do {
            let observations = try observationDecoder.decode(payload)
            guard !observations.isEmpty else { return }
            wifiScanner.ingestSidekickObservations(observations)
        } catch {
            logger.debug("Skipped Sidekick preview decode: \(error.localizedDescription)")
        }
    }

    private func startSpectrumRelay(
        sidekickClient: SidekickClient,
        sessionID: String,
        sidekickID: String,
        forwardToBackend: Bool
    ) {
        let settings = SettingsManager.shared

        let spectrumSink: FieldSurveyBackendArrowSink?
        if forwardToBackend {
            guard let sink = FieldSurveyBackendArrowSink(
                baseURL: settings.apiURL,
                authToken: settings.authToken,
                sessionID: sessionID,
                stream: .spectrumObservations
            ) else {
                status = .failed("Invalid ServiceRadar spectrum ingest URL")
                return
            }
            spectrumSink = sink
            sinks.append(sink)
        } else {
            spectrumSink = nil
        }

        let task = Task { [weak self, sidekickClient, spectrumSink] in
            var attempt = 0

            while !Task.isCancelled {
                do {
                    if let spectrumSink {
                        let stream = sidekickClient.spectrumBatches(
                            sidekickID: sidekickID,
                            sdrID: settings.sidekickSpectrumSDRID,
                            serialNumber: settings.sidekickSpectrumSerialNumber.nilIfBlank,
                            frequencyMinMHz: settings.sidekickSpectrumMinMHz,
                            frequencyMaxMHz: settings.sidekickSpectrumMaxMHz,
                            binWidthHz: settings.sidekickSpectrumBinWidthHz,
                            lnaGainDB: settings.sidekickSpectrumLNAGainDB,
                            vgaGainDB: settings.sidekickSpectrumVGAGainDB
                        )

                        for try await batch in stream {
                            try Task.checkCancellation()
                            try await spectrumSink.send(batch.payload)
                            attempt = 0
                            await MainActor.run {
                                self?.spectrumWarning = nil
                                self?.recordSpectrumBatch()
                            }
                        }
                    } else {
                        let stream = sidekickClient.spectrumSummaries(
                            sidekickID: sidekickID,
                            sdrID: settings.sidekickSpectrumSDRID,
                            serialNumber: settings.sidekickSpectrumSerialNumber.nilIfBlank,
                            frequencyMinMHz: settings.sidekickSpectrumMinMHz,
                            frequencyMaxMHz: settings.sidekickSpectrumMaxMHz,
                            binWidthHz: settings.sidekickSpectrumBinWidthHz,
                            lnaGainDB: settings.sidekickSpectrumLNAGainDB,
                            vgaGainDB: settings.sidekickSpectrumVGAGainDB
                        )

                        for try await summary in stream {
                            try Task.checkCancellation()
                            attempt = 0
                            await MainActor.run {
                                self?.spectrumWarning = nil
                                self?.recordSpectrumSummary(summary)
                            }
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    attempt += 1
                    await MainActor.run {
                        if attempt >= 3 {
                            self?.spectrumWarning = "Spectrum reconnecting: \(error.localizedDescription)"
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: Self.retryDelayNanos(for: attempt))
            }
        }

        tasks.append(task)
    }

    private static func radioConfigurations(
        from rawValue: String,
        status: SidekickStatusResponse,
        uplinkInterfaceName: String
    ) -> [SidekickRadioConfiguration] {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed.lowercased() != "auto" {
            return SidekickRadioConfiguration.parseList(trimmed)
        }

        let uplinkInterface = uplinkInterfaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let surveyRadios = status.radios
            .filter { radio in
                radio.usb != nil &&
                    radio.monitorSupported != false &&
                    radio.name != uplinkInterface
            }
            .sorted { lhs, rhs in
                (lhs.usb?.speedMbps ?? 0) > (rhs.usb?.speedMbps ?? 0)
            }

        return surveyRadios
            .enumerated()
            .map { index, radio in
                SidekickRadioConfiguration(
                    interfaceName: radio.name,
                    frequenciesMHz: Self.autoFrequenciesMHz(forRadioAt: index, radioCount: surveyRadios.count),
                    hopIntervalMS: Self.autoHopIntervalMS(for: radio)
                )
            }
    }

    private func recordRFBatch() {
        pendingRFBatchCount += 1
        let now = Date().timeIntervalSince1970
        if now - lastRFCountPublishTime >= 0.5 {
            rfBatchCount = pendingRFBatchCount
            lastRFCountPublishTime = now
        }
    }

    private func recordSpectrumBatch() {
        pendingSpectrumBatchCount += 1
        let now = Date().timeIntervalSince1970
        if now - lastSpectrumCountPublishTime >= 0.5 {
            spectrumBatchCount = pendingSpectrumBatchCount
            lastSpectrumCountPublishTime = now
        }
    }

    private func recordSpectrumSummary(_ summary: SidekickSpectrumSummary) {
        for score in summary.channelScores {
            latestSpectrumScoresByChannel[score.id] = score
        }

        latestSpectrumSummary = SidekickSpectrumSummary(
            sidekickID: summary.sidekickID,
            sdrID: summary.sdrID,
            deviceKind: summary.deviceKind,
            serialNumber: summary.serialNumber,
            sweepID: summary.sweepID,
            capturedAtUnixNanos: summary.capturedAtUnixNanos,
            startFrequencyHz: summary.startFrequencyHz,
            stopFrequencyHz: summary.stopFrequencyHz,
            binWidthHz: summary.binWidthHz,
            sampleCount: summary.sampleCount,
            averagePowerDBM: summary.averagePowerDBM,
            peakPowerDBM: summary.peakPowerDBM,
            peakFrequencyHz: summary.peakFrequencyHz,
            sweepRateHz: summary.sweepRateHz,
            channelScores: mergedSpectrumScores()
        )
        spectrumSummaries.append(summary)
        if spectrumSummaries.count > 900 {
            spectrumSummaries.removeFirst(spectrumSummaries.count - 900)
        }
        recordSpectrumBatch()
    }

    private func mergedSpectrumScores() -> [SidekickSpectrumChannelScore] {
        latestSpectrumScoresByChannel.values.sorted { lhs, rhs in
            if lhs.band == rhs.band {
                return lhs.channel < rhs.channel
            }
            return lhs.band < rhs.band
        }
    }

    private static func retryDelayNanos(for attempt: Int) -> UInt64 {
        let seconds = min(max(attempt, 1), 5)
        return UInt64(seconds) * 1_000_000_000
    }

    private static func autoFrequenciesMHz(forRadioAt index: Int, radioCount: Int) -> [Int] {
        if radioCount <= 1 {
            return twoGHzSurveyFrequenciesMHz + fiveGHzSurveyFrequenciesMHz
        }

        return index == 0 ? fiveGHzSurveyFrequenciesMHz : twoGHzSurveyFrequenciesMHz
    }

    private static func autoHopIntervalMS(for radio: SidekickRadioInterface) -> Int {
        if radio.driver?.lowercased().contains("mt76") == true {
            return 1_000
        }
        return 250
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
