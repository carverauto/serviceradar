import XCTest
@testable import FieldSurvey

final class SettingsManagerTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "scannerDeviceId")
    }

    @MainActor
    func testDefaultValuesAndPersistence() {
        let manager = SettingsManager.shared

        let id = manager.scannerDeviceId
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "scannerDeviceId"), id)
    }
}
