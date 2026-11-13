import XCTest
@testable import portside

final class NotchShelfTests: XCTestCase {
    // MARK: Regions

    /// 400 pt panel, 200 pt header with a 100 pt notch, 32 pt header height.
    private func region(_ x: CGFloat, _ y: CGFloat, notch: CGFloat = 100) -> NotchShelfRegion {
        .at(CGPoint(x: x, y: y), panelWidth: 400, compactWidth: 200, notchWidth: notch, headerHeight: 32)
    }

    func testRegionsAcrossTheHeader() {
        XCTAssertEqual(region(110, 10), .side(.leading))
        XCTAssertEqual(region(200, 10), .notch)
        XCTAssertEqual(region(290, 10), .side(.trailing))
        XCTAssertEqual(region(50, 10), .body, "panel wider than the header: outside the header is content")
        XCTAssertEqual(region(200, 60), .body)
        XCTAssertEqual(region(-1, 10), .outside)
        XCTAssertEqual(region(401, 10), .outside)
    }

    func testWithoutNotchMiddleThirdActsAsNotch() {
        XCTAssertEqual(region(120, 10, notch: 0), .side(.leading))
        XCTAssertEqual(region(200, 10, notch: 0), .notch)
        XCTAssertEqual(region(280, 10, notch: 0), .side(.trailing))
    }

    // MARK: Hover mode

    func testSideHoverPeeksAfterDelayThenNotchOpens() {
        var m = NotchShelfMachine(mode: .hover)
        XCTAssertEqual(m.pointer(.side(.leading)), .peek(.leading))
        XCTAssertEqual(m.phase, .compact, "nothing changes before the delay")
        m.fire(.peek(.leading))
        XCTAssertEqual(m.phase, .peek(.leading))
        XCTAssertEqual(m.pointer(.notch), .open)
        m.fire(.open)
        XCTAssertTrue(m.isOpen)
    }

    func testPassingOverSideDoesNotPeek() {
        var m = NotchShelfMachine(mode: .hover)
        m.pointer(.side(.leading))
        m.pointer(.outside)
        m.fire(.peek(.leading))
        XCTAssertEqual(m.phase, .compact, "a stale timer is ignored")
    }

    func testEmptySideDoesNotPeek() {
        var m = NotchShelfMachine(mode: .hover)
        XCTAssertNil(m.pointer(.side(.trailing)) { $0 == .leading })
        XCTAssertEqual(m.pointer(.side(.leading)) { $0 == .leading }, .peek(.leading))
    }

    func testPeekSwitchesSides() {
        var m = NotchShelfMachine(mode: .hover)
        m.pointer(.side(.leading)); m.fire(.peek(.leading))
        XCTAssertNil(m.pointer(.side(.leading)), "same side keeps the card")
        XCTAssertEqual(m.pointer(.side(.trailing)), .peek(.trailing))
        m.fire(.peek(.trailing))
        XCTAssertEqual(m.phase, .peek(.trailing))
    }

    func testLeavingPeekUsesShortCollapse() {
        var m = NotchShelfMachine(mode: .hover)
        m.pointer(.side(.leading)); m.fire(.peek(.leading))
        XCTAssertNil(m.pointer(.body), "moving onto the card keeps it")
        XCTAssertEqual(m.pointer(.outside), .collapsePeek)
        m.fire(.collapsePeek)
        XCTAssertEqual(m.phase, .compact)
    }

    func testLeavingOpenShelfCollapsesUnlessReentered() {
        var m = NotchShelfMachine(mode: .hover)
        m.open()
        XCTAssertEqual(m.pointer(.outside), .collapse)
        XCTAssertNil(m.pointer(.body), "coming back cancels the collapse")
        m.fire(.collapse)
        XCTAssertTrue(m.isOpen)
        m.pointer(.outside); m.fire(.collapse)
        XCTAssertEqual(m.phase, .compact)
    }

    func testClickTogglesInHoverMode() {
        var m = NotchShelfMachine(mode: .hover)
        m.click()
        XCTAssertTrue(m.isOpen)
        XCTAssertFalse(m.pinned)
        m.click()
        XCTAssertEqual(m.phase, .compact, "a second click closes (Bartender does not)")
    }

    // MARK: Click mode

    func testClickModeNotchHoverDoesNotOpen() {
        var m = NotchShelfMachine(mode: .click)
        XCTAssertNil(m.pointer(.notch))
        XCTAssertEqual(m.pointer(.side(.leading)), .peek(.leading), "sides still peek")
        m.fire(.peek(.leading))
        XCTAssertNil(m.pointer(.notch), "notch keeps the peek in click mode")
        XCTAssertEqual(m.phase, .peek(.leading))
        m.click()
        XCTAssertTrue(m.isOpen)
        XCTAssertEqual(m.pointer(.outside), .collapse, "click mode still closes when the pointer leaves")
    }

    // MARK: Hover opens, click pins

    func testHoverPinMode() {
        var m = NotchShelfMachine(mode: .hoverPin)
        m.pointer(.notch); m.fire(.open)
        XCTAssertFalse(m.pinned)
        m.click()
        XCTAssertTrue(m.isOpen)
        XCTAssertTrue(m.pinned)
        XCTAssertNil(m.pointer(.outside), "pinned survives the pointer leaving")
        m.click()
        XCTAssertEqual(m.phase, .compact, "clicking a pinned shelf closes it")
    }

    func testClickFromCompactPinsInHoverPinMode() {
        var m = NotchShelfMachine(mode: .hoverPin)
        m.click()
        XCTAssertTrue(m.isOpen)
        XCTAssertTrue(m.pinned)
    }

    func testCloseClearsPinAndPending() {
        var m = NotchShelfMachine(mode: .hoverPin)
        m.click()
        m.pointer(.side(.leading))
        m.close()
        XCTAssertEqual(m.phase, .compact)
        XCTAssertFalse(m.pinned)
        XCTAssertNil(m.pending)
    }

    func testPinOnlyWhileOpen() {
        var m = NotchShelfMachine(mode: .hover)
        m.setPinned(true)
        XCTAssertFalse(m.pinned)
        m.open(); m.setPinned(true)
        XCTAssertTrue(m.pinned)
    }

    // MARK: Settings

    func testSettingsDefaultOffAndRoundTrip() throws {
        let old = try JSONDecoder().decode(AgentNotchSettings.self, from: Data(#"{"expandOnHover":false}"#.utf8))
        XCTAssertFalse(old.shelfEnabled, "existing files keep the classic island")
        XCTAssertEqual(old.shelfOpenMode, .hover)
        var settings = AgentNotchSettings()
        settings.shelfEnabled = true
        settings.shelfOpenMode = .hoverPin
        let back = try JSONDecoder().decode(AgentNotchSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(back.shelfEnabled)
        XCTAssertEqual(back.shelfOpenMode, .hoverPin)
        let bad = try JSONDecoder().decode(AgentNotchSettings.self, from: Data(#"{"shelfOpenMode":"wiggle"}"#.utf8))
        XCTAssertEqual(bad.shelfOpenMode, .hover, "unknown mode falls back")
    }
}
