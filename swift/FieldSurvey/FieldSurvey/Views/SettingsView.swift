#if os(iOS)
import SwiftUI
import UIKit
import RPerfClient

@available(iOS 16.0, *)
public struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var settingsManager = SettingsManager.shared
    
    @State private var isTesting = false
    @State private var testResult: RPerfResult? = nil
    @State private var testError: String? = nil
    @State private var sidekickUplinkPassword = ""
    @State private var isConfiguringSidekickUplink = false
    @State private var sidekickUplinkResult: String? = nil
    @State private var isStoppingSidekickCapture = false
    @State private var sidekickCaptureResult: String? = nil
    @State private var isPairingSidekick = false
    @State private var sidekickPairingResult: String? = nil
    
    public var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Data Ingestion Pipeline")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable RF Scanning", isOn: $settingsManager.rfScanningEnabled)
                            .font(.headline)
                            .toggleStyle(SwitchToggleStyle(tint: .green))
                        
                        Text("Master on/off for Wi-Fi, Sidekick RF, and subnet sampling. Disable this to keep LiDAR mapping active without gathering RF telemetry.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Render Wi-Fi Heatmap", isOn: $settingsManager.showWiFiHeatmap)
                            .font(.headline)
                            .toggleStyle(SwitchToggleStyle(tint: .green))

                        Text("Shows a live signal-intensity heatmap built from your walk path and RSSI samples (connected/AP-visible telemetry).")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("AR Priority Mode", isOn: $settingsManager.arPriorityModeEnabled)
                            .font(.headline)
                            .toggleStyle(SwitchToggleStyle(tint: .green))

                        Text("When AR tracking degrades, temporarily pauses Sidekick preview and subnet background work to keep LiDAR world tracking stable, then resumes automatically.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 8)
                }

                Section(header: Text("FieldSurvey Sidekick")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sidekick URL")
                            .font(.headline)
                        TextField("http://fieldsurvey-rpi.local:17321", text: $settingsManager.sidekickURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    .padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sidekick Token")
                            .font(.headline)
                        SecureField("Bearer token", text: $settingsManager.sidekickAuthToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(isPairingSidekick ? "Pairing..." : "Pair Sidekick") {
                            Task {
                                await pairSidekick()
                            }
                        }
                        .disabled(isPairingSidekick || settingsManager.sidekickAuthToken.isEmpty)

                        if let sidekickPairingResult {
                            Text(sidekickPairingResult)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Radio Plan")
                            .font(.headline)
                        TextField("auto or wlan1:2412|2437|2462,wlan2:5180|5200", text: $settingsManager.sidekickRadioConfig)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("Use auto to scan with all monitor-capable USB radios, assigning the fastest adapter to 5 GHz and the next adapter to 2.4 GHz, or set explicit interface:frequency pairs.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Button(isStoppingSidekickCapture ? "Stopping Capture..." : "Stop Sidekick Capture") {
                            Task {
                                await stopSidekickCapture()
                            }
                        }
                        .disabled(isStoppingSidekickCapture)

                        if let sidekickCaptureResult {
                            Text(sidekickCaptureResult)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pi Wi-Fi Uplink")
                            .font(.headline)
                        TextField("Interface", text: $settingsManager.sidekickUplinkInterface)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("SSID", text: $settingsManager.sidekickUplinkSSID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $sidekickUplinkPassword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Country", text: $settingsManager.sidekickUplinkCountryCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()

                        HStack {
                            Button("Check Plan") {
                                Task {
                                    await configureSidekickUplink(dryRun: true)
                                }
                            }
                            .disabled(isConfiguringSidekickUplink || settingsManager.sidekickUplinkSSID.isEmpty)

                            Spacer()

                            Button("Apply") {
                                Task {
                                    await configureSidekickUplink(dryRun: false)
                                }
                            }
                            .disabled(isConfiguringSidekickUplink || settingsManager.sidekickUplinkSSID.isEmpty)
                        }

                        if isConfiguringSidekickUplink {
                            ProgressView()
                        } else if let sidekickUplinkResult {
                            Text(sidekickUplinkResult)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(.vertical, 8)

                    Toggle("Stream HackRF Spectrum", isOn: $settingsManager.sidekickSpectrumEnabled)
                        .font(.headline)
                        .toggleStyle(SwitchToggleStyle(tint: .green))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("HackRF Serial")
                            .font(.headline)
                        TextField("optional serial", text: $settingsManager.sidekickSpectrumSerialNumber)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.vertical, 8)

                    Stepper(
                        "Spectrum Range: \(settingsManager.sidekickSpectrumMinMHz)-\(settingsManager.sidekickSpectrumMaxMHz) MHz",
                        value: $settingsManager.sidekickSpectrumMinMHz,
                        in: 1...7250,
                        step: 1
                    )

                    Stepper(
                        "Spectrum Stop: \(settingsManager.sidekickSpectrumMaxMHz) MHz",
                        value: $settingsManager.sidekickSpectrumMaxMHz,
                        in: 1...7250,
                        step: 1
                    )

                    Stepper(
                        "Bin Width: \(settingsManager.sidekickSpectrumBinWidthHz) Hz",
                        value: $settingsManager.sidekickSpectrumBinWidthHz,
                        in: 2_445...5_000_000,
                        step: 10_000
                    )

                    Stepper(
                        "LNA Gain: \(settingsManager.sidekickSpectrumLNAGainDB) dB",
                        value: $settingsManager.sidekickSpectrumLNAGainDB,
                        in: 0...40,
                        step: 8
                    )

                    Stepper(
                        "VGA Gain: \(settingsManager.sidekickSpectrumVGAGainDB) dB",
                        value: $settingsManager.sidekickSpectrumVGAGainDB,
                        in: 0...62,
                        step: 2
                    )
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

    private func configureSidekickUplink(dryRun: Bool) async {
        isConfiguringSidekickUplink = true
        sidekickUplinkResult = nil

        let client = SidekickClient(settings: settingsManager)
        let request = SidekickWifiUplinkRequest(
            interfaceName: settingsManager.sidekickUplinkInterface,
            ssid: settingsManager.sidekickUplinkSSID,
            psk: sidekickUplinkPassword.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            countryCode: settingsManager.sidekickUplinkCountryCode.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            dryRun: dryRun
        )

        do {
            if dryRun {
                let response = try await client.wifiUplinkPlan(request)
                sidekickUplinkResult = "Plan has \(response.plan.commands.count) commands."
            } else {
                let response = try await client.configureWifiUplink(request)
                let failures = response.result.executions.filter { !$0.success }
                sidekickUplinkResult = failures.isEmpty
                    ? "Applied uplink config for \(settingsManager.sidekickUplinkSSID)."
                    : "Uplink command failed: \(failures.first?.stderr ?? "unknown error")"
            }
        } catch {
            sidekickUplinkResult = error.localizedDescription
        }

        isConfiguringSidekickUplink = false
    }

    private func stopSidekickCapture() async {
        isStoppingSidekickCapture = true
        sidekickCaptureResult = nil

        do {
            let response = try await SidekickClient(settings: settingsManager).stopCapture()
            sidekickCaptureResult = response.stopped
                ? "Stop signal sent."
                : "No active capture stopped."
        } catch {
            sidekickCaptureResult = error.localizedDescription
        }

        isStoppingSidekickCapture = false
    }

    private func pairSidekick() async {
        isPairingSidekick = true
        sidekickPairingResult = nil

        do {
            let response = try await SidekickClient(settings: settingsManager).claimPairing(
                SidekickPairingClaimRequest(
                    deviceID: settingsManager.scannerDeviceId,
                    deviceName: UIDevice.current.name.nilIfBlank
                )
            )
            settingsManager.sidekickAuthToken = response.token
            sidekickPairingResult = "Paired \(response.deviceName ?? response.deviceID)."
        } catch {
            sidekickPairingResult = error.localizedDescription
        }

        isPairingSidekick = false
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
