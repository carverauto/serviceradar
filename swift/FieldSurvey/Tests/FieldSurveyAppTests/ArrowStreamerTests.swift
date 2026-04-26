import XCTest
import simd
@testable import FieldSurvey

final class ArrowStreamerTests: XCTestCase {
    
    @MainActor
    func testArrowEncoding() throws {
        let streamer = ArrowStreamer()
        
        let sample = SurveySample(
            scannerDeviceId: "test-device",
            bssid: "00:00:00:00:00:00",
            ssid: "TestNet",
            rssi: -45.0,
            frequency: 5180,
            securityType: "WPA3",
            isSecure: true,
            rfVector: [-45.0, -55.0],
            position: simd_float3(1.0, 2.0, 3.0),
            uncertainty: 0.1
        )
        
        // Ensure encoding does not throw an error and returns non-empty data
        let encodedData = try streamer.encodeBatch(samples: [sample])
        XCTAssertGreaterThan(encodedData.count, 0)
        
        // Ensure compression does not throw
        let url = try streamer.compressForOfflineUpload(payload: encodedData, filename: "test_batch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        
        // Cleanup temp file
        try? FileManager.default.removeItem(at: url)
    }
}
