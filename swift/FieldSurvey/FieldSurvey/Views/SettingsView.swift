#if os(iOS)
import SwiftUI

@available(iOS 16.0, *)
public struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var settingsManager = SettingsManager.shared
    @ObservedObject var wifiScanner: RealWiFiScanner
    
    public init(wifiScanner: RealWiFiScanner) {
        self.wifiScanner = wifiScanner
    }
    
    public var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Data Ingestion Pipeline")) {
                    
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
            }
            .navigationTitle("FieldSurvey Settings")
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
        }
        .preferredColorScheme(.dark)
    }
}
#endif
