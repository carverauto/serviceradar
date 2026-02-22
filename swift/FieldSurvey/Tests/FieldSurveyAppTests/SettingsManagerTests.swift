import XCTest
@testable import FieldSurveyApp

final class SettingsManagerTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Clear out UserDefaults for a clean state
        UserDefaults.standard.removeObject(forKey: "sampleRateSeconds")
        UserDefaults.standard.removeObject(forKey: "scannerDeviceId")
    }

    func testDefaultValuesAndPersistence() {
        let manager = SettingsManager.shared
        
        // Due to the singleton nature, we just test that it persists what we set
        manager.sampleRateSeconds = 2.5
        
        XCTAssertEqual(UserDefaults.standard.double(forKey: "sampleRateSeconds"), 2.5)
        
        let id = manager.scannerDeviceId
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "scannerDeviceId"), id)
    }
}
