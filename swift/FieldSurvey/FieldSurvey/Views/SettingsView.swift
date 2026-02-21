#if os(iOS)
import SwiftUI
import RPerfClient

@available(iOS 16.0, *)
public struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var settingsManager = SettingsManager.shared
    @ObservedObject var wifiScanner: RealWiFiScanner
    
    @State private var isTesting = false
    @State private var testResult: RPerfResult? = nil
    @State private var testError: String? = nil
    
    public init(wifiScanner: RealWiFiScanner) {
        self.wifiScanner = wifiScanner
    }
    
    public var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Data Ingestion Pipeline")) {
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Show BLE Beacons in Map", isOn: $settingsManager.showBLEBeacons)
                            .font(.headline)
                            .toggleStyle(SwitchToggleStyle(tint: .green))
                        
                        Text("When disabled, only true 802.11 Wi-Fi access points will be drawn in the AR/3D map. When enabled, BLE polyfill data is also drawn. Turn off to reduce visual clutter from laptops and phones.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 8)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RF Polling Resolution: \(String(format: "%.1f", settingsManager.sampleRateSeconds))s")
                            .font(.headline)
                        
                        Text("Determines how frequently the app polls the network hardware and constructs Arrow IPC frames. Lower values provide higher data fidelity for the God-View spatial join engine, at the cost of device battery.")
                            .font(.caption)
                            .foregroundColor(.gray)
                        
                        Slider(value: $settingsManager.sampleRateSeconds, in: 0.1...5.0, step: 0.1) { editing in
                            if !editing {
                                // Restart scanner with new rate immediately if it was already running
                                if wifiScanner.isScanning {
                                    wifiScanner.stopScanning()
                                    wifiScanner.startScanning()
                                }
                            }
                        }
                        .accentColor(.green)
                    }
                    .padding(.vertical, 8)
                }
                
                Section(header: Text("Active Throughput Testing (rperf)")) {
                    Button(action: {
                        Task {
                            await runThroughputTest()
                        }
                    }) {
                        HStack {
                            Text(isTesting ? "Running RPerf Test..." : "Run Active Test")
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)
                    
                    if let result = testResult {
                        if result.success {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Throughput: \(String(format: "%.2f", result.summary.bits_per_second / 1_000_000)) Mbps")
                                Text("Duration: \(String(format: "%.1f", result.summary.duration))s")
                                Text("Data Exchanged: \(result.summary.bytes_received > 0 ? result.summary.bytes_received : result.summary.bytes_sent) bytes")
                            }
                            .font(.caption)
                        } else {
                            Text("Error: \(result.error ?? "Unknown")")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    } else if let error = testError {
                        Text("Error: \(error)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("FieldSurvey Settings")
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
        }
        .preferredColorScheme(.dark)
    }
    
    private func runThroughputTest() async {
        isTesting = true
        testError = nil
        testResult = nil
        
        let hostUrl = settingsManager.apiURL.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").components(separatedBy: "/").first ?? "demo.serviceradar.cloud"
        
        let runner = RPerfRunner(
            targetAddress: hostUrl,
            port: 4000,
            testProtocol: .tcp,
            reverse: true, // Download from server
            bandwidth: 1_000_000_000,
            duration: 5.0,
            parallel: 4
        )
        
        do {
            let result = try await runner.runTest()
            DispatchQueue.main.async {
                self.testResult = result
                self.isTesting = false
            }
        } catch {
            DispatchQueue.main.async {
                self.testError = error.localizedDescription
                self.isTesting = false
            }
        }
    }
}
#endif
