import XCTest
import simd
@testable import FieldSurvey

final class SignalCoverageInterpolatorTests: XCTestCase {
    func testCoverageGridPredictsSignalBetweenMeasuredPoints() {
        let points = [
            heatPoint(x: 0.0, z: 0.0, rssi: -42.0),
            heatPoint(x: 1.0, z: 0.0, rssi: -47.0),
            heatPoint(x: 0.0, z: 1.0, rssi: -50.0),
            heatPoint(x: 1.0, z: 1.0, rssi: -54.0),
            heatPoint(x: 2.0, z: 1.0, rssi: -60.0)
        ]

        let grid = SignalCoverageInterpolator.coverageGrid(
            points: points,
            minX: 0.0,
            maxX: 2.0,
            minZ: 0.0,
            maxZ: 1.5,
            preferredCellSize: 0.5
        )

        XCTAssertFalse(grid.isEmpty)
        XCTAssertTrue(grid.allSatisfy { $0.rssi <= -20.0 && $0.rssi >= -100.0 })
        XCTAssertTrue(grid.contains { $0.confidence > 0.5 })
    }

    func testCoverageGridNeedsEnoughSamples() {
        let grid = SignalCoverageInterpolator.coverageGrid(
            points: [
                heatPoint(x: 0.0, z: 0.0, rssi: -45.0),
                heatPoint(x: 1.0, z: 0.0, rssi: -50.0)
            ],
            minX: 0.0,
            maxX: 1.0,
            minZ: 0.0,
            maxZ: 1.0
        )

        XCTAssertTrue(grid.isEmpty)
    }

    private func heatPoint(x: Float, z: Float, rssi: Double) -> WiFiHeatmapPoint {
        WiFiHeatmapPoint(
            timestamp: Date().timeIntervalSince1970,
            bssid: "aa:bb:cc:dd:ee:ff",
            ssid: "test",
            rssi: rssi,
            position: SIMD3<Float>(x, 0.0, z)
        )
    }
}
