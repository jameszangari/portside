import XCTest
@testable import portside

/// dock.json compatibility, checked by value rather than serialized text.
final class SettingsFixtureTests: XCTestCase {
    private let legacy = "legacy-flat-pins.json"

    func testLegacyFileMigratesOnLoad() throws {
        let model = try JSONDecoder().decode(DockModel.self, from: Fixture.data(legacy))

        XCTAssertEqual(model.entries, [
            .app(PinnedApp(bundleIdentifier: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app")),
            .app(PinnedApp(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app")),
            .app(PinnedApp(bundleIdentifier: nil, path: "/Applications/Unbundled Tool.app")),
        ])
        XCTAssertEqual(model.edge, .left)
        XCTAssertEqual(model.iconSize, 40)
        XCTAssertEqual(model.widgetKinds, ["clock"])
        XCTAssertFalse(model.hideNativeDock)
        // Out of range values clamp instead of failing the file.
        XCTAssertEqual(model.hideDelay, DockModel.hideDelayRange.upperBound)
        // A file from before auto-hide was optional keeps the old behavior.
        XCTAssertTrue(model.autoHide)
        XCTAssertEqual(model.settingsHotkey, .settingsDefault)
        // Older flat background keys become the per-style background.
        XCTAssertEqual(model.background.style, .solid)
        XCTAssertEqual(model.background.solid.opacity, 0.7, accuracy: 0.0001)
    }

    func testRoundTripKeepsUnknownKeysAndDropsLegacyKeys() throws {
        let original = try Fixture.data(legacy)
        let model = try JSONDecoder().decode(DockModel.self, from: original)
        let saved = DockModel.mergingUnknownKeys(from: original, into: try JSONEncoder().encode(model))
        let json = try Fixture.object(saved)

        let future = try XCTUnwrap(json["futureModules"] as? NSDictionary)
        XCTAssertEqual(future, try Fixture.object(original)["futureModules"] as? NSDictionary)
        XCTAssertEqual(json["savedByVersion"] as? String, AppInfo.version)
        for key in ["pinnedApps", "backgroundStyle", "backgroundFrost"] {
            XCTAssertNil(json[key], "\(key) is read for migration only")
        }

        let reloaded = try JSONDecoder().decode(DockModel.self, from: saved)
        XCTAssertEqual(reloaded.entries, model.entries)
        XCTAssertEqual(reloaded.edge, model.edge)
        XCTAssertEqual(reloaded.hideDelay, model.hideDelay)
        XCTAssertEqual(reloaded.autoHide, model.autoHide)
        XCTAssertEqual(reloaded.hideNativeDock, model.hideNativeDock)
        XCTAssertEqual(reloaded.settingsHotkey, model.settingsHotkey)
        XCTAssertEqual(reloaded.background.style, model.background.style)
        XCTAssertEqual(reloaded.background.solid.opacity, model.background.solid.opacity, accuracy: 0.0001)
    }

    func testKnownKeysUseCurrentValuesOverStaleOnes() throws {
        // Setters persist to the real dock.json, so stale the file on disk instead.
        let model = try JSONDecoder().decode(DockModel.self, from: Fixture.data(legacy))
        var stale = try Fixture.object(Fixture.data(legacy))
        stale["edge"] = DockEdge.right.rawValue
        let existing = try JSONSerialization.data(withJSONObject: stale)
        let json = try Fixture.object(DockModel.mergingUnknownKeys(from: existing, into: try JSONEncoder().encode(model)))
        XCTAssertEqual(json["edge"] as? String, DockEdge.left.rawValue)
        XCTAssertNotNil(json["futureModules"])
    }

    func testNoExistingFileLeavesEncodingUnchanged() throws {
        let model = try JSONDecoder().decode(DockModel.self, from: Fixture.data(legacy))
        let encoded = try JSONEncoder().encode(model)
        XCTAssertEqual(DockModel.mergingUnknownKeys(from: nil, into: encoded), encoded)
        XCTAssertEqual(DockModel.mergingUnknownKeys(from: Data("not json".utf8), into: encoded), encoded)
    }
}
