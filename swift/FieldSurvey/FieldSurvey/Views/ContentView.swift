#if os(iOS)
import SwiftUI
import RoomPlan
import simd
import ARKit
import SceneKit
import UIKit

@available(iOS 16.0, *)
public struct SurveyView: View {
    @ObservedObject public var roomScanner: RoomScanner
    @ObservedObject public var wifiScanner: RealWiFiScanner
    @ObservedObject public var sessionStore: SurveySessionStore
    @ObservedObject private var settings = SettingsManager.shared
    @StateObject private var networkMonitor = NetworkMonitor()
    public var onExit: (() -> Void)?
    
    @State private var isStreaming = false
    @State private var showSettings = false
    @State private var showSessionLibrary = false
    @State private var showSubnetIntel = false
    @State private var showAPIntel = false
    @State private var isMapView = false
    @State private var sessionID: String = UUID().uuidString
    @State private var pendingAPCandidate: APLabelCandidate?
    @State private var showSavePrompt = false
    @State private var saveSessionName: String = ""
    @State private var saveStatusMessage: String?
    @State private var isExportingOfflineBundle = false
    
    // Core Pipeline Instantiation for God-View Ingestion
    private let arrowStreamer = ArrowStreamer()
    
    public init(
        roomScanner: RoomScanner,
        wifiScanner: RealWiFiScanner,
        sessionStore: SurveySessionStore,
        onExit: (() -> Void)? = nil
    ) {
        self.roomScanner = roomScanner
        self.wifiScanner = wifiScanner
        self.sessionStore = sessionStore
        self.onExit = onExit
    }

    public var body: some View {
        ZStack {
            CompositeSurveyView(
                roomScanner: roomScanner,
                wifiScanner: wifiScanner,
                isMapView: $isMapView
            ) { candidate in
                if candidate.source == .tapAssist {
                    pendingAPCandidate = candidate
                }
            }
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                if settings.authToken == "OFFLINE_MODE" {
                    Text("Real-time streaming is not available in Offline Mode")
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
                        
                        Text(isMapView ? "Wi-Fi Space Mode" : "LiDAR / AR Mode")
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
                        showSavePrompt = true
                    }) {
                        Text("Save Session")
                            .fontWeight(.bold)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.cyan.opacity(0.85))
                            .foregroundColor(.black)
                            .cornerRadius(25)
                    }

                    Button(action: {
                        isStreaming.toggle()
                        if isStreaming {
                            sessionID = UUID().uuidString
                            arrowStreamer.connect(sessionID: sessionID)
                        } else {
                            arrowStreamer.disconnect()
                        }
                    }) {
                        Text(isStreaming ? "Stop Live Stream" : "Stream to God-View")
                            .fontWeight(.bold)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(isStreaming ? Color.red.opacity(0.8) : Color.green.opacity(0.8))
                            .foregroundColor(isStreaming ? .white : .black)
                            .cornerRadius(25)
                    }
                    .disabled(settings.authToken == "OFFLINE_MODE")
                    .opacity(settings.authToken == "OFFLINE_MODE" ? 0.5 : 1.0)
                    
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
            SettingsView(wifiScanner: wifiScanner)
        }
        .sheet(isPresented: $showSessionLibrary) {
            SessionLibraryView(
                roomScanner: roomScanner,
                wifiScanner: wifiScanner,
                sessionStore: sessionStore
            )
        }
        .sheet(isPresented: $showSubnetIntel) {
            SubnetIntelView()
        }
        .sheet(isPresented: $showAPIntel) {
            APIntelView(wifiScanner: wifiScanner)
        }
        .sheet(item: $pendingAPCandidate) { candidate in
            APLabelPromptSheet(
                initialLabel: candidate.suggestedLabel,
                confidence: candidate.confidence
            ) { confirmedLabel in
                wifiScanner.addManualAccessPoint(
                    label: confirmedLabel,
                    position: candidate.worldPosition,
                    confidence: candidate.confidence,
                    source: candidate.source.rawValue
                )
            }
        }
        .alert("Save Survey Session", isPresented: $showSavePrompt) {
            TextField("Session name (optional)", text: $saveSessionName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                saveSession()
            }
        } message: {
            Text("This captures the current RF heatmap, AP labels, roam transitions, and LiDAR room mesh.")
        }
        // Lifecycle Hooks for Core Location / Network Extension / MobileWiFi
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            applyRFState(settings.rfScanningEnabled)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            wifiScanner.stopScanning(clearData: false)
            BLEScanner.shared.stopScanning()
            SubnetScanner.shared.stopScanning()
            if isStreaming {
                arrowStreamer.disconnect()
                isStreaming = false
            }
        }
        .onChange(of: settings.rfScanningEnabled) { enabled in
            applyRFState(enabled)
        }
        .onChange(of: settings.showBLEBeacons) { showBLE in
            wifiScanner.setBLEIngestionEnabled(showBLE)
            if settings.rfScanningEnabled {
                if showBLE {
                    BLEScanner.shared.startScanning()
                } else {
                    BLEScanner.shared.stopScanning()
                }
            }
        }
        // Continuous Zero-Copy Ingestion Flow
        .onChange(of: wifiScanner.accessPoints) { _ in
            guard isStreaming else { return }
            
            let currentSamples = Array(wifiScanner.accessPoints.values)
            guard !currentSamples.isEmpty else { return }
            
            DispatchQueue.global(qos: .userInitiated).async {
                if let payload = try? arrowStreamer.encodeBatch(samples: currentSamples) {
                    // Fire IPC payload across the persistent WebSocket connection
                    arrowStreamer.streamToBackend(payload: payload, sessionID: sessionID)
                }
            }
        }
    }

    private func applyRFState(_ enabled: Bool) {
        wifiScanner.setRFScanning(enabled: enabled)
        if enabled {
            if settings.showBLEBeacons {
                BLEScanner.shared.startScanning()
            } else {
                BLEScanner.shared.stopScanning()
                wifiScanner.setBLEIngestionEnabled(false)
            }
            SubnetScanner.shared.startScanning()
        } else {
            BLEScanner.shared.stopScanning()
            SubnetScanner.shared.stopScanning()
        }
    }

    private func saveSession() {
        do {
            let record = try sessionStore.saveCurrentSession(
                name: saveSessionName,
                roomScanner: roomScanner,
                wifiScanner: wifiScanner
            )
            saveSessionName = ""
            saveStatusMessage = "Saved: \(record.name)"
        } catch {
            saveStatusMessage = "Save failed: \(error.localizedDescription)"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
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
}

@available(iOS 16.0, *)
private struct APLabelPromptSheet: View {
    @Environment(\.dismiss) var dismiss

    @State private var label: String
    let confidence: Double
    let onSave: (String) -> Void

    init(initialLabel: String, confidence: Double, onSave: @escaping (String) -> Void) {
        _label = State(initialValue: initialLabel)
        self.confidence = confidence
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("AI Candidate")) {
                    TextField("Access Point Label", text: $label)
                        .textInputAutocapitalization(.words)
                    Text("Confidence: \(Int(confidence * 100))%")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .navigationTitle("Label Access Point")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(label)
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
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
                    settings.apiURL = "offline"
                    settings.authToken = "OFFLINE_MODE"
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
