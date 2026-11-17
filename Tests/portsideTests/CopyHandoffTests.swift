import XCTest
@testable import portside

final class CopyHandoffTests: XCTestCase {
    private let release = PortsideCopy(pid: 10, isInstalledApp: true, bundleURL: URL(fileURLWithPath: "/Applications/Portside.app"))
    private let otherDev = PortsideCopy(pid: 20, isInstalledApp: false, bundleURL: nil)

    func testAloneAlwaysStarts() {
        XCTAssertEqual(CopyHandoff.decide(isDevCopy: true, others: [], allowSecondCopy: false), .proceed)
        XCTAssertEqual(CopyHandoff.decide(isDevCopy: false, others: [], allowSecondCopy: false), .proceed)
    }

    func testDevCopyQuitsReleaseAndReopensIt() {
        XCTAssertEqual(CopyHandoff.decide(isDevCopy: true, others: [release], allowSecondCopy: false),
                       .takeOver(quit: [release], relaunch: release.bundleURL))
    }

    func testDevCopyQuitsAnotherDevCopyWithoutReopeningIt() {
        XCTAssertEqual(CopyHandoff.decide(isDevCopy: true, others: [otherDev], allowSecondCopy: false),
                       .takeOver(quit: [otherDev], relaunch: nil))
    }

    func testDevCopyReopensTheInstalledCopyWhenBothRun() {
        XCTAssertEqual(CopyHandoff.decide(isDevCopy: true, others: [otherDev, release], allowSecondCopy: false),
                       .takeOver(quit: [otherDev, release], relaunch: release.bundleURL))
    }

    func testReleaseStepsAsideForADevCopy() {
        XCTAssertEqual(CopyHandoff.decide(isDevCopy: false, others: [otherDev], allowSecondCopy: false), .yield(to: otherDev))
    }

    func testTwoInstalledCopiesKeepTodaysBehavior() {
        XCTAssertEqual(CopyHandoff.decide(isDevCopy: false, others: [release], allowSecondCopy: false), .proceed)
    }

    func testAllowSecondCopyTurnsHandoffOff() {
        XCTAssertEqual(CopyHandoff.decide(isDevCopy: true, others: [release], allowSecondCopy: true), .proceed)
        XCTAssertEqual(CopyHandoff.decide(isDevCopy: false, others: [otherDev], allowSecondCopy: true), .proceed)
    }
}
