import SwiftUI
import RoomPlan
import simd
import ARKit

@available(iOS 16.0, *)
public struct ContentView: View {
    @StateObject private var roomScanner = RoomScanner()
    @StateObject private var wifiScanner = RealWiFiScanner()
    @StateObject private var networkMonitor = NetworkMonitor()
    
    @State private var showRoomPlan = false
    @State private var isStreaming = false
    @State private var showSettings = false
    @State private var sessionID: String = UUID().uuidString
    
    // Core Pipeline Instantiation for God-View Ingestion
    private let arrowStreamer = ArrowStreamer()
    
    public init() {}

    public var body: some View {
        ZStack {
            if showRoomPlan {
                RoomCaptureViewContainer(scanner: roomScanner)
                    .edgesIgnoringSafeArea(.all)
            } else {
                ARRealityView(scanner: wifiScanner)
                    .edgesIgnoringSafeArea(.all)
            }
            
            VStack {
                HStack {
                    VStack(alignment: .leading) {
                        Text("ServiceRadar FieldSurvey")
                            .font(.headline)
                            .foregroundColor(.green)
                            .shadow(color: .green, radius: 2, x: 0, y: 0)
                        
                        Text(showRoomPlan ? "LiDAR Mesh Mode" : "RF Scanning Mode")
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
                }
                .padding(.top, 40)
                .padding(.horizontal)
                
                Spacer()
                
                // Pipeline Control Bar
                HStack(spacing: 20) {
                    Button(action: {
                        showRoomPlan.toggle()
                    }) {
                        Image(systemName: showRoomPlan ? "cube.transparent" : "cube.transparent.fill")
                            .font(.system(size: 24))
                            .foregroundColor(showRoomPlan ? .green : .white)
                            .padding()
                            .background(Color.black.opacity(0.7))
                            .clipShape(Circle())
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
        }
        .onDisappear {
            wifiScanner.stopScanning()
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

// Wrapper for the RoomCaptureView to integrate with SwiftUI
@available(iOS 16.0, *)
public struct RoomCaptureViewContainer: UIViewRepresentable {
    let scanner: RoomScanner
    
    public func makeUIView(context: Context) -> RoomCaptureView {
        let captureView = RoomCaptureView(frame: .zero)
        scanner.startSession(in: captureView)
        return captureView
    }
    
    public func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
    
    public static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: ()) {
        uiView.captureSession.stop()
    }
}
