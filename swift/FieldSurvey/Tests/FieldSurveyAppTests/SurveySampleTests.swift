import XCTest
import simd
@testable import FieldSurvey

final class SurveySampleTests: XCTestCase {
    func testInitializationAndDistance() {
        let sample = SurveySample(
            scannerDeviceId: "test-device-id",
            bssid: "00:11:22:33:44:55",
            ssid: "Test_SSID",
            rssi: -50.0,
            frequency: 5180,
            securityType: "WPA2",
            isSecure: true,
            rfVector: [-50.0, -60.0, -70.0],
            position: simd_float3(1.0, 2.0, 3.0),
            uncertainty: 0.1
        )
        
        XCTAssertEqual(sample.scannerDeviceId, "test-device-id")
        XCTAssertEqual(sample.bssid, "00:11:22:33:44:55")
        XCTAssertEqual(sample.ssid, "Test_SSID")
        XCTAssertEqual(sample.rssi, -50.0)
        XCTAssertEqual(sample.frequency, 5180)
        XCTAssertEqual(sample.securityType, "WPA2")
        XCTAssertTrue(sample.isSecure)
        XCTAssertEqual(sample.rfVector.count, SurveySample.rfVectorDimensions)
        XCTAssertEqual(Array(sample.rfVector.prefix(3)), [-50.0, -60.0, -70.0])
        XCTAssertEqual(sample.rfVector.last, SurveySample.missingSignalValue)
        XCTAssertEqual(sample.x, 1.0)
        XCTAssertEqual(sample.y, 2.0)
        XCTAssertEqual(sample.z, 3.0)
        XCTAssertEqual(sample.uncertainty, 0.1)
    }
}
