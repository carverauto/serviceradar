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

    func testAPPositionLocalizerUsesStrongestClusterAndPathDiversity() throws {
        let localizer = APPositionLocalizer()
        let accessPoint = SIMD3<Float>(3.4, 0.0, 1.2)
        var resolved: APResolvedLocation?

        for xStep in 0..<5 {
            for zStep in 0..<5 {
                let position = SIMD3<Float>(
                    Float(xStep) * 1.1 - 1.6,
                    0.0,
                    Float(zStep) * 1.0 - 1.8
                )
                let distance = max(Double(simd_distance(position, accessPoint)), 0.5)
                let rssi = -45.0 - 18.0 * log10(distance)
                resolved = localizer.addObservation(
                    APPositionObservation(
                        timestamp: Double(xStep * 10 + zStep),
                        bssid: "aa:bb:cc:dd:ee:ff",
                        frequencyMHz: 5180,
                        rssi: rssi,
                        scannerPosition: position
                    )
                )
            }
        }

        let estimate = try XCTUnwrap(resolved)
        XCTAssertGreaterThan(estimate.confidence, 0.25)
        XCTAssertGreaterThan(estimate.pathDiversityScore, 0.35)
        XCTAssertLessThan(simd_distance(estimate.position, accessPoint), 2.0)
        XCTAssertGreaterThan(estimate.strongestRSSI, -60.0)
    }
}
