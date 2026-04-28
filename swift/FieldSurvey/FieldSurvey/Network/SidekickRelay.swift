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

private actor FieldSurveyBackendSendQueue {
    func ping(task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func send(_ payload: Data, task: URLSessionWebSocketTask) async throws {
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
}

private final class FieldSurveyBackendWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var failedError: Error?
    private var continuations: [CheckedContinuation<Void, Error>] = []

    func waitForOpen(timeoutSeconds: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw URLError(.cancelled) }
                try await self.waitForOpen()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeoutSeconds, 1) * 1_000_000_000))
                throw URLError(.timedOut)
            }

            guard let result = try await group.next() else {
                throw URLError(.cannotConnectToHost)
            }
            group.cancelAll()
            return result
        }
    }

    private func waitForOpen() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume(returning: ())
                return
            }
            if let failedError {
                lock.unlock()
                continuation.resume(throwing: failedError)
                return
            }
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        completeOpen()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        failOpen(URLError(.networkConnectionLost))
    }

    private func completeOpen() {
        lock.lock()
        opened = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()

        pending.forEach { $0.resume(returning: ()) }
    }

    private func failOpen(_ error: Error) {
        lock.lock()
        guard !opened else {
            lock.unlock()
            return
        }
        failedError = error
        let pending = continuations
        continuations.removeAll()
        lock.unlock()

        pending.forEach { $0.resume(throwing: error) }
    }
}

public final class FieldSurveyBackendArrowSink: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let webSocketDelegate: FieldSurveyBackendWebSocketDelegate
    private let sendQueue = FieldSurveyBackendSendQueue()
    private let logger: Logger
    public let url: URL

    public init?(
        baseURL: String,
        authToken: String,
        sessionID: String,
        stream: FieldSurveyBackendStream,
        metadata: FieldSurveySessionUploadMetadata? = nil,
        urlSession: URLSession? = nil
    ) {
        let trimmedBaseURL = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "http://", with: "ws://")
            .replacingOccurrences(of: "https://", with: "wss://")

        let trimmedAuthToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAuthToken.isEmpty, trimmedAuthToken != "OFFLINE_MODE" else {
            return nil
        }

        guard var components = URLComponents(string: "\(trimmedBaseURL)/v1/field-survey/\(sessionID)/\(stream.rawValue)") else {
            return nil
        }

        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "ws_token", value: trimmedAuthToken)
        ]

        guard let url = components.url else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Bearer \(trimmedAuthToken)", forHTTPHeaderField: "Authorization")
        FieldSurveyRoomArtifactUploader.applySessionMetadataHeaders(metadata, to: &request)

        let webSocketDelegate = FieldSurveyBackendWebSocketDelegate()
        let session = urlSession ?? URLSession(
            configuration: .default,
            delegate: webSocketDelegate,
            delegateQueue: nil
        )

        self.url = url
        self.session = session
        self.webSocketDelegate = webSocketDelegate
        self.task = session.webSocketTask(with: request)
        self.logger = Logger(subsystem: "com.serviceradar.fieldsurvey", category: "FieldSurveyBackendArrowSink")
        self.task.resume()
    }

    public func connect(timeoutSeconds: TimeInterval = 8) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [sendQueue, task] in
                try await sendQueue.ping(task: task)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeoutSeconds, 1) * 1_000_000_000))
                throw URLError(.timedOut)
            }

            guard let result = try await group.next() else {
                throw URLError(.cannotConnectToHost)
            }
            group.cancelAll()
            return result
        }
    }

    public func send(_ payload: Data) async throws {
        try await webSocketDelegate.waitForOpen(timeoutSeconds: 8)
        try await sendQueue.send(payload, task: task)
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        logger.debug("Closed FieldSurvey backend Arrow sink")
    }
}

private actor BackendUploadBackoff {
    private let cooldownSeconds: TimeInterval
    private var pausedUntil: Date?
    private var inFlight = false

    init(cooldownSeconds: TimeInterval) {
        self.cooldownSeconds = cooldownSeconds
    }

    func claimSendSlot(now: Date = Date()) -> Bool {
        guard !inFlight else { return false }
        if let pausedUntil, now < pausedUntil {
            return false
        }
        inFlight = true
        return true
    }

    func markSuccess() {
        inFlight = false
        pausedUntil = nil
    }

    func markFailure(now: Date = Date()) {
        inFlight = false
        pausedUntil = now.addingTimeInterval(cooldownSeconds)
    }
}

private actor PreviewIngestThrottle {
    private var lastIngestTime: TimeInterval = 0

    func claim(minInterval: TimeInterval, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard now - lastIngestTime >= minInterval else { return false }
        lastIngestTime = now
        return true
    }
}

@MainActor
public final class SidekickRelay: ObservableObject {
    private static let twoGHzSurveyFrequenciesMHz = [
        2412, 2417, 2422, 2427, 2432, 2437, 2442, 2447, 2452, 2457, 2462
    ]
    private static let fiveGHzSurveyFrequenciesMHz = [
        5180, 5200, 5220, 5240,
        5745, 5765, 5785, 5805, 5825
    ]

    @Published public private(set) var status: SidekickRelayStatus = .idle
    @Published public private(set) var rfBatchCount: Int = 0
    @Published public private(set) var spectrumBatchCount: Int = 0
    @Published public private(set) var latestSpectrumSummary: SidekickSpectrumSummary?
    @Published public private(set) var spectrumSummaries: [SidekickSpectrumSummary] = []
    @Published public private(set) var adaptiveScan: SidekickAdaptiveScanSnapshot?
    @Published public private(set) var lastError: String?
    @Published public private(set) var spectrumWarning: String?
    @Published public private(set) var backendWarning: String?
    @Published public private(set) var backendFrameCount: Int = 0
    @Published public private(set) var previewObservationCount: Int = 0
    @Published public private(set) var previewDecodeError: String?

    private let logger = Logger(subsystem: "com.serviceradar.fieldsurvey", category: "SidekickRelay")
    private let observationDecoder = SidekickObservationArrowDecoder()
    private var tasks: [Task<Void, Never>] = []
    private var sinks: [FieldSurveyBackendArrowSink] = []
    private var pendingRFBatchCount = 0
    private var pendingSpectrumBatchCount = 0
    private var lastRFCountPublishTime: TimeInterval = 0
    private var lastSpectrumCountPublishTime: TimeInterval = 0
    private var pendingPreviewObservationCount = 0
    private var lastPreviewCountPublishTime: TimeInterval = 0
    private var lastSpectrumSummaryPublishTime: TimeInterval = 0
    private var latestSpectrumScoresByChannel: [String: SidekickSpectrumChannelScore] = [:]
    private var relayGeneration = 0

    public init() {}

    deinit {
        tasks.forEach { $0.cancel() }
        sinks.forEach { $0.close() }
    }

    public var displayWarning: String? {
        backendWarning ?? spectrumWarning
    }

    public func start(
        sessionID: String,
        wifiScanner: RealWiFiScanner? = nil,
        forwardToBackend: Bool = true,
        metadata: FieldSurveySessionUploadMetadata? = nil
    ) {
        stop()
        relayGeneration += 1
        let generation = relayGeneration
        status = .connecting
        rfBatchCount = 0
        spectrumBatchCount = 0
        latestSpectrumSummary = nil
        spectrumSummaries = []
        adaptiveScan = nil
        latestSpectrumScoresByChannel = [:]
        pendingRFBatchCount = 0
        pendingSpectrumBatchCount = 0
        lastRFCountPublishTime = 0
        lastSpectrumCountPublishTime = 0
        pendingPreviewObservationCount = 0
        lastPreviewCountPublishTime = 0
        lastSpectrumSummaryPublishTime = 0
        backendFrameCount = 0
        lastError = nil
        spectrumWarning = nil
        backendWarning = nil
        previewObservationCount = 0
        previewDecodeError = nil

        let settings = SettingsManager.shared
        let sidekickBaseURLs = SidekickClient.baseURLCandidates(from: settings.sidekickURL)
        let sidekickAuthToken = settings.sidekickAuthToken
        let sidekickSetupToken = settings.sidekickSetupToken
        let scannerDeviceID = settings.scannerDeviceId
        let sidekickRadioConfig = settings.sidekickRadioConfig
        let sidekickUplinkInterface = settings.sidekickUplinkInterface
        let sidekickSpectrumEnabled = settings.sidekickSpectrumEnabled
        let sidekickID = "fieldsurvey-sidekick"

        let rfSink: FieldSurveyBackendArrowSink?
        if forwardToBackend {
            guard let sink = FieldSurveyBackendArrowSink(
                baseURL: settings.apiURL,
                authToken: settings.authToken,
                sessionID: sessionID,
                stream: .rfObservations,
                metadata: metadata
            ) else {
                status = .failed("Invalid ServiceRadar RF ingest URL")
                return
            }
            rfSink = sink
            sinks.append(sink)
            backendWarning = "Backend upload connecting"
            Task { [weak self, sink, generation] in
                do {
                    try await sink.connect()
                    await MainActor.run {
                        guard self?.isCurrentGeneration(generation) == true else { return }
                        if self?.backendWarning?.hasPrefix("Backend upload") == true {
                            self?.backendWarning = nil
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard self?.isCurrentGeneration(generation) == true else { return }
                        self?.backendWarning = "Backend upload unavailable; recording locally: \(error.localizedDescription)"
                    }
                }
            }
        } else {
            rfSink = nil
        }

        let spectrumSink: FieldSurveyBackendArrowSink?
        if forwardToBackend, sidekickSpectrumEnabled {
            spectrumSink = FieldSurveyBackendArrowSink(
                baseURL: settings.apiURL,
                authToken: settings.authToken,
                sessionID: sessionID,
                stream: .spectrumObservations,
                metadata: metadata
            )
            if let spectrumSink {
                sinks.append(spectrumSink)
                Task { [weak self, spectrumSink, generation] in
                    do {
                        try await spectrumSink.connect()
                        await MainActor.run {
                            guard self?.isCurrentGeneration(generation) == true else { return }
                            if self?.backendWarning?.hasPrefix("Backend upload") == true {
                                self?.backendWarning = nil
                            }
                        }
                    } catch {
                        await MainActor.run {
                            guard self?.isCurrentGeneration(generation) == true else { return }
                            self?.backendWarning = "Backend upload unavailable; recording locally: \(error.localizedDescription)"
                        }
                    }
                }
            }
        } else {
            spectrumSink = nil
        }

        let bootstrapTask = Task { [weak self, rfSink, spectrumSink, generation] in
            do {
                let (sidekickClient, statusResponse) = try await Self.firstReachableSidekick(
                    baseURLs: sidekickBaseURLs,
                    apiToken: sidekickAuthToken,
                    setupToken: sidekickSetupToken,
                    deviceID: scannerDeviceID
                )
                try Task.checkCancellation()
                let radioConfigs = Self.radioConfigurations(
                    from: sidekickRadioConfig,
                    status: statusResponse,
                    uplinkInterfaceName: sidekickUplinkInterface
                )

                await MainActor.run {
                    guard self?.isCurrentGeneration(generation) == true else { return }
                    self?.adaptiveScan = statusResponse.adaptiveScan
                    self?.status = .streaming(
                        radios: radioConfigs.count,
                        spectrum: sidekickSpectrumEnabled
                    )
                }
                guard self?.isCurrentGeneration(generation) == true else { return }

                for radioConfig in radioConfigs {
                    self?.startRadioRelay(
                        generation: generation,
                        sidekickClient: sidekickClient,
                        backendSink: rfSink,
                        wifiScanner: wifiScanner,
                        sidekickID: sidekickID,
                        radioConfig: radioConfig
                    )
                }

                if sidekickSpectrumEnabled {
                    self?.startSpectrumRelay(
                        generation: generation,
                        sidekickClient: sidekickClient,
                        backendSink: spectrumSink,
                        sidekickID: sidekickID
                    )
                }

                self?.startStatusRelay(generation: generation, sidekickClient: sidekickClient)
            } catch {
                await MainActor.run {
                    guard self?.isCurrentGeneration(generation) == true else { return }
                    self?.lastError = "Sidekick setup: \(error.localizedDescription)"
                    self?.status = .failed(self?.lastError ?? error.localizedDescription)
                }
            }
        }

        tasks.append(bootstrapTask)
    }

    private func startStatusRelay(
        generation: Int,
        sidekickClient: SidekickClient
    ) {
        let task = Task.detached(priority: .utility) { [weak self, sidekickClient] in
            while !Task.isCancelled {
                guard await MainActor.run(body: { self?.isCurrentGeneration(generation) == true }) else { return }
                do {
                    let status = try await sidekickClient.status()
                    await MainActor.run {
                        guard self?.isCurrentGeneration(generation) == true else { return }
                        self?.adaptiveScan = status.adaptiveScan
                    }
                } catch {
                    await MainActor.run {
                        guard self?.isCurrentGeneration(generation) == true else { return }
                        if self?.spectrumWarning == nil {
                            self?.spectrumWarning = "Sidekick status unavailable: \(error.localizedDescription)"
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        tasks.append(task)
    }

    nonisolated private static func firstReachableSidekick(
        baseURLs: [URL],
        apiToken: String,
        setupToken: String,
        deviceID: String
    ) async throws -> (SidekickClient, SidekickStatusResponse) {
        var lastError: Error?
        let trimmedAPIToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSetupToken = setupToken.trimmingCharacters(in: .whitespacesAndNewlines)

        for baseURL in baseURLs {
            let client = SidekickClient(baseURL: baseURL, apiToken: trimmedAPIToken)
            do {
                let status = try await client.status()
                do {
                    _ = try await client.runtimeConfig()
                    return (client, status)
                } catch {
                    lastError = error
                    guard !trimmedSetupToken.isEmpty, trimmedSetupToken != trimmedAPIToken else {
                        continue
                    }

                    let setupClient = SidekickClient(baseURL: baseURL, apiToken: trimmedSetupToken)
                    let pairing = try await setupClient.claimPairing(
                        SidekickPairingClaimRequest(deviceID: deviceID, deviceName: "iPhone")
                    )
                    let pairedClient = SidekickClient(baseURL: baseURL, apiToken: pairing.token)
                    _ = try await pairedClient.runtimeConfig()
                    await MainActor.run {
                        let settings = SettingsManager.shared
                        settings.sidekickAuthToken = pairing.token
                        settings.sidekickSetupToken = ""
                    }
                    return (pairedClient, status)
                }
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SidekickClientError.invalidStreamURL
    }

    public func stop() {
        relayGeneration += 1
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        sinks.forEach { $0.close() }
        sinks.removeAll()
        status = .idle
        adaptiveScan = nil
        lastError = nil
        spectrumWarning = nil
        backendWarning = nil
        backendFrameCount = 0
    }

    private func startRadioRelay(
        generation: Int,
        sidekickClient: SidekickClient,
        backendSink: FieldSurveyBackendArrowSink?,
        wifiScanner: RealWiFiScanner?,
        sidekickID: String,
        radioConfig: SidekickRadioConfiguration
    ) {
        let observationDecoder = observationDecoder
        let task = Task.detached(priority: .utility) { [weak self, sidekickClient, backendSink, weak wifiScanner, observationDecoder] in
            var attempt = 0
            let backendBackoff = BackendUploadBackoff(cooldownSeconds: 20)
            let previewThrottle = PreviewIngestThrottle()

            while !Task.isCancelled {
                guard await MainActor.run(body: { self?.isCurrentGeneration(generation) == true }) else { return }
                do {
                    if let frequencyMHz = radioConfig.frequencyMHz {
                        let execution = try await sidekickClient.prepareMonitor(
                            SidekickMonitorPrepareRequest(
                                interfaceName: radioConfig.interfaceName,
                                frequencyMHz: frequencyMHz,
                                dryRun: false
                            )
                        )
                        try Self.validateMonitorPrepare(execution.result)
                    }

                    let stream = sidekickClient.observationBatches(
                        interfaceName: radioConfig.interfaceName,
                        sidekickID: sidekickID,
                        radioID: radioConfig.interfaceName,
                        frequenciesMHz: [],
                        hopIntervalMS: radioConfig.hopIntervalMS,
                        scanMode: "adaptive"
                    )

                    for try await batch in stream {
                        try Task.checkCancellation()
                        if await previewThrottle.claim(minInterval: 0.8) {
                            do {
                                let observations = try observationDecoder.decode(batch.payload)
                                await MainActor.run {
                                    guard self?.isCurrentGeneration(generation) == true else { return }
                                    self?.ingestPreviewObservations(observations, wifiScanner: wifiScanner)
                                }
                            } catch {
                                await MainActor.run {
                                    guard self?.isCurrentGeneration(generation) == true else { return }
                                    self?.previewDecodeError = error.localizedDescription
                                }
                            }
                        }
                        if let backendSink,
                           await backendBackoff.claimSendSlot() {
                            let payload = batch.payload
                            Task.detached(priority: .utility) { [weak self, backendSink, backendBackoff] in
                                do {
                                    try await backendSink.send(payload)
                                    await backendBackoff.markSuccess()
                                    await MainActor.run {
                                        guard self?.isCurrentGeneration(generation) == true else { return }
                                        self?.backendFrameCount += 1
                                        if self?.backendWarning?.hasPrefix("Backend upload") == true {
                                            self?.backendWarning = nil
                                        }
                                    }
                                } catch {
                                    await backendBackoff.markFailure()
                                    await MainActor.run {
                                        guard self?.isCurrentGeneration(generation) == true else { return }
                                        self?.backendWarning = "Backend upload unavailable; recording locally: \(error.localizedDescription)"
                                    }
                                }
                            }
                        }
                        attempt = 0
                        await MainActor.run {
                            guard self?.isCurrentGeneration(generation) == true else { return }
                            self?.lastError = nil
                            self?.recordRFBatch()
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    attempt += 1
                    await MainActor.run {
                        guard self?.isCurrentGeneration(generation) == true else { return }
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

    private func ingestPreviewObservations(_ observations: [SidekickObservation], wifiScanner: RealWiFiScanner?) {
        guard let wifiScanner else { return }
        guard !observations.isEmpty else { return }
        wifiScanner.ingestSidekickObservations(observations)
        recordPreviewObservations(observations.count)
        previewDecodeError = nil
    }

    private func startSpectrumRelay(
        generation: Int,
        sidekickClient: SidekickClient,
        backendSink: FieldSurveyBackendArrowSink?,
        sidekickID: String
    ) {
        let settings = SettingsManager.shared

        let sdrID = settings.sidekickSpectrumSDRID
        let serialNumber = settings.sidekickSpectrumSerialNumber.nilIfBlank
        let frequencyMinMHz = settings.sidekickSpectrumMinMHz
        let frequencyMaxMHz = settings.sidekickSpectrumMaxMHz
        let binWidthHz = settings.sidekickSpectrumBinWidthHz
        let lnaGainDB = settings.sidekickSpectrumLNAGainDB
        let vgaGainDB = settings.sidekickSpectrumVGAGainDB

        let task = Task.detached(priority: .utility) { [weak self, sidekickClient] in
            var attempt = 0
            let backendBackoff = BackendUploadBackoff(cooldownSeconds: 20)

            while !Task.isCancelled {
                guard await MainActor.run(body: { self?.isCurrentGeneration(generation) == true }) else { return }
                do {
                    let stream = sidekickClient.spectrumMessages(
                        sidekickID: sidekickID,
                        sdrID: sdrID,
                        serialNumber: serialNumber,
                        frequencyMinMHz: frequencyMinMHz,
                        frequencyMaxMHz: frequencyMaxMHz,
                        binWidthHz: binWidthHz,
                        lnaGainDB: lnaGainDB,
                        vgaGainDB: vgaGainDB
                    )

                    for try await message in stream {
                        try Task.checkCancellation()
                        attempt = 0
                        switch message {
                        case .summary(let summary):
                            await MainActor.run {
                                guard self?.isCurrentGeneration(generation) == true else { return }
                                self?.spectrumWarning = nil
                                self?.recordSpectrumSummary(summary)
                            }
                        case .batch(let batch):
                            if let backendSink,
                               await backendBackoff.claimSendSlot() {
                                let payload = batch.payload
                                Task.detached(priority: .utility) { [weak self, backendSink, backendBackoff] in
                                    do {
                                        try await backendSink.send(payload)
                                        await backendBackoff.markSuccess()
                                        await MainActor.run {
                                            guard self?.isCurrentGeneration(generation) == true else { return }
                                            self?.backendFrameCount += 1
                                            if self?.backendWarning?.hasPrefix("Backend upload") == true {
                                                self?.backendWarning = nil
                                            }
                                        }
                                    } catch {
                                        await backendBackoff.markFailure()
                                        await MainActor.run {
                                            guard self?.isCurrentGeneration(generation) == true else { return }
                                            self?.backendWarning = "Backend upload unavailable; recording locally: \(error.localizedDescription)"
                                        }
                                    }
                                }
                            }
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    attempt += 1
                    await MainActor.run {
                        guard self?.isCurrentGeneration(generation) == true else { return }
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
                if Self.supportsFiveGHz(lhs) != Self.supportsFiveGHz(rhs) {
                    return Self.supportsFiveGHz(lhs)
                }
                return (lhs.usb?.speedMbps ?? 0) > (rhs.usb?.speedMbps ?? 0)
            }

        return surveyRadios
            .enumerated()
            .map { index, radio in
                SidekickRadioConfiguration(
                    interfaceName: radio.name,
                    frequenciesMHz: Self.autoFrequenciesMHz(
                        forRadioAt: index,
                        radioCount: surveyRadios.count,
                        radio: radio
                    ),
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

    private func recordPreviewObservations(_ count: Int) {
        pendingPreviewObservationCount += count
        let now = Date().timeIntervalSince1970
        if now - lastPreviewCountPublishTime >= 0.5 {
            previewObservationCount = pendingPreviewObservationCount
            lastPreviewCountPublishTime = now
        }
    }

    private func recordSpectrumSummary(_ summary: SidekickSpectrumSummary) {
        for score in summary.channelScores {
            latestSpectrumScoresByChannel[score.id] = score
        }

        recordSpectrumBatch()

        let now = Date().timeIntervalSince1970
        guard now - lastSpectrumSummaryPublishTime >= 0.75 else { return }
        lastSpectrumSummaryPublishTime = now

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
        if spectrumSummaries.count > 180 {
            spectrumSummaries.removeFirst(spectrumSummaries.count - 180)
        }
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

    private static func autoFrequenciesMHz(
        forRadioAt index: Int,
        radioCount: Int,
        radio: SidekickRadioInterface
    ) -> [Int] {
        if radioCount <= 1 {
            return supportedSurveyFrequencies(for: radio)
        }

        return index == 0
            ? supportedSurveyFrequencies(for: radio, preferredBand: .fiveGHz)
            : supportedSurveyFrequencies(for: radio, preferredBand: .twoGHz)
    }

    private enum SurveyBand {
        case twoGHz
        case fiveGHz
    }

    private static func supportedSurveyFrequencies(
        for radio: SidekickRadioInterface,
        preferredBand: SurveyBand? = nil
    ) -> [Int] {
        let supported = radio.supportedFrequenciesMHz ?? []
        let twoGHz = filterSupported(twoGHzSurveyFrequenciesMHz, supportedBy: supported)
        let fiveGHz = filterSupported(fiveGHzSurveyFrequenciesMHz, supportedBy: supported)

        switch preferredBand {
        case .twoGHz:
            return twoGHz.isEmpty ? twoGHzSurveyFrequenciesMHz : twoGHz
        case .fiveGHz:
            return fiveGHz.isEmpty ? fiveGHzSurveyFrequenciesMHz : fiveGHz
        case nil:
            if supported.isEmpty {
                return twoGHzSurveyFrequenciesMHz + fiveGHzSurveyFrequenciesMHz
            }
            if !fiveGHz.isEmpty && twoGHz.isEmpty {
                return fiveGHz
            }
            if !twoGHz.isEmpty && fiveGHz.isEmpty {
                return twoGHz
            }
            return twoGHz + fiveGHz
        }
    }

    private static func supportsFiveGHz(_ radio: SidekickRadioInterface) -> Bool {
        guard let frequencies = radio.supportedFrequenciesMHz, !frequencies.isEmpty else {
            return true
        }
        return frequencies.contains { $0 >= 5_000 && $0 < 6_000 }
    }

    private static func filterSupported(_ frequencies: [Int], supportedBy supported: [Int]) -> [Int] {
        guard !supported.isEmpty else { return frequencies }
        return frequencies.filter { supported.contains($0) }
    }

    private static func autoHopIntervalMS(for radio: SidekickRadioInterface) -> Int {
        if radio.driver?.lowercased().contains("mt76") == true {
            return 1_000
        }
        return 250
    }

    nonisolated private static func validateMonitorPrepare(_ execution: SidekickMonitorPrepareExecution) throws {
        guard let failedExecution = execution.executions.first(where: { !$0.success }) else { return }
        let command = ([failedExecution.command.program] + failedExecution.command.args).joined(separator: " ")
        let detail = failedExecution.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            throw SidekickClientError.sidekickStreamError("monitor setup failed: \(command)")
        }
        throw SidekickClientError.sidekickStreamError("monitor setup failed: \(command): \(detail)")
    }

    private func isCurrentGeneration(_ generation: Int) -> Bool {
        relayGeneration == generation
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
