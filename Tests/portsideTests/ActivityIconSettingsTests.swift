import XCTest
@testable import portside

final class ActivityIconSettingsTests: XCTestCase {
    func testAudioWorkstationsAreAlwaysMeasured() throws {
        let fresh = ActivityIconSettings()
        XCTAssertFalse(fresh.measureAudioPlayback, "measuring every app stays opt-in")
        XCTAssertTrue(fresh.measuredApps.contains("com.ableton.live"))
        let old = try JSONDecoder().decode(ActivityIconSettings.self, from: Data(#"{"audio":true}"#.utf8))
        XCTAssertEqual(old.measuredApps, ActivityIconSettings.defaultMeasuredApps, "a file from before the list gets the defaults")
        var custom = ActivityIconSettings()
        custom.measuredApps = ["com.example.daw"]
        let restored = try JSONDecoder().decode(ActivityIconSettings.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(restored.measuredApps, ["com.example.daw"])
    }
}
