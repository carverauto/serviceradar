import XCTest
import Arrow
@testable import FieldSurvey

final class SidekickClientTests: XCTestCase {
    func testDecodesStatusResponse() throws {
        let payload = """
        {
          "service": "serviceradar-fieldsurvey-sidekick",
          "version": "0.1.0",
          "capture_running": false,
          "active_streams": [
            {
              "stream_id": "capture-1",
              "stream_type": "rf_observation",
              "target": "wlan2",
              "started_at_unix_secs": 1777132800
            }
          ],
          "iw_available": true,
          "radios": [
            {
              "name": "wlan2",
              "phy": "phy2",
              "driver": "mt76x2u",
              "mac_address": "00:11:22:33:44:55",
              "operstate": "up",
              "supported_modes": ["managed", "monitor"],
              "monitor_supported": true,
              "usb": {
                "speed_mbps": 5000,
                "version": "3.00",
                "manufacturer": "MediaTek Inc.",
                "product": "Wireless",
                "vendor_id": "0e8d",
                "product_id": "7612",
                "bus_path": "2-1"
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(SidekickStatusResponse.self, from: payload)

        XCTAssertEqual(status.service, "serviceradar-fieldsurvey-sidekick")
        XCTAssertEqual(status.radios.first?.name, "wlan2")
        XCTAssertEqual(status.radios.first?.driver, "mt76x2u")
        XCTAssertEqual(status.activeStreams.first?.target, "wlan2")
        XCTAssertEqual(status.activeStreams.first?.streamType, "rf_observation")
        XCTAssertTrue(status.radios.first?.monitorSupported ?? false)
        XCTAssertEqual(status.radios.first?.usb?.speedMbps, 5000)
    }

    func testEncodesMonitorPrepareRequest() throws {
        let request = SidekickMonitorPrepareRequest(interfaceName: "wlan2", frequencyMHz: 5180, dryRun: true)
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(object?["interface_name"] as? String, "wlan2")
        XCTAssertEqual(object?["frequency_mhz"] as? Int, 5180)
        XCTAssertEqual(object?["dry_run"] as? Bool, true)
    }

    func testParsesRadioFrequencyPlans() {
        let configs = SidekickRadioConfiguration.parseList("wlan1:2412|2437|2462,wlan2:5180|5200")

        XCTAssertEqual(configs.count, 2)
        XCTAssertEqual(configs[0].interfaceName, "wlan1")
        XCTAssertEqual(configs[0].frequenciesMHz, [2412, 2437, 2462])
        XCTAssertEqual(configs[1].interfaceName, "wlan2")
        XCTAssertEqual(configs[1].frequenciesMHz, [5180, 5200])
    }

    func testEncodesWifiUplinkRequest() throws {
        let request = SidekickWifiUplinkRequest(
            interfaceName: "wlan0",
            ssid: "LabNet",
            psk: "secret",
            countryCode: "US",
            dryRun: true
        )
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(object?["interface_name"] as? String, "wlan0")
        XCTAssertEqual(object?["ssid"] as? String, "LabNet")
        XCTAssertEqual(object?["psk"] as? String, "secret")
        XCTAssertEqual(object?["country_code"] as? String, "US")
        XCTAssertEqual(object?["dry_run"] as? Bool, true)
    }

    func testEncodesPairingClaimRequest() throws {
        let request = SidekickPairingClaimRequest(deviceID: "iphone-1", deviceName: "Survey Phone")
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(object?["device_id"] as? String, "iphone-1")
        XCTAssertEqual(object?["device_name"] as? String, "Survey Phone")
    }

    func testDecodesPairingClaimResponse() throws {
        let payload = """
        {
          "sidekick_id": "fieldsurvey-sidekick",
          "device_id": "iphone-1",
          "device_name": "Survey Phone",
          "token": "paired-token",
          "paired_at_unix_secs": 1777132800
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SidekickPairingClaimResponse.self, from: payload)

        XCTAssertEqual(response.sidekickID, "fieldsurvey-sidekick")
        XCTAssertEqual(response.deviceID, "iphone-1")
        XCTAssertEqual(response.deviceName, "Survey Phone")
        XCTAssertEqual(response.token, "paired-token")
        XCTAssertEqual(response.pairedAtUnixSecs, 1777132800)
    }

    func testNormalizesSidekickBaseURL() {
        XCTAssertEqual(
            SidekickClient.normalizedBaseURL(from: "192.168.1.77:17321")?.absoluteString,
            "http://192.168.1.77:17321"
        )
        XCTAssertEqual(
            SidekickClient.normalizedBaseURL(from: " ws://fieldsurvey-rpi.local:17321 ")?.absoluteString,
            "http://fieldsurvey-rpi.local:17321"
        )
    }

    func testSidekickClientErrorDescriptionsExposeDetails() {
        let authError = SidekickClientError.httpStatus(
            403,
            #"{"error":"pairing is disabled until api_token is configured"}"#
        )

        XCTAssertEqual(
            authError.localizedDescription,
            "Sidekick request failed with HTTP 403: pairing is disabled until api_token is configured"
        )
        XCTAssertEqual(
            SidekickClientError.invalidStreamURL.localizedDescription,
            "Sidekick stream URL is invalid. Use a URL like http://192.168.1.77:17321."
        )
    }

    func testAppliesFieldSurveySessionMetadataHeaders() throws {
        var request = URLRequest(url: URL(string: "https://demo.serviceradar.cloud/v1/field-survey/session/room-artifacts")!)
        let metadata = FieldSurveySessionUploadMetadata(
            siteID: "ord",
            siteName: "ORD",
            buildingID: "terminal-b",
            buildingName: "Terminal B",
            floorID: "level-2",
            floorName: "Level 2",
            floorIndex: 2,
            tags: ["airport", "ord"],
            metadata: ["session_name": "Survey A"]
        )

        FieldSurveyRoomArtifactUploader.applySessionMetadataHeaders(metadata, to: &request)

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-FieldSurvey-Site-Id"), "ord")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-FieldSurvey-Building-Name"), "Terminal B")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-FieldSurvey-Floor-Index"), "2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-FieldSurvey-Tags"), "airport,ord")
        let encoded = try XCTUnwrap(request.value(forHTTPHeaderField: "X-FieldSurvey-Session-Metadata"))
        let object = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: String]
        XCTAssertEqual(object?["session_name"], "Survey A")
    }

    func testDecodesRuntimeConfig() throws {
        let payload = """
        {
          "sidekick_id": "fieldsurvey-sidekick",
          "radio_plans": [
            {"interface_name": "wlan2", "frequencies_mhz": [5180, 5200], "hop_interval_ms": 250}
          ],
          "wifi_uplink": {
            "interface_name": "wlan0",
            "ssid": "LabNet",
            "country_code": "US",
            "psk_configured": true
          }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(SidekickRuntimeConfig.self, from: payload)

        XCTAssertEqual(config.sidekickID, "fieldsurvey-sidekick")
        XCTAssertEqual(config.radioPlans.first?.frequenciesMHz, [5180, 5200])
        XCTAssertEqual(config.wifiUplink?.ssid, "LabNet")
        XCTAssertTrue(config.wifiUplink?.pskConfigured ?? false)
    }

    func testDecodesObservation() throws {
        let payload = """
        {
          "sidekick_id": "sidekick-1",
          "radio_id": "radio-1",
          "interface_name": "wlan2",
          "bssid": "00:11:22:33:44:55",
          "ssid": "fieldlab",
          "hidden_ssid": false,
          "frame_type": "beacon",
          "rssi_dbm": -64,
          "noise_floor_dbm": -97,
          "snr_db": 33,
          "frequency_mhz": 5180,
          "channel": 36,
          "channel_width_mhz": null,
          "captured_at_unix_nanos": 1777132800000000000,
          "captured_at_monotonic_nanos": 9876543210,
          "parser_confidence": 0.9
        }
        """.data(using: .utf8)!

        let observation = try JSONDecoder().decode(SidekickObservation.self, from: payload)

        XCTAssertEqual(observation.sidekickID, "sidekick-1")
        XCTAssertEqual(observation.ssid, "fieldlab")
        XCTAssertEqual(observation.rssiDBM, -64)
        XCTAssertEqual(observation.channel, 36)
        XCTAssertEqual(observation.snrDB, 33)
        XCTAssertEqual(observation.capturedAtUnixNanos, 1777132800000000000)
        XCTAssertEqual(observation.capturedAtMonotonicNanos, 9876543210)
    }

    func testDecodesSidekickObservationArrowStream() throws {
        let payload = try makeSidekickObservationArrowPayload()
        let observations = try SidekickObservationArrowDecoder().decode(payload)

        XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(observations[0].sidekickID, "fieldsurvey-sidekick")
        XCTAssertEqual(observations[0].radioID, "wlan2")
        XCTAssertEqual(observations[0].interfaceName, "wlan2")
        XCTAssertEqual(observations[0].bssid, "00:11:22:33:44:55")
        XCTAssertEqual(observations[0].ssid, "fieldlab")
        XCTAssertEqual(observations[0].rssiDBM, -58)
        XCTAssertEqual(observations[0].frequencyMHz, 5180)
        XCTAssertEqual(observations[0].channel, 36)
        XCTAssertEqual(observations[0].capturedAtUnixNanos, 1777132800000000000)
        XCTAssertEqual(observations[0].capturedAtMonotonicNanos, 9876543210)
        XCTAssertEqual(observations[1].ssid, nil)
        XCTAssertEqual(observations[1].hiddenSSID, true)
    }

    @MainActor
    func testIngestsSidekickObservationAsSurveySample() throws {
        let scanner = RealWiFiScanner()
        scanner.updateDevicePose(position: SIMD3<Float>(1.0, 2.0, 3.0))

        scanner.ingestSidekickObservations([
            SidekickObservation(
                sidekickID: "fieldsurvey-sidekick",
                radioID: "wlan2",
                interfaceName: "wlan2",
                bssid: "00:11:22:33:44:55",
                ssid: "fieldlab",
                hiddenSSID: false,
                frameType: "beacon",
                rssiDBM: -58,
                noiseFloorDBM: -96,
                snrDB: 38,
                frequencyMHz: 5180,
                channel: 36,
                channelWidthMHz: nil,
                capturedAtUnixNanos: 1777132800000000000,
                capturedAtMonotonicNanos: 9876543210,
                parserConfidence: 0.9
            )
        ])

        let sample = try XCTUnwrap(scanner.accessPoints["00:11:22:33:44:55"])
        XCTAssertEqual(sample.ssid, "fieldlab")
        XCTAssertEqual(sample.rssi, -58)
        XCTAssertEqual(sample.frequency, 5180)
        XCTAssertEqual(sample.securityType, "Sidekick beacon")
        XCTAssertEqual(sample.x, 1.0)
        XCTAssertEqual(sample.y, 2.0)
        XCTAssertEqual(sample.z, 3.0)
        XCTAssertEqual(scanner.heatmapPoints.last?.bssid, "00:11:22:33:44:55")
    }

    private func makeSidekickObservationArrowPayload() throws -> Data {
        let sidekickID = try ArrowArrayBuilders.loadStringArrayBuilder()
        let radioID = try ArrowArrayBuilders.loadStringArrayBuilder()
        let interfaceName = try ArrowArrayBuilders.loadStringArrayBuilder()
        let bssid = try ArrowArrayBuilders.loadStringArrayBuilder()
        let ssid = try ArrowArrayBuilders.loadStringArrayBuilder()
        let hiddenSSID = try ArrowArrayBuilders.loadBoolArrayBuilder()
        let frameType = try ArrowArrayBuilders.loadStringArrayBuilder()
        let rssi = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Int16>
        let noise = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Int16>
        let snr = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Int16>
        let frequency = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Int32>
        let channel = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Int32>
        let width = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Int32>
        let unixNanos = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Int64>
        let monoNanos = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Int64>
        let confidence = try ArrowArrayBuilders.loadNumberArrayBuilder() as NumberArrayBuilder<Double>

        sidekickID.append(["fieldsurvey-sidekick", "fieldsurvey-sidekick"])
        radioID.append(["wlan2", "wlan1"])
        interfaceName.append(["wlan2", "wlan1"])
        bssid.append(["00:11:22:33:44:55", "66:77:88:99:aa:bb"])
        ssid.append(["fieldlab", nil])
        hiddenSSID.append([false, true])
        frameType.append(["beacon", "probe_response"])
        rssi.append([-58, -67])
        noise.append([-96, nil])
        snr.append([38, nil])
        frequency.append([5180, 2412])
        channel.append([36, 1])
        width.append([nil, nil])
        unixNanos.append([1777132800000000000, 1777132801000000000])
        monoNanos.append([9876543210, nil])
        confidence.append([0.9, 0.8])

        let result = RecordBatch.Builder()
            .addColumn("sidekick_id", arrowArray: try sidekickID.toHolder())
            .addColumn("radio_id", arrowArray: try radioID.toHolder())
            .addColumn("interface_name", arrowArray: try interfaceName.toHolder())
            .addColumn("bssid", arrowArray: try bssid.toHolder())
            .addColumn("ssid", arrowArray: try ssid.toHolder())
            .addColumn("hidden_ssid", arrowArray: try hiddenSSID.toHolder())
            .addColumn("frame_type", arrowArray: try frameType.toHolder())
            .addColumn("rssi_dbm", arrowArray: try rssi.toHolder())
            .addColumn("noise_floor_dbm", arrowArray: try noise.toHolder())
            .addColumn("snr_db", arrowArray: try snr.toHolder())
            .addColumn("frequency_mhz", arrowArray: try frequency.toHolder())
            .addColumn("channel", arrowArray: try channel.toHolder())
            .addColumn("channel_width_mhz", arrowArray: try width.toHolder())
            .addColumn("captured_at_unix_nanos", arrowArray: try unixNanos.toHolder())
            .addColumn("captured_at_monotonic_nanos", arrowArray: try monoNanos.toHolder())
            .addColumn("parser_confidence", arrowArray: try confidence.toHolder())
            .finish()

        let batch: RecordBatch
        switch result {
        case .success(let recordBatch):
            batch = recordBatch
        case .failure(let error):
            throw error
        }

        let writerInfo = ArrowWriter.Info(.recordbatch, schema: batch.schema, batches: [batch])
        switch ArrowWriter().writeStreaming(writerInfo) {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }
}
