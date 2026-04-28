#if os(iOS)
import SwiftUI
import RoomPlan
import simd
import ARKit
import SceneKit
import UIKit
import Combine

@available(iOS 16.0, *)
private enum SurveyWorkflowPhase {
    case setup
    case capture
    case review
}

@available(iOS 16.0, *)
public struct SurveyView: View {
    @ObservedObject public var roomScanner: RoomScanner
    @ObservedObject public var wifiScanner: RealWiFiScanner
    @ObservedObject public var sessionStore: SurveySessionStore
    @ObservedObject private var settings = SettingsManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var sidekickRelay = SidekickRelay()
    private let resumeSnapshot: SurveySessionSnapshot?
    public var onExit: (() -> Void)?
    
    @State private var isStreaming = false
    @State private var isSidekickPreviewing = false
    @State private var workflowPhase: SurveyWorkflowPhase = .setup
    @State private var showSettings = false
    @State private var showSessionLibrary = false
    @State private var showSubnetIntel = false
    @State private var showAPIntel = false
    @State private var showSignalMap = false
    @State private var isMapView = false
    @State private var sessionID: String = UUID().uuidString
    @State private var autosaveSessionID: String?
    @State private var autosaveSessionName: String = ""
    @State private var showManualAPPrompt = false
    @State private var manualAPLabel = ""
    @State private var saveStatusMessage: String?
    @State private var isExportingOfflineBundle = false
    @State private var recoveredSnapshot: SurveySessionSnapshot?
    @State private var didApplyResumeSnapshot = false
    @State private var checkpointTask: Task<Void, Never>?
    @State private var lastAutosavedHeatmapCount = 0
    @State private var captureStartedAt: Date?
    private let autosaveTimer = Timer.publish(every: 12.0, on: .main, in: .common).autoconnect()
    
    // Core Pipeline Instantiation for God-View Ingestion
    private let arrowStreamer = ArrowStreamer()
    private let roomArtifactUploader = FieldSurveyRoomArtifactUploader()
    
    public init(
        roomScanner: RoomScanner,
        wifiScanner: RealWiFiScanner,
        sessionStore: SurveySessionStore,
        resumeSnapshot: SurveySessionSnapshot? = nil,
        onExit: (() -> Void)? = nil
    ) {
        self.roomScanner = roomScanner
        self.wifiScanner = wifiScanner
        self.sessionStore = sessionStore
        self.resumeSnapshot = resumeSnapshot
        self.onExit = onExit
    }

    public var body: some View {
        ZStack {
            switch workflowPhase {
            case .setup:
                SurveySetupPhaseView(
                    backendEnabled: backendStreamingEnabled,
                    rfEnabled: settings.rfScanningEnabled,
                    sessionName: autosaveSessionName,
                    heatmapPointCount: wifiScanner.heatmapPoints.count,
                    onStartLocal: startSidekickPreview,
                    onStartBackend: startBackendStreaming,
                    onReview: { workflowPhase = .review },
                    onSessions: { showSessionLibrary = true },
                    onSettings: { showSettings = true },
                    onExit: onExit
                )
            case .capture:
                CompositeSurveyView(
                    roomScanner: roomScanner,
                    wifiScanner: wifiScanner,
                    isMapView: $isMapView
                )
                .edgesIgnoringSafeArea(.all)
            case .review:
                SurveyReviewPhaseView(
                    sessionName: autosaveSessionName,
                    heatmapPointCount: signalMapPoints.count,
                    spectrumCount: currentSpectrumSummaries.count,
                    onResumeCapture: enterCapturePhase,
                    onOpenSignalMap: { showSignalMap = true },
                    onSessions: { showSessionLibrary = true },
                    onDone: onExit
                )
            }

            if workflowPhase == .capture {
                VStack {
                    if !backendStreamingEnabled {
                        Text("Backend upload is disabled in Offline Mode; Sidekick preview is still available")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.black)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 16)
                        .background(Color.yellow.opacity(0.9))
                        .cornerRadius(20)
                        .padding(.top, 10)
                }
                
                HStack {
                    VStack(alignment: .leading) {
                        Text("ServiceRadar FieldSurvey")
                            .font(.headline)
                            .foregroundColor(.green)
                            .shadow(color: .green, radius: 2, x: 0, y: 0)
                        
                        Text("LiDAR / AR Mode")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .opacity(0.8)

                        Text(wifiScanner.poseTrackingStatus.label)
                            .font(.caption2)
                            .foregroundColor(wifiScanner.poseTrackingStatus.canPlaceRF ? .green : .orange)

                        Text(settings.rfScanningEnabled ? "RF Scan Enabled" : "RF Scan Paused")
                            .font(.caption2)
                            .foregroundColor(settings.rfScanningEnabled ? .green : .orange)

                        Text(
                            settings.arPriorityModeEnabled
                                ? (settings.arPriorityLoadShedActive ? "AR Priority: ACTIVE" : "AR Priority: standby")
                                : "AR Priority: off"
                        )
                        .font(.caption2)
                        .foregroundColor(
                            settings.arPriorityModeEnabled
                                ? (settings.arPriorityLoadShedActive ? .orange : .green)
                                : .gray
                        )

                        Text("Mapped APs: \(wifiScanner.resolvedAPLocations.count) • Roams: \(wifiScanner.roamEvents.count) • Heat pts: \(wifiScanner.heatmapPoints.count)")
                            .font(.caption2)
                            .foregroundColor(.cyan.opacity(0.85))

                        CaptureStatusPanel(
                            sidekickStatus: sidekickRelay.status,
                            rfBatches: sidekickRelay.rfBatchCount,
                            rfObservations: sidekickRelay.previewObservationCount,
                            poseSamples: wifiScanner.poseStreamFrameCount,
                            backendFrames: sidekickRelay.backendFrameCount,
                            adaptiveScan: sidekickRelay.adaptiveScan,
                            isStreaming: isStreaming,
                            isPreviewing: isSidekickPreviewing,
                            backendEnabled: backendStreamingEnabled,
                            elapsedSeconds: captureElapsedSeconds
                        )
                        .padding(.top, 4)

                        if let summary = sidekickRelay.latestSpectrumSummary {
                            SpectrumAnalyzerMiniPanel(
                                summary: summary,
                                sweepCount: sidekickRelay.spectrumBatchCount,
                                compact: true
                            )
                            .frame(width: 260)
                            .padding(.top, 4)
                        }

                        if !autosaveSessionName.isEmpty {
                            Text("Autosaving: \(autosaveSessionName)")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.72))
                        }
                        
                        HStack(spacing: 6) {
                            Circle()
                                .fill(networkMonitor.isConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            
                            Text(networkMonitor.isConnected ? "Online" : "Offline")
                                .font(.caption)
                                .foregroundColor(networkMonitor.isConnected ? .green : .red)
                            
                            if networkMonitor.isConnected {
                                if networkMonitor.isWiFi {
                                    Image(systemName: "wifi")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                } else if networkMonitor.isCellular {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.green, lineWidth: 1)
                    )
                    
                    Spacer()
                    
                    VStack(spacing: 12) {
                        if onExit != nil {
                            Button(action: {
                                stopSidekickForLifecycle()
                                onExit?()
                            }) {
                                Image(systemName: "house.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.cyan)
                                    .padding(12)
                                    .background(Color.black.opacity(0.7))
                                    .clipShape(Circle())
                            }
                        }

                        Button(action: {
                            showSettings.toggle()
                        }) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                        }

                        Button(action: {
                            settings.rfScanningEnabled.toggle()
                        }) {
                            Image(systemName: settings.rfScanningEnabled ? "dot.radiowaves.left.and.right" : "wifi.slash")
                                .font(.system(size: 24))
                                .foregroundColor(settings.rfScanningEnabled ? .green : .orange)
                                .padding(12)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                        }

                        Button(action: {
                            manualAPLabel = ""
                            showManualAPPrompt = true
                        }) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 24))
                                .foregroundColor(.green)
                                .padding(12)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                        }

                        Button(action: {
                            showSessionLibrary = true
                        }) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                        }

                        Button(action: {
                            showAPIntel = true
                        }) {
                            Image(systemName: "list.bullet.rectangle.portrait")
                                .font(.system(size: 24))
                                .foregroundColor(.cyan)
                                .padding(12)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                        }

                        Button(action: {
                            showSignalMap = true
                        }) {
                            Image(systemName: "chart.dots.scatter")
                                .font(.system(size: 24))
                                .foregroundColor(.green)
                                .padding(12)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                        }

                        Button(action: {
                            showSubnetIntel = true
                        }) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 24))
                                .foregroundColor(.purple.opacity(0.9))
                                .padding(12)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.top, 40)
                .padding(.horizontal)
                
                Spacer()

                if let saveStatusMessage {
                    Text(saveStatusMessage)
                        .font(.caption2)
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.65))
                        .cornerRadius(12)
                        .padding(.bottom, 10)
                }
                
                // Pipeline Control Bar
                HStack(spacing: 20) {
                    Button(action: {
                        checkpointSession(includeMesh: true)
                    }) {
                        Text("Checkpoint")
                            .fontWeight(.bold)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.cyan.opacity(0.85))
                            .foregroundColor(.black)
                            .cornerRadius(25)
                    }

                    Button(action: {
                        if backendStreamingEnabled {
                            if isStreaming {
                                stopStreamingPipeline()
                            } else {
                                startBackendStreaming()
                            }
                        } else {
                            if isSidekickPreviewing {
                                stopSidekickPreview()
                            } else {
                                startSidekickPreview()
                            }
                        }
                    }) {
                        Text(streamButtonTitle)
                            .fontWeight(.bold)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(pipelineControlActive ? Color.red.opacity(0.8) : Color.green.opacity(0.8))
                            .foregroundColor(pipelineControlActive ? .white : .black)
                            .cornerRadius(25)
                    }
                    
                    Button(action: {
                        exportOfflineBundle()
                    }) {
                        Image(systemName: "arrow.up.doc.fill")
                            .font(.system(size: 24))
                            .foregroundColor(isExportingOfflineBundle ? .cyan : .white)
                            .padding()
                            .background(Color.black.opacity(0.7))
                            .clipShape(Circle())
                    }
                    .disabled(isExportingOfflineBundle)

                    Button(action: {
                        discardLiveRFPreview()
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 22))
                            .foregroundColor(hasLivePreviewData ? .orange : .gray)
                            .padding()
                            .background(Color.black.opacity(0.7))
                            .clipShape(Circle())
                    }
                    .disabled(!hasLivePreviewData)
                }
                .padding(.bottom, 40)
            }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showSessionLibrary) {
            SessionLibraryView(
                roomScanner: roomScanner,
                wifiScanner: wifiScanner,
                sessionStore: sessionStore,
                onResume: resumeLoadedSession(_:)
            )
        }
        .sheet(isPresented: $showSubnetIntel) {
            SubnetIntelView()
        }
        .sheet(isPresented: $showAPIntel) {
            APIntelView(wifiScanner: wifiScanner)
        }
        .sheet(isPresented: $showSignalMap) {
            SignalMapView(
                title: "Live Signal Map",
                points: signalMapPoints,
                landmarks: signalMapLandmarks,
                floorplanSegments: signalMapFloorplanSegments,
                currentPose: wifiScanner.currentDevicePose,
                rfBatchCount: sidekickRelay.rfBatchCount,
                spectrumBatchCount: sidekickRelay.spectrumBatchCount,
                spectrumSummary: currentSpectrumSummary,
                spectrumSummaries: currentSpectrumSummaries,
                adaptiveScan: sidekickRelay.adaptiveScan,
                sidekickStatus: sidekickRelay.status,
                sidekickError: sidekickRelay.lastError,
                sidekickWarning: sidekickRelay.displayWarning,
                backendFrameCount: sidekickRelay.backendFrameCount,
                rfObservationCount: sidekickRelay.previewObservationCount,
                rfDecodeError: sidekickRelay.previewDecodeError
            )
        }
        .alert("Mark Access Point", isPresented: $showManualAPPrompt) {
            TextField("AP label", text: $manualAPLabel)
            Button("Cancel", role: .cancel) {}
            Button("Mark Here") {
                markManualAccessPoint()
            }
        } message: {
            Text("Stand near the AP, then save its current LiDAR position.")
        }
        // Lifecycle hooks for LiDAR pose, Sidekick RF preview, and autosave.
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            applyResumeSnapshotIfNeeded()
            beginAutosaveSession()
            checkpointSession(includeMesh: false, showStatus: false)
        }
        .onDisappear {
            checkpointSession(includeMesh: true, showStatus: false)
            UIApplication.shared.isIdleTimerDisabled = false
            wifiScanner.stopScanning(clearData: false)
            SubnetScanner.shared.stopScanning()
            stopSidekickForLifecycle()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            stopSidekickForLifecycle()
        }
        .onChange(of: settings.rfScanningEnabled) { _, enabled in
            guard workflowPhase == .capture else { return }
            applyRFState(enabled)
        }
        .onReceive(autosaveTimer) { _ in
            checkpointSession(includeMesh: false, showStatus: false)
        }
        .onChange(of: wifiScanner.heatmapPoints.count) { _, count in
            guard count >= lastAutosavedHeatmapCount + 75 else { return }
            lastAutosavedHeatmapCount = count
            checkpointSession(includeMesh: false, showStatus: false)
        }
    }

    private func startSidekickPreview() {
        beginAutosaveSession()
        checkpointSession(includeMesh: false, showStatus: false)
        enterCapturePhase()
        isSidekickPreviewing = true
        captureStartedAt = Date()
        sessionID = autosaveSessionID ?? UUID().uuidString
        sidekickRelay.start(
            sessionID: sessionID,
            wifiScanner: wifiScanner,
            forwardToBackend: false,
            metadata: activeSessionUploadMetadata()
        )
    }

    private func startBackendStreaming() {
        guard settings.backendUploadEnabled else {
            saveStatusMessage = "Backend upload is not authenticated. Sign in and run Check Backend."
            clearSaveStatus(after: 3.5)
            return
        }
        beginAutosaveSession()
        checkpointSession(includeMesh: false, showStatus: false)
        enterCapturePhase()
        isStreaming = true
        captureStartedAt = Date()
        saveStatusMessage = "Starting FieldSurvey backend upload..."
        clearSaveStatus(after: 3.0)
        sessionID = autosaveSessionID ?? UUID().uuidString
        let uploadMetadata = activeSessionUploadMetadata()
        wifiScanner.startPoseStreaming(sessionID: sessionID, metadata: uploadMetadata)
        sidekickRelay.start(
            sessionID: sessionID,
            wifiScanner: wifiScanner,
            forwardToBackend: true,
            metadata: uploadMetadata
        )
    }

    private func stopStreamingPipeline() {
        checkpointSession(includeMesh: true, showStatus: false)
        stopCaptureSideEffects()
        sidekickRelay.stop()
        isStreaming = false
        isSidekickPreviewing = false
        captureStartedAt = nil
        workflowPhase = .review
    }

    private func stopSidekickPreview() {
        checkpointSession(includeMesh: true, showStatus: false)
        stopCaptureSideEffects()
        sidekickRelay.stop()
        isSidekickPreviewing = false
        captureStartedAt = nil
        workflowPhase = .review
    }

    private func stopSidekickForLifecycle() {
        guard isStreaming || isSidekickPreviewing else { return }
        checkpointSession(includeMesh: true, showStatus: false)
        stopCaptureSideEffects()
        sidekickRelay.stop()
        isStreaming = false
        isSidekickPreviewing = false
        captureStartedAt = nil
        if workflowPhase == .capture {
            workflowPhase = .review
        }
    }

    private func stopCaptureSideEffects() {
        wifiScanner.stopPoseStreaming()
        wifiScanner.stopScanning(clearData: false)
        SubnetScanner.shared.stopScanning()
    }

    private func applyRFState(_ enabled: Bool) {
        wifiScanner.setRFScanning(enabled: enabled)
        if enabled {
            SubnetScanner.shared.startScanning()
        } else {
            SubnetScanner.shared.stopScanning()
        }
    }

    private func enterCapturePhase() {
        workflowPhase = .capture
        applyRFState(settings.rfScanningEnabled)
    }

    private var backendStreamingEnabled: Bool {
        settings.backendUploadEnabled
    }

    private var pipelineControlActive: Bool {
        backendStreamingEnabled ? isStreaming : isSidekickPreviewing
    }

    private var streamButtonTitle: String {
        if pipelineControlActive {
            return backendStreamingEnabled ? "Stop Live Stream" : "Stop Sidekick Preview"
        }
        return backendStreamingEnabled ? "Stream to God-View" : "Start Sidekick Preview"
    }

    private var hasLivePreviewData: Bool {
        wifiScanner.heatmapPoints.contains { !$0.bssid.hasPrefix("manual-ap-") } ||
            wifiScanner.accessPoints.keys.contains { !$0.hasPrefix("manual-ap-") }
    }

    private var captureElapsedSeconds: Int {
        guard let captureStartedAt else { return 0 }
        return max(0, Int(Date().timeIntervalSince(captureStartedAt)))
    }

    private func discardLiveRFPreview() {
        wifiScanner.discardLiveRFPreview()
        checkpointSession(includeMesh: false, showStatus: false)
        saveStatusMessage = "Discarded live RF preview data."
        clearSaveStatus(after: 2.4)
    }

    private func beginAutosaveSession() {
        guard autosaveSessionID == nil else { return }
        if let resumeSnapshot {
            autosaveSessionID = resumeSnapshot.record.id
            autosaveSessionName = resumeSnapshot.record.name
            sessionID = resumeSnapshot.record.id
            recoveredSnapshot = resumeSnapshot
            return
        }
        autosaveSessionID = UUID().uuidString
        autosaveSessionName = "Survey \(Self.sessionDateFormatter.string(from: Date()))"
    }

    private func applyResumeSnapshotIfNeeded() {
        guard !didApplyResumeSnapshot, let resumeSnapshot else { return }
        wifiScanner.loadSessionSnapshot(resumeSnapshot)
        autosaveSessionID = resumeSnapshot.record.id
        autosaveSessionName = resumeSnapshot.record.name
        sessionID = resumeSnapshot.record.id
        recoveredSnapshot = resumeSnapshot
        didApplyResumeSnapshot = true
    }

    private func checkpointSession(includeMesh: Bool, showStatus: Bool = true) {
        beginAutosaveSession()
        guard let autosaveSessionID else { return }

        checkpointTask?.cancel()

        let sessionName = autosaveSessionName
        let spectrumSummaries = currentSpectrumSummaries
        checkpointTask = Task { @MainActor in
            do {
                let record = try await sessionStore.autosaveCurrentSession(
                    id: autosaveSessionID,
                    name: sessionName,
                    roomScanner: roomScanner,
                    wifiScanner: wifiScanner,
                    spectrumSummaries: spectrumSummaries,
                    includeMesh: includeMesh
                )
                guard !Task.isCancelled else { return }
                autosaveSessionName = record.name
                let roomArtifactUploaded: Bool?
                if includeMesh {
                    roomArtifactUploaded = await uploadRoomArtifact(record: record, showStatus: showStatus)
                    guard !Task.isCancelled else { return }
                } else {
                    roomArtifactUploaded = false
                }
                if showStatus, roomArtifactUploaded != nil {
                    let checkpointPrefix = (roomArtifactUploaded == true)
                        ? "Checkpoint saved + room scan uploaded"
                        : "Checkpoint saved locally"
                    saveStatusMessage = includeMesh ? "\(checkpointPrefix): \(record.name)" : "Autosaved: \(record.name)"
                    clearSaveStatus(after: 2.6)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if showStatus {
                    saveStatusMessage = "Autosave failed: \(error.localizedDescription)"
                    clearSaveStatus(after: 3.5)
                }
            }
        }
    }

    private func uploadRoomArtifact(record: SurveySessionRecord, showStatus: Bool) async -> Bool? {
        guard backendStreamingEnabled else { return false }

        var uploaded: [String] = []
        var failures: [String] = []
        let snapshot = sessionStore.loadSession(id: record.id)
        let uploadMetadata = activeSessionUploadMetadata(record: record, snapshot: snapshot)

        do {
            let floorplanURL = try roomScanner.exportCurrentFloorplanGeoJSON()
            let floorplanResult = try await roomArtifactUploader.uploadFloorplanGeoJSON(
                fileURL: floorplanURL,
                baseURL: settings.apiURL,
                authToken: settings.authToken,
                sessionID: record.id,
                metadata: uploadMetadata
            )
            if floorplanResult.ok {
                uploaded.append("floorplan")
            }
        } catch {
            failures.append("floorplan: \(error.localizedDescription)")
        }

        do {
            let roomPlanURL = try roomScanner.exportCurrentRoomToUSDZ()
            let roomPlanResult = try await roomArtifactUploader.uploadRoomPlanUSDZ(
                fileURL: roomPlanURL,
                baseURL: settings.apiURL,
                authToken: settings.authToken,
                sessionID: record.id,
                metadata: uploadMetadata
            )
            if roomPlanResult.ok {
                uploaded.append("RoomPlan")
            }
        } catch {
            failures.append("RoomPlan: \(error.localizedDescription)")
        }

        do {
            let pointCloudURL = try roomScanner.exportPointCloudPLY()
            let pointCloudResult = try await roomArtifactUploader.uploadPointCloudPLY(
                fileURL: pointCloudURL,
                baseURL: settings.apiURL,
                authToken: settings.authToken,
                sessionID: record.id,
                metadata: uploadMetadata
            )
            if pointCloudResult.ok {
                uploaded.append("point cloud")
            }
        } catch {
            failures.append("point cloud: \(error.localizedDescription)")
        }

        if showStatus {
            if failures.isEmpty {
                saveStatusMessage = "Uploaded \(uploaded.joined(separator: " + "))"
                clearSaveStatus(after: 2.4)
            } else if uploaded.isEmpty {
                saveStatusMessage = "Room artifact upload failed: \(failures.joined(separator: "; "))"
                clearSaveStatus(after: 3.5)
            } else {
                saveStatusMessage = "Uploaded \(uploaded.joined(separator: " + ")); failed \(failures.joined(separator: "; "))"
                clearSaveStatus(after: 3.5)
            }
        }

        if uploaded.isEmpty {
            return nil
        }
        return failures.isEmpty ? true : nil
    }

    private func activeSessionUploadMetadata(
        record: SurveySessionRecord? = nil,
        snapshot: SurveySessionSnapshot? = nil
    ) -> FieldSurveySessionUploadMetadata {
        let base = snapshot?.uploadMetadata ?? recoveredSnapshot?.uploadMetadata ?? settings.currentSurveyUploadMetadata
        guard let record else { return base }
        return base.merged(record: record, snapshot: snapshot)
    }

    private func markManualAccessPoint() {
        guard let pose = wifiScanner.currentDevicePose else {
            saveStatusMessage = "No LiDAR pose yet. Move the phone until tracking starts."
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                saveStatusMessage = nil
            }
            return
        }

        let label = manualAPLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        wifiScanner.addManualAccessPoint(
            label: label.isEmpty ? "Access Point" : label,
            position: pose,
            confidence: 1.0,
            source: "manual"
        )
        checkpointSession(includeMesh: false, showStatus: false)
        saveStatusMessage = "Marked AP: \(label.isEmpty ? "Access Point" : label)"
        manualAPLabel = ""
        clearSaveStatus(after: 2.5)
    }

    private var signalMapPoints: [WiFiHeatmapPoint] {
        if !wifiScanner.heatmapPoints.isEmpty {
            return wifiScanner.heatmapPoints
        }
        return recoveredSnapshot?.heatmapPoints ?? []
    }

    private var signalMapLandmarks: [ManualAPLandmark] {
        var landmarks = wifiScanner.manualAPLandmarks
        let autoCandidates = wifiScanner.resolvedAPLocations
            .filter { bssid, resolved in
                !bssid.hasPrefix("manual-ap-") &&
                    resolved.confidence >= 0.30 &&
                    !landmarks.contains { simd_distance($0.position, resolved.position) < 0.8 }
            }
            .sorted { lhs, rhs in
                if lhs.value.confidence == rhs.value.confidence {
                    return lhs.value.observationCount > rhs.value.observationCount
                }
                return lhs.value.confidence > rhs.value.confidence
            }
            .prefix(8)
            .map { bssid, resolved in
                let trimmedSSID = wifiScanner.accessPoints[bssid]?.ssid
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let displayName = trimmedSSID.isEmpty ? String(bssid.suffix(5)) : trimmedSSID
                return ManualAPLandmark(
                    id: "auto-\(bssid)",
                    label: "\(displayName) \(Int((resolved.confidence * 100).rounded()))%",
                    confidence: Double(resolved.confidence),
                    source: "sidekick-auto",
                    createdAt: Date().timeIntervalSince1970,
                    updatedAt: Date().timeIntervalSince1970,
                    position: resolved.position
                )
            }

        landmarks.append(contentsOf: autoCandidates)
        if !landmarks.isEmpty {
            return landmarks
        }
        return recoveredSnapshot?.manualLandmarks ?? []
    }

    private var signalMapFloorplanSegments: [SurveyFloorplanSegment] {
        let liveSegments = roomScanner.currentFloorplanSegments()
        if !liveSegments.isEmpty {
            return liveSegments
        }
        return recoveredSnapshot?.floorplanSegments ?? []
    }

    private var currentSpectrumSummary: SidekickSpectrumSummary? {
        sidekickRelay.latestSpectrumSummary ?? recoveredSnapshot?.spectrumSummaries.last
    }

    private var currentSpectrumSummaries: [SidekickSpectrumSummary] {
        if !sidekickRelay.spectrumSummaries.isEmpty {
            return sidekickRelay.spectrumSummaries
        }
        return recoveredSnapshot?.spectrumSummaries ?? []
    }

    private func resumeLoadedSession(_ snapshot: SurveySessionSnapshot) {
        autosaveSessionID = snapshot.record.id
        autosaveSessionName = snapshot.record.name
        sessionID = snapshot.record.id
        recoveredSnapshot = snapshot
        enterCapturePhase()
    }

    private func clearSaveStatus(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            saveStatusMessage = nil
        }
    }

    private func exportOfflineBundle() {
        guard !isExportingOfflineBundle else { return }

        let samples = Array(wifiScanner.accessPoints.values)
        guard !samples.isEmpty else {
            saveStatusMessage = "No RF samples yet. Walk a bit and retry."
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                saveStatusMessage = nil
            }
            return
        }

        isExportingOfflineBundle = true
        saveStatusMessage = "Exporting offline bundle..."
        let exportSamples = Array(samples.suffix(2600))
        let filename = "survey_bulk_\(Int(Date().timeIntervalSince1970))"

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let payload = try arrowStreamer.encodeBatch(samples: exportSamples)
                let fileURL = try arrowStreamer.compressForOfflineUpload(payload: payload, filename: filename)
                DispatchQueue.main.async {
                    isExportingOfflineBundle = false
                    saveStatusMessage = "Offline bundle saved: \(fileURL.lastPathComponent)"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        saveStatusMessage = nil
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isExportingOfflineBundle = false
                    saveStatusMessage = "Offline export failed: \(error.localizedDescription)"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                        saveStatusMessage = nil
                    }
                }
            }
        }
    }

    private static let sessionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

@available(iOS 16.0, *)
private struct SurveySetupPhaseView: View {
    let backendEnabled: Bool
    let rfEnabled: Bool
    let sessionName: String
    let heatmapPointCount: Int
    let onStartLocal: () -> Void
    let onStartBackend: () -> Void
    let onReview: () -> Void
    let onSessions: () -> Void
    let onSettings: () -> Void
    let onExit: (() -> Void)?

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.035, blue: 0.05)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("FieldSurvey")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                        Text(sessionName.isEmpty ? "Setup" : sessionName)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.cyan.opacity(0.86))
                    }

                    Spacer()

                    if let onExit {
                        Button(action: onExit) {
                            Image(systemName: "house.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.cyan)
                                .frame(width: 44, height: 44)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Circle())
                        }
                    }
                }

                HStack(spacing: 10) {
                    CaptureMetric(label: "RF", value: rfEnabled ? "ready" : "paused", tint: rfEnabled ? .green : .orange)
                    CaptureMetric(label: "Backend", value: backendEnabled ? "ready" : "offline", tint: backendEnabled ? .green : .orange)
                    CaptureMetric(label: "Heat", value: "\(heatmapPointCount)", tint: .cyan)
                }

                VStack(spacing: 12) {
                    PhaseActionButton(
                        title: backendEnabled ? "Start Backend Capture" : "Start Local Capture",
                        icon: backendEnabled ? "antenna.radiowaves.left.and.right" : "play.fill",
                        tint: .green,
                        action: backendEnabled ? onStartBackend : onStartLocal
                    )

                    if backendEnabled {
                        PhaseActionButton(
                            title: "Start Local Preview",
                            icon: "play",
                            tint: .cyan,
                            action: onStartLocal
                        )
                    }

                    PhaseActionButton(title: "Review", icon: "chart.dots.scatter", tint: .cyan, action: onReview)
                    PhaseActionButton(title: "Sessions", icon: "folder.fill", tint: .purple, action: onSessions)
                    PhaseActionButton(title: "Settings", icon: "gearshape.fill", tint: .orange, action: onSettings)
                }

                Spacer()
            }
            .padding(22)
        }
        .preferredColorScheme(.dark)
    }
}

@available(iOS 16.0, *)
private struct SurveyReviewPhaseView: View {
    let sessionName: String
    let heatmapPointCount: Int
    let spectrumCount: Int
    let onResumeCapture: () -> Void
    let onOpenSignalMap: () -> Void
    let onSessions: () -> Void
    let onDone: (() -> Void)?

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.035, blue: 0.05)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Review")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                        Text(sessionName.isEmpty ? "Current survey" : sessionName)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.cyan.opacity(0.86))
                    }

                    Spacer()

                    if let onDone {
                        Button(action: onDone) {
                            Image(systemName: "house.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.cyan)
                                .frame(width: 44, height: 44)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Circle())
                        }
                    }
                }

                HStack(spacing: 10) {
                    CaptureMetric(label: "Heat", value: "\(heatmapPointCount)", tint: .green)
                    CaptureMetric(label: "Spectrum", value: "\(spectrumCount)", tint: .orange)
                }

                VStack(spacing: 12) {
                    PhaseActionButton(title: "Open Signal Map", icon: "chart.dots.scatter", tint: .green, action: onOpenSignalMap)
                    PhaseActionButton(title: "Resume Capture", icon: "camera.viewfinder", tint: .cyan, action: onResumeCapture)
                    PhaseActionButton(title: "Sessions", icon: "folder.fill", tint: .purple, action: onSessions)
                }

                Spacer()
            }
            .padding(22)
        }
        .preferredColorScheme(.dark)
    }
}

@available(iOS 16.0, *)
private struct PhaseActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

@available(iOS 16.0, *)
private struct CaptureMetric: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.58))
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

@available(iOS 16.0, *)
private struct CaptureStatusPanel: View {
    let sidekickStatus: SidekickRelayStatus
    let rfBatches: Int
    let rfObservations: Int
    let poseSamples: Int
    let backendFrames: Int
    let adaptiveScan: SidekickAdaptiveScanSnapshot?
    let isStreaming: Bool
    let isPreviewing: Bool
    let backendEnabled: Bool
    let elapsedSeconds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(modeLabel)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(modeColor)
            Text("Elapsed: \(elapsedLabel)")
            Text("Sidekick: \(sidekickLabel)")
            Text("RF: \(rfBatches) batches / \(rfObservations) obs")
            if let adaptiveScan {
                Text("Scan: \(adaptiveScanLabel(adaptiveScan))")
            }
            Text("Pose: \(poseSamples) frames")
            Text("Backend: \(backendLabel)")
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundColor(.white.opacity(0.82))
    }

    private var modeLabel: String {
        if isStreaming {
            return "CAPTURE: BACKEND STREAM"
        }
        if isPreviewing {
            return "CAPTURE: LOCAL PREVIEW"
        }
        return "SETUP: CAPTURE STOPPED"
    }

    private var modeColor: Color {
        if isStreaming || isPreviewing {
            return .green
        }
        return .orange
    }

    private var sidekickLabel: String {
        switch sidekickStatus {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting"
        case .streaming(let radios, let spectrum):
            return spectrum ? "\(radios) radios + SDR" : "\(radios) radios"
        case .failed:
            return "failed"
        }
    }

    private var backendLabel: String {
        guard backendEnabled else { return "offline" }
        return backendFrames > 0 ? "\(backendFrames) frames" : "pending"
    }

    private func adaptiveScanLabel(_ snapshot: SidekickAdaptiveScanSnapshot) -> String {
        let topChannels = snapshot.channels
            .filter { $0.observed != false }
            .prefix(4)
            .map { channel in
                let channelLabel = channel.channel.map { "ch\($0)" } ?? "\(channel.frequencyMHz)"
                return "\(channelLabel)x\(channel.weight)"
            }
            .joined(separator: " ")
        let observedChannels = snapshot.channels.filter { $0.observed == true }.count

        if topChannels.isEmpty {
            return "\(snapshot.observedBSSIDCount) APs observed / \(snapshot.channelCount) ch"
        }
        return "\(topChannels) • \(snapshot.observedBSSIDCount) APs • \(observedChannels)/\(snapshot.channelCount) ch"
    }

    private var elapsedLabel: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return "\(minutes)m \(seconds)s"
    }
}

@available(iOS 16.0, *)
public struct ContentView: View {
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var roomScanner = RoomScanner()
    @StateObject private var wifiScanner = RealWiFiScanner()
    @StateObject private var sessionStore = SurveySessionStore()
    @State private var showSplash = true
    
    public init() {}
    
    public var body: some View {
        ZStack {
            Group {
                if settings.authToken.isEmpty {
                    LoginView()
                } else {
                    HomeDashboardView(
                        roomScanner: roomScanner,
                        wifiScanner: wifiScanner,
                        sessionStore: sessionStore
                    )
                    .preferredColorScheme(.dark)
                }
            }

            if showSplash {
                AppSplashView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.easeOut(duration: 0.35)) {
                    showSplash = false
                }
            }
        }
    }
}

@available(iOS 16.0, *)
public struct LoginView: View {
    @StateObject private var settings = SettingsManager.shared
    
    @State private var isAuthenticating: Bool = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    
    public init() {}
    
    public var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                Spacer().frame(height: 40)
            
            // ServiceRadar Logo & Branding
            VStack(spacing: 15) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 100, height: 100)
                    
                    Image("serviceradar_logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 60, height: 60)
                }
                
                Text("ServiceRadar")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("FieldSurvey Operations")
                    .font(.headline)
                    .foregroundColor(.gray)
            }
            
            VStack(spacing: 20) {
                // Server URL Input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Server URL")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    
                    TextField("https://demo.serviceradar.cloud", text: $settings.apiURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                }
                
                // Username Input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Username")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    
                    TextField("operator@serviceradar.com", text: $settings.backendUsername)
                        .autocapitalization(.none)
                        .keyboardType(.emailAddress)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                }
                
                // Password Input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Password")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    
                    SecureField("Enter Password", text: $settings.backendPassword)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    
                    Text("Password is saved in the iOS Keychain on this phone.")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                
                if let error = errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 5)
                }
            }
            .padding(.horizontal, 30)
            
            // Login Buttons
            VStack(spacing: 12) {
                Button(action: {
                    authenticate()
                }) {
                    HStack {
                        if isAuthenticating {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("Connect to Gateway")
                                .fontWeight(.bold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.black)
                    .cornerRadius(12)
                }
                .disabled(isAuthenticating || !loginFormIsReady)

                Button(action: {
                    showSettings = true
                }) {
                    Text("Settings")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray5))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(isAuthenticating)
                
                Button(action: {
                    settings.setOfflineMode()
                }) {
                    Text("Work Offline")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray6))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(isAuthenticating)
            }
            .padding(.horizontal, 30)
            .padding(.top, 10)
            
            Spacer().frame(height: 40)
        }
        .padding(.vertical)
        }
        .preferredColorScheme(.dark)
        .background(Color.black.edgesIgnoringSafeArea(.all))
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private var loginFormIsReady: Bool {
        !settings.apiURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !settings.backendUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !settings.backendPassword.isEmpty
    }
    
    private func authenticate() {
        isAuthenticating = true
        errorMessage = nil
        
        let cleanedURL = settings.apiURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let username = settings.backendUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = settings.backendPassword
        guard let url = URL(string: "\(cleanedURL)/oauth/token") else {
            errorMessage = "Invalid Server URL format."
            isAuthenticating = false
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        request.httpBody = formEncoded([
            "grant_type": "password",
            "username": username,
            "password": password,
            "scope": "read write"
        ])
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                self.isAuthenticating = false
                
                if let error = error {
                    self.errorMessage = "Connection error: \(error.localizedDescription)"
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    self.errorMessage = "Invalid server response."
                    return
                }
                
                if httpResponse.statusCode == 200, let data = data {
                    do {
                        if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                           let token = json["access_token"] as? String {
                            self.settings.setAuthenticated(apiURL: cleanedURL, token: token, username: username)
                        } else {
                            self.errorMessage = "Invalid token format received."
                        }
                    } catch {
                        self.errorMessage = "Failed to parse authentication response."
                    }
                } else if httpResponse.statusCode == 401 {
                    self.errorMessage = "Invalid Username or Password."
                } else {
                    self.errorMessage = "Server returned error \(httpResponse.statusCode)."
                }
            }
        }.resume()
    }

    private func formEncoded(_ parameters: [String: String]) -> Data? {
        parameters
            .map { key, value in
                "\(formEscape(key))=\(formEscape(value))"
            }
            .joined(separator: "&")
            .data(using: .utf8)
    }

    private func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
#endif
