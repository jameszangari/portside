import XCTest
@testable import portside

/// LaunchServices badges merged with the Dock's own (`AXStatusLabel`).
final class DockBadgesTests: XCTestCase {
    private let ids = ["/System/Applications/System Settings.app": "com.apple.systempreferences"]

    func testDockFillsAppsLaunchServicesMisses() {
        let running = [
            DockBadges.BadgeSource(path: "/Applications/Mail.app", bundleID: "com.apple.mail", label: "3"),
            DockBadges.BadgeSource(path: "/System/Applications/Messages.app", bundleID: "com.apple.MobileSMS", label: nil),
        ]
        let dock = ["/System/Applications/Messages.app": "2", "/System/Applications/System Settings.app": "1"]
        let (byPath, byBundleID) = DockBadges.merge(running: running, dock: dock) { self.ids[$0] }
        XCTAssertEqual(byPath["/Applications/Mail.app"], "3")
        XCTAssertEqual(byBundleID["com.apple.MobileSMS"], "2", "UserNotifications badge, running app")
        XCTAssertEqual(byBundleID["com.apple.systempreferences"], "1", "badge on an app that is not running")
        XCTAssertEqual(byPath["/System/Applications/System Settings.app"], "1")
    }

    func testLaunchServicesWinsOverDock() {
        let running = [DockBadges.BadgeSource(path: "/Applications/Mail.app", bundleID: "com.apple.mail", label: "5")]
        let (byPath, byBundleID) = DockBadges.merge(running: running, dock: ["/Applications/Mail.app": "4"]) { _ in nil }
        XCTAssertEqual(byPath["/Applications/Mail.app"], "5")
        XCTAssertEqual(byBundleID["com.apple.mail"], "5")
    }

    func testNoBadgesWithoutAccessibility() {
        let running = [DockBadges.BadgeSource(path: "/System/Applications/Messages.app", bundleID: "com.apple.MobileSMS", label: nil)]
        let (byPath, byBundleID) = DockBadges.merge(running: running, dock: [:]) { _ in nil }
        XCTAssertTrue(byPath.isEmpty)
        XCTAssertTrue(byBundleID.isEmpty)
    }
}
