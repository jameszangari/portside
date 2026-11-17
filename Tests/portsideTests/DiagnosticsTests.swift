import XCTest
@testable import portside

@MainActor
final class DiagnosticsTests: XCTestCase {
    func testReportRedactsHomeAndListsState() throws {
        let module = IntegrationSettings.ModuleRow(
            id: try XCTUnwrap(ModuleID("clipboardHistory")), title: "Clipboard History", summary: "", fallback: "",
            isRequired: false, isSensitive: true, isEnabled: false, state: .disabled, permissions: [], isRestricted: true)
        let text = Diagnostics.report(Diagnostics.Input(
            versionLine: "Version 2.0.0 by James Cliff", macOS: "Version 27.0", bundlePath: "/Users/me/Developer/portside/.build/debug",
            home: "/Users/me", settings: [("edge", "left")], modules: [module], permissions: [],
            nativeDockBackup: false, revealLatency: RevealLatency().summary))
        XCTAssertTrue(text.contains("App: ~/Developer/portside/.build/debug (development copy)"))
        XCTAssertFalse(text.contains("/Users/me"), "the home folder never appears")
        XCTAssertTrue(text.contains("  edge: left"))
        XCTAssertTrue(text.contains("  clipboardHistory: disabled, off, held by restricted mode"))
        XCTAssertTrue(text.contains("native Dock backup: none"))
        XCTAssertTrue(text.hasSuffix("Reveal latency: no reveals yet\n"))
    }

    func testRedactOnlyMatchesTheWholeHomeFolder() {
        XCTAssertEqual(Diagnostics.redact("/Users/me/Applications/Portside.app", home: "/Users/me"), "~/Applications/Portside.app")
        XCTAssertEqual(Diagnostics.redact("/Users/meg/x", home: "/Users/me"), "/Users/meg/x")
        XCTAssertEqual(Diagnostics.redact("/Applications/Portside.app", home: "/Users/me"), "/Applications/Portside.app")
    }
}
