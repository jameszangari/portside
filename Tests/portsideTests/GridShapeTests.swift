import XCTest
@testable import portside

/// Columns and Rows of an open group or folder stack grid (`grid` in dock.json).
final class GridShapeTests: XCTestCase {
    func testAutomaticKeepsTheSquareRule() {
        let auto = GridShape()
        XCTAssertTrue(auto.isAutomatic)
        for count in [1, 3, 4, 7, 12, 30] {
            XCTAssertEqual(auto.columns(for: count), GroupPopoverView.columns(for: count))
        }
        XCTAssertNil(auto.maxHeight(rowHeight: 80, spacing: 6))
    }

    func testChosenColumnsNeverWiderThanTheCells() {
        let six = GridShape(columns: 6)
        XCTAssertEqual(six.columns(for: 20), 6)
        XCTAssertEqual(six.columns(for: 3), 3)
        XCTAssertEqual(six.columns(for: 0), 1)
    }

    func testRowsCapTheHeight() {
        XCTAssertEqual(GridShape(rows: 3).maxHeight(rowHeight: 80, spacing: 6), 252)
    }

    func testOutOfRangeAndMalformedReadAsAutomatic() throws {
        func decode(_ json: String) throws -> GridShape {
            try JSONDecoder().decode(GridShape.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"columns": 5, "rows": 2}"#), GridShape(columns: 5, rows: 2))
        XCTAssertEqual(try decode(#"{"columns": 40, "rows": 0}"#), GridShape())
        XCTAssertEqual(try decode(#"{"columns": "wide"}"#), GridShape())
    }

    func testStackRoundTripWritesOnlyAChosenGrid() throws {
        var stack = FolderStack(id: "s", path: "/tmp")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stack)) as? [String: Any])
        XCTAssertNil(json["grid"], "automatic is not written")
        stack.grid = GridShape(columns: 4)
        let data = try JSONEncoder().encode(stack)
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["grid"] as? [String: Any])?["columns"] as? Int, 4)
        XCTAssertEqual(try JSONDecoder().decode(FolderStack.self, from: data).grid, GridShape(columns: 4))
    }

    func testGroupRoundTripAndOlderFilesWithoutAGrid() throws {
        let old = try JSONDecoder().decode(FolderGroup.self, from: Data(#"{"id": "g", "name": "Work", "apps": []}"#.utf8))
        XCTAssertNil(old.grid)
        let group = FolderGroup(id: "g", name: "Work", apps: [], grid: GridShape(columns: 3, rows: 2))
        XCTAssertEqual(try JSONDecoder().decode(FolderGroup.self, from: JSONEncoder().encode(group)).grid, GridShape(columns: 3, rows: 2))
    }
}

/// Portside's own icon (`appIcon` in dock.json).
final class AppIconSettingsTests: XCTestCase {
    private func model(_ json: String) throws -> DockModel {
        try JSONDecoder().decode(DockModel.self, from: Data(json.utf8))
    }

    func testSystemByDefaultUnknownReadsAsSystemAndRoundTrips() throws {
        XCTAssertEqual(try model("{}").appIcon, .system)
        XCTAssertEqual(try model(#"{"appIcon": "rainbow"}"#).appIcon, .system)
        let dark = try model(#"{"appIcon": "dark"}"#)
        XCTAssertEqual(dark.appIcon, .dark)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(dark)) as? [String: Any])
        XCTAssertEqual(json["appIcon"] as? String, "dark")
        let defaults = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try model("{}"))) as? [String: Any])
        XCTAssertNil(defaults["appIcon"], "System is not written")
    }

    func testEveryChoiceDrawsAtTheAskedSize() {
        for choice in AppIconChoice.allCases {
            let image = AppIcon.image(for: choice, points: 48)
            XCTAssertEqual(image.size, NSSize(width: 48, height: 48), choice.rawValue)
        }
    }
}
