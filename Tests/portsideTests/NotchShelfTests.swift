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

    func testClickOpensAndASecondClickKeepsItOpen() {
        var m = NotchShelfMachine(mode: .hover)
        m.click()
        XCTAssertTrue(m.isOpen)
        XCTAssertFalse(m.pinned)
        m.click()
        XCTAssertTrue(m.isOpen, "like Bartender, a second click does not close")
        XCTAssertEqual(m.pointer(.outside), .collapse)
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
        XCTAssertTrue(m.pinned, "clicking a pinned shelf keeps it")
        m.close()
        XCTAssertEqual(m.phase, .compact)
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

    // MARK: Menu bar coordination (SHELF-02)

    func testExclusionJoinsNotchAndHeaderWithMargin() throws {
        let band = CGRect(x: 0, y: 1080, width: 1728, height: 38)
        let m = MenuBarShelfExclusion.margin
        let joined = try XCTUnwrap(MenuBarShelfExclusion.rect(band: band, notch: 800...928, header: 770...958))
        XCTAssertEqual(joined, CGRect(x: 770 - m, y: 1080, width: 188 + 2 * m, height: 38))
        let notchOnly = try XCTUnwrap(MenuBarShelfExclusion.rect(band: band, notch: 800...928, header: nil))
        XCTAssertEqual(notchOnly.minX, 800 - m)
        XCTAssertEqual(notchOnly.maxX, 928 + m)
        XCTAssertNil(MenuBarShelfExclusion.rect(band: band, notch: nil, header: nil), "below the bar without a notch: nothing to exclude")
    }

    func testExclusionContainsOnlyItsRects() {
        defer { MenuBarShelfExclusion.update([]) }
        MenuBarShelfExclusion.update([CGRect(x: 100, y: 0, width: 50, height: 30)])
        XCTAssertTrue(MenuBarShelfExclusion.contains(CGPoint(x: 120, y: 10)))
        XCTAssertFalse(MenuBarShelfExclusion.contains(CGPoint(x: 200, y: 10)))
        MenuBarShelfExclusion.update([])
        XCTAssertFalse(MenuBarShelfExclusion.contains(CGPoint(x: 120, y: 10)))
    }

    func testShelfLocksPresentationWithoutChangingTheSavedChoice() {
        var settings = MenuBarTriggerSettings()
        for saved in MenuBarPresentation.allCases {
            settings.presentation = saved
            XCTAssertEqual(settings.presentation(notchShelf: true), .portsideBar)
            XCTAssertEqual(settings.presentation(notchShelf: false), saved)
        }
    }

    // MARK: Pages (SHELF-03)

    private let all: (NotchShelfPage) -> Bool = { _ in true }

    func testPagesDefaultsAndOpening() {
        let pages = NotchShelfPages()
        XCTAssertEqual(pages.order, [.widgets, .agents, .clipboard])
        XCTAssertEqual(pages.start, .lastUsed)
        XCTAssertEqual(pages.opening(lastUsed: nil, fromPeek: false, available: all), .widgets, "no last page: the first")
        XCTAssertEqual(pages.opening(lastUsed: .clipboard, fromPeek: false, available: all), .clipboard)
        XCTAssertEqual(pages.opening(lastUsed: .clipboard, fromPeek: true, available: all), .agents, "a peek opens on the page with its card")
    }

    func testFixedStartAndUnavailablePages() {
        var pages = NotchShelfPages()
        pages.start = .clipboard
        XCTAssertEqual(pages.opening(lastUsed: .agents, fromPeek: false, available: all), .clipboard)
        let noClipboard: (NotchShelfPage) -> Bool = { $0 != .clipboard }
        XCTAssertEqual(pages.visible(available: noClipboard), [.widgets, .agents])
        XCTAssertEqual(pages.opening(lastUsed: nil, fromPeek: false, available: noClipboard), .widgets, "start page unavailable: the first")
        pages.setOn(.agents, false)
        XCTAssertEqual(pages.opening(lastUsed: nil, fromPeek: true, available: noClipboard), .widgets, "Agents off: a peek opens normally")
        pages.setOn(.widgets, false)
        XCTAssertNil(pages.opening(lastUsed: nil, fromPeek: false, available: noClipboard))
    }

    func testPagesMoveWithinBounds() {
        var pages = NotchShelfPages()
        pages.move(.clipboard, by: -1)
        XCTAssertEqual(pages.order, [.widgets, .clipboard, .agents])
        pages.move(.widgets, by: -1)
        XCTAssertEqual(pages.order, [.widgets, .clipboard, .agents], "first stays first")
        pages.move(.agents, by: 1)
        XCTAssertEqual(pages.order, [.widgets, .clipboard, .agents])
    }

    func testPagesDecodeRepairsOrder() throws {
        let json = #"{"order":["agents","bogus","agents"],"hidden":["clipboard","nope"],"start":"weird"}"#
        let pages = try JSONDecoder().decode(NotchShelfPages.self, from: Data(json.utf8))
        XCTAssertEqual(pages.order, [.agents, .widgets, .clipboard], "unknown and repeated dropped, missing appended")
        XCTAssertFalse(pages.isOn(.clipboard))
        XCTAssertEqual(pages.start, .lastUsed)
        let back = try JSONDecoder().decode(NotchShelfPages.self, from: JSONEncoder().encode(pages))
        XCTAssertEqual(back, pages)
        let settings = try JSONDecoder().decode(AgentNotchSettings.self, from: Data(#"{"shelfEnabled":true}"#.utf8))
        XCTAssertEqual(settings.shelfPages, NotchShelfPages(), "older files get the default pages")
    }

    // MARK: Widgets page (SHELF-04)

    func testShelfWidgetsNormalize() {
        XCTAssertEqual(NotchShelfWidgets.normalized(["weather", "bogus", "weather", "clock"]), ["weather", "clock"])
        XCTAssertEqual(NotchShelfWidgets.normalized([]), NotchShelfWidgets.defaults)
        XCTAssertEqual(NotchShelfWidgets.normalized(["agents"]), NotchShelfWidgets.defaults, "the agents widget is the Agents page, not a slot")
        XCTAssertEqual(NotchShelfWidgets.normalized(NotchShelfWidgets.eligible).count, NotchShelfWidgets.maxSlots)
    }

    func testShelfWidgetsSettingRoundTrip() throws {
        XCTAssertEqual(AgentNotchSettings().shelfWidgets, ["nowPlaying", "weather"])
        let saved = try JSONDecoder().decode(AgentNotchSettings.self, from: Data(#"{"shelfWidgets":["clock","nope"]}"#.utf8))
        XCTAssertEqual(saved.shelfWidgets, ["clock"])
    }

    func testShelfWidgetLayoutSharesOneTileHeight() {
        let natural: (String) -> WidgetSize = { $0 == "clock" || $0 == "weather" ? .small : .large }
        // 420 pt shelf, 378 pt of room for 4 units: tiles stop at 76 pt.
        let two = AgentNotchView.shelfWidgetLayout(kinds: ["nowPlaying", "weather"], width: 420, natural: natural)
        XCTAssertEqual(two.tile, 76)
        XCTAssertEqual(two.items.map(\.size), [.large, .small])
        // Four widgets, 358 pt for 8 units: 44.75 pt after two step-downs.
        let four = AgentNotchView.shelfWidgetLayout(kinds: ["nowPlaying", "calendar", "usage", "clock"], width: 420, natural: natural)
        XCTAssertEqual(four.items.map(\.size), [.medium, .medium, .large, .small])
        XCTAssertEqual(four.tile, 358 / 8)
    }
}
