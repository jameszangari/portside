import XCTest
@testable import MissionControlProbe

final class OverlayPresenceTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    func testUserTraceDetectsOverlayWithoutWindowTitles() {
        let surfaces: [OverlayPresence.Surface] = [
            .init(owner: "Dock", layer: 20, bounds: display, onScreen: true),
            .init(owner: "WindowManager", layer: 19, bounds: display, onScreen: true),
            .init(owner: "WindowManager", layer: 14, bounds: CGRect(x: 0, y: 0, width: 1728, height: 128), onScreen: true)
        ]
        XCTAssertTrue(OverlayPresence.isActive(surfaces, displays: [display]))
        XCTAssertTrue(OverlayPresence.isActive([surfaces[1]], displays: [display]))
    }

    func testRejectsOrdinaryDesktopAndUnrelatedWindows() {
        let surfaces: [OverlayPresence.Surface] = [
            .init(owner: "WindowManager", layer: -2147483624, bounds: display, onScreen: true),
            .init(owner: "WindowManager", layer: 19, bounds: CGRect(x: 0, y: 0, width: 66, height: 82), onScreen: true),
            .init(owner: "WindowManager", layer: 18, bounds: display, onScreen: true),
            .init(owner: "AnotherApp", layer: 19, bounds: display, onScreen: true),
            .init(owner: "WindowManager", layer: 19, bounds: display, onScreen: false)
        ]
        XCTAssertFalse(OverlayPresence.isActive(surfaces, displays: [display]))
    }

    func testDisplayCoordinatesMatter() {
        let other = CGRect(x: -2000, y: -200, width: 2000, height: 1200)
        let surface = OverlayPresence.Surface(owner: "WindowManager", layer: 19, bounds: other, onScreen: true)
        XCTAssertFalse(OverlayPresence.isActive([surface], displays: [display]))
        XCTAssertTrue(OverlayPresence.isActive([surface], displays: [display, other]))
        XCTAssertFalse(OverlayPresence.isActive([surface], displays: []))
    }
}

final class DockCoverTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    func testBottomDockGrowsOnOpenSidesAndStaysFlush() {
        let dock = CGRect(x: 400, y: 4, width: 900, height: 80)
        let (rect, edge) = DockCover.rect(dock: dock, screen: screen, margin: 12)!
        XCTAssertEqual(edge, .bottom)
        XCTAssertEqual(rect, CGRect(x: 388, y: 0, width: 924, height: 96))
    }

    func testSideDocksAndClamping() {
        let left = DockCover.rect(dock: CGRect(x: 0, y: 200, width: 80, height: 700), screen: screen, margin: 12)!
        XCTAssertEqual(left.1, .left)
        XCTAssertEqual(left.0, CGRect(x: 0, y: 188, width: 92, height: 724))
        let right = DockCover.rect(dock: CGRect(x: 1648, y: 0, width: 80, height: 1117), screen: screen, margin: 12)!
        XCTAssertEqual(right.1, .right)
        XCTAssertEqual(right.0, CGRect(x: 1636, y: 0, width: 92, height: 1117))
    }

    func testDockSlidingInCoversSettledSize() {
        // Captured on entry: AX Dock frame still 39 pt below the screen.
        let (rect, edge) = DockCover.rect(dock: CGRect(x: 295, y: -39, width: 1138, height: 48), screen: screen, margin: 12)!
        XCTAssertEqual(edge, .bottom)
        XCTAssertEqual(rect, CGRect(x: 283, y: 0, width: 1162, height: 60))
        XCTAssertNotNil(DockCover.rect(dock: CGRect(x: 295, y: -60, width: 1138, height: 48), screen: screen, margin: 12))
        XCTAssertNil(DockCover.rect(dock: CGRect(x: 295, y: 600, width: 1138, height: 48), screen: screen, margin: 12))
    }

    func testHoverGrowsTowardScreenCenter() {
        let bottom = CGRect(x: 301, y: 0, width: 1126, height: 70)
        XCTAssertEqual(DockCover.hovered(bottom, edge: .bottom, clearance: 40, screen: screen),
                       CGRect(x: 301, y: 0, width: 1126, height: 110))
        let right = CGRect(x: 1636, y: 100, width: 92, height: 700)
        XCTAssertEqual(DockCover.hovered(right, edge: .right, clearance: 40, screen: screen),
                       CGRect(x: 1596, y: 100, width: 132, height: 700))
        let left = CGRect(x: 0, y: 100, width: 92, height: 700)
        XCTAssertEqual(DockCover.hovered(left, edge: .left, clearance: 40, screen: screen),
                       CGRect(x: 0, y: 100, width: 132, height: 700))
    }

    func testDockOnAnotherDisplayIsIgnored() {
        XCTAssertNil(DockCover.rect(dock: CGRect(x: -900, y: 0, width: 800, height: 80), screen: screen, margin: 12))
    }

    func testFallbackUsesReservedStripOrBottomStrip() {
        let reserved = CGRect(x: 0, y: 90, width: 1728, height: 997)
        XCTAssertEqual(DockCover.fallback(screen: screen, visible: reserved, height: 100),
                       CGRect(x: 0, y: 0, width: 1728, height: 90))
        let hidden = CGRect(x: 0, y: 0, width: 1728, height: 1087)
        XCTAssertEqual(DockCover.fallback(screen: screen, visible: hidden, height: 100),
                       CGRect(x: 0, y: 0, width: 1728, height: 100))
    }
}
