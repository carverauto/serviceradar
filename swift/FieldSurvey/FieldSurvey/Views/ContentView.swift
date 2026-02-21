#if os(iOS)
import SwiftUI
import RoomPlan
import simd
import ARKit
import SceneKit

@available(iOS 16.0, *)
public struct SurveyView: View {
    @ObservedObject public var roomScanner: RoomScanner
    @ObservedObject public var wifiScanner: RealWiFiScanner
    @StateObject private var networkMonitor = NetworkMonitor()
    
    @State private var isStreaming = false
    @State private var showSettings = false
    @State private var isMapView = false
    @State private var sessionID: String = UUID().uuidString
    
    // Core Pipeline Instantiation for God-View Ingestion
    private let arrowStreamer = ArrowStreamer()
    
    public init(roomScanner: RoomScanner, wifiScanner: RealWiFiScanner) {
        self.roomScanner = roomScanner
        self.wifiScanner = wifiScanner
    }

    public var body: some View {
        ZStack {
            CompositeSurveyView(roomScanner: roomScanner, wifiScanner: wifiScanner, isMapView: $isMapView)
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                if SettingsManager.shared.authToken == "OFFLINE_MODE" {
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
                        
                        Text(isMapView ? "God-View Map Mode" : "Composite AR Mode")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .opacity(0.8)
                        
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
                
                // Pipeline Control Bar
                HStack(spacing: 20) {
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
                    .disabled(SettingsManager.shared.authToken == "OFFLINE_MODE")
                    .opacity(SettingsManager.shared.authToken == "OFFLINE_MODE" ? 0.5 : 1.0)
                    
                    Button(action: {
                        if let _ = try? roomScanner.exportUSDZ() {
                            // Offline sync via compressed native LZFSE + Arrow IPC buffer
                            let currentSamples = Array(wifiScanner.accessPoints.values)
                            if let payload = try? arrowStreamer.encodeBatch(samples: currentSamples) {
                                _ = try? arrowStreamer.compressForOfflineUpload(payload: payload, filename: "survey_bulk")
                            }
                        }
                    }) {
                        Image(systemName: "arrow.up.doc.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.black.opacity(0.7))
                            .clipShape(Circle())
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView(wifiScanner: wifiScanner)
        }
        // Lifecycle Hooks for Core Location / Network Extension / MobileWiFi
        .onAppear {
            wifiScanner.startScanning()
            BLEScanner.shared.startScanning()
        }
        .onDisappear {
            wifiScanner.stopScanning()
            BLEScanner.shared.stopScanning()
            if isStreaming {
                arrowStreamer.disconnect()
                isStreaming = false
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
}

@available(iOS 16.0, *)
public struct ContentView: View {
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var roomScanner = RoomScanner()
    @StateObject private var wifiScanner = RealWiFiScanner()
    
    public init() {}
    
    public var body: some View {
        Group {
            if settings.authToken.isEmpty {
                LoginView()
            } else {
                SurveyView(roomScanner: roomScanner, wifiScanner: wifiScanner)
                    .preferredColorScheme(.dark)
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