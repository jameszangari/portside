import XCTest
@testable import portside

final class WindowSpacesTests: XCTestCase {
    /// The stuck panel from the maintainer's Mac: listed on Space 1 only
    /// while Space 4 was current.
    func testWindowOnlyOnAnotherSpaceIsOff() {
        XCTAssertTrue(WindowSpaces.isOff(listed: [1], current: [4]))
    }

    func testWindowOnTheCurrentSpaceIsFine() {
        XCTAssertFalse(WindowSpaces.isOff(listed: [1, 5, 4], current: [4]))
        XCTAssertFalse(WindowSpaces.isOff(listed: [1], current: [4, 1]))
    }

    /// A fresh all-Spaces window can report no Spaces, and a failed read
    /// reports none either: neither is treated as stuck.
    func testEmptyListsAreNotStuck() {
        XCTAssertFalse(WindowSpaces.isOff(listed: [], current: [4]))
        XCTAssertFalse(WindowSpaces.isOff(listed: [1], current: []))
    }
}
