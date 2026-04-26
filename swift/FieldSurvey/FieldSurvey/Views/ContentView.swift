#if os(iOS)
import SwiftUI
import RoomPlan
import simd
import ARKit
import SceneKit
import UIKit
import Combine

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
    private let autosaveTimer = Timer.publish(every: 6.0, on: .main, in: .common).autoconnect()
    
    // Core Pipeline Instantiation for God-View Ingestion
    private let arrowStreamer = ArrowStreamer()
    
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
            CompositeSurveyView(
                roomScanner: roomScanner,
                wifiScanner: wifiScanner,
                isMapView: $isMapView
            )
                .edgesIgnoringSafeArea(.all)
            
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
                        
                        Text(isMapView ? "Signal Map" : "LiDAR / AR Mode")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .opacity(0.8)

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

                        Button(action: {
                            isMapView.toggle()
                        }) {
                            Image(systemName: isMapView ? "arkit" : "map.fill")
                                .font(.system(size: 24))
                                .foregroundColor(isMapView ? .cyan : .white)
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
                }
                .padding(.bottom, 40)
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
                currentPose: wifiScanner.currentDevicePose,
                rfBatchCount: sidekickRelay.rfBatchCount,
                spectrumBatchCount: sidekickRelay.spectrumBatchCount,
                spectrumSummary: currentSpectrumSummary,
                spectrumSummaries: currentSpectrumSummaries,
                sidekickStatus: sidekickRelay.status,
                sidekickError: sidekickRelay.lastError,
                sidekickWarning: sidekickRelay.spectrumWarning
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
            applyRFState(settings.rfScanningEnabled)
            beginAutosaveSession()
            checkpointSession(includeMesh: false, showStatus: false)
            startOfflineSidekickPreviewIfNeeded()
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
            applyRFState(enabled)
        }
        .onReceive(autosaveTimer) { _ in
            checkpointSession(includeMesh: false, showStatus: false)
            refreshRecoveredSnapshot()
        }
        .onChange(of: wifiScanner.heatmapPoints.count) { _, count in
            guard count > 0, count % 5 == 0 else { return }
            checkpointSession(includeMesh: false, showStatus: false)
        }
    }

    private func startSidekickPreview() {
        beginAutosaveSession()
        checkpointSession(includeMesh: false, showStatus: false)
        isSidekickPreviewing = true
        sessionID = autosaveSessionID ?? UUID().uuidString
        sidekickRelay.start(
            sessionID: sessionID,
            wifiScanner: wifiScanner,
            forwardToBackend: false
        )
    }

    private func startBackendStreaming() {
        beginAutosaveSession()
        checkpointSession(includeMesh: false, showStatus: false)
        isStreaming = true
        sessionID = autosaveSessionID ?? UUID().uuidString
        wifiScanner.startPoseStreaming(sessionID: sessionID)
        sidekickRelay.start(
            sessionID: sessionID,
            wifiScanner: wifiScanner,
            forwardToBackend: true
        )
    }

    private func stopStreamingPipeline() {
        checkpointSession(includeMesh: true, showStatus: false)
        wifiScanner.stopPoseStreaming()
        sidekickRelay.stop()
        isStreaming = false
        isSidekickPreviewing = false
    }

    private func stopSidekickPreview() {
        checkpointSession(includeMesh: true, showStatus: false)
        sidekickRelay.stop()
        isSidekickPreviewing = false
        if settings.rfScanningEnabled {
            wifiScanner.startScanning()
        }
    }

    private func stopSidekickForLifecycle() {
        guard isStreaming || isSidekickPreviewing else { return }
        checkpointSession(includeMesh: true, showStatus: false)
        wifiScanner.stopPoseStreaming()
        sidekickRelay.stop()
        isStreaming = false
        isSidekickPreviewing = false
    }

    private func applyRFState(_ enabled: Bool) {
        wifiScanner.setRFScanning(enabled: enabled)
        if enabled {
            SubnetScanner.shared.startScanning()
        } else {
            SubnetScanner.shared.stopScanning()
        }
    }

    private func startOfflineSidekickPreviewIfNeeded() {
        guard settings.rfScanningEnabled, !backendStreamingEnabled, !isSidekickPreviewing else { return }
        startSidekickPreview()
    }

    private var backendStreamingEnabled: Bool {
        settings.authToken != "OFFLINE_MODE"
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

        do {
            let record = try sessionStore.autosaveCurrentSession(
                id: autosaveSessionID,
                name: autosaveSessionName,
                roomScanner: roomScanner,
                wifiScanner: wifiScanner,
                spectrumSummaries: sidekickRelay.spectrumSummaries,
                includeMesh: includeMesh
            )
            autosaveSessionName = record.name
            recoveredSnapshot = sessionStore.loadSession(id: autosaveSessionID)
            if showStatus {
                saveStatusMessage = includeMesh ? "Checkpoint saved: \(record.name)" : "Autosaved: \(record.name)"
                clearSaveStatus(after: 2.6)
            }
        } catch {
            if showStatus {
                saveStatusMessage = "Autosave failed: \(error.localizedDescription)"
                clearSaveStatus(after: 3.5)
            }
        }
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
        if !wifiScanner.manualAPLandmarks.isEmpty {
            return wifiScanner.manualAPLandmarks
        }
        return recoveredSnapshot?.manualLandmarks ?? []
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
    }

    private func refreshRecoveredSnapshot() {
        guard let autosaveSessionID else { return }
        recoveredSnapshot = sessionStore.loadSession(id: autosaveSessionID)
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
    
    @State private var serverURL: String = SettingsManager.shared.apiURL
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isAuthenticating: Bool = false
    @State private var errorMessage: String?
    
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
                    
                    TextField("https://demo.serviceradar.cloud", text: $serverURL)
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
                    
                    TextField("operator@serviceradar.com", text: $username)
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
                    
                    SecureField("Enter Password", text: $password)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
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
                .disabled(isAuthenticating || username.isEmpty || password.isEmpty || serverURL.isEmpty)
                
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
    }
    
    private func authenticate() {
        isAuthenticating = true
        errorMessage = nil
        
        let cleanedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(cleanedURL)/oauth/token") else {
            errorMessage = "Invalid Server URL format."
            isAuthenticating = false
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        // Use standard password grant
        let parameters = "grant_type=password&username=\(username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&password=\(password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        request.httpBody = parameters.data(using: .utf8)
        
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
                            self.settings.apiURL = cleanedURL
                            self.settings.authToken = token
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
}
#endif
