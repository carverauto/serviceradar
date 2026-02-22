import XCTest
import Combine
@testable import FieldSurveyApp

final class NetworkMonitorTests: XCTestCase {
    
    func testNetworkMonitorInitialization() {
        let monitor = NetworkMonitor()
        // It initializes to false on everything before path updates
        XCTAssertFalse(monitor.isConnected)
        XCTAssertFalse(monitor.isWiFi)
        XCTAssertFalse(monitor.isCellular)
        XCTAssertFalse(monitor.isEthernet)
    }
}
