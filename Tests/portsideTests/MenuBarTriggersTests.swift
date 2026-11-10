import Carbon.HIToolbox
import XCTest
@testable import portside

@MainActor
final class MenuBarTriggersTests: XCTestCase {
    final class FakeEnvironment: MenuBarTriggerEnvironment {
        var menuOpen = false
        var mouseDown = false
        var secure = false
        var trusted = true
        var busy = false
        func menuIsOpen() -> Bool { menuOpen }
        func mouseButtonDown() -> Bool { mouseDown }
        func secureInputActive() -> Bool { secure }
        func accessibilityTrusted() -> Bool { trusted }
        func layoutIsBusy() -> Bool { busy }
        var editing = false
        func layoutIsEditing() -> Bool { editing }
        var inBar = false
        var overActive = true
        func pointerInMenuBar() -> Bool { inBar }
        func cursorOverActiveAppOrDock() -> Bool { overActive }
    }

    final class FakeProbe: MenuBarEmptyAreaProbe {
        var empty = true
        func isEmptyBar(_ point: CGPoint) -> Bool { empty }
    }

    private struct Rig {
        let shelf: MenuBarShelf
        let service: MenuBarTriggerService
        let env: FakeEnvironment
        let probe: FakeProbe
        let surface: MenuBarShelfTests.FakeSurface
    }

    private func make(settings: MenuBarTriggerSettings = MenuBarTriggerSettings(), pointerOK: Bool = false) -> Rig {
        let surface = MenuBarShelfTests.FakeSurface()
        let shelf = MenuBarShelf(surface: surface, verifyDelay: .seconds(60))
        let env = FakeEnvironment()
        let probe = FakeProbe()
        let service = MenuBarTriggerService(
            shelf: shelf, environment: env, probe: probe,
            unit: { .milliseconds($0 * 20) }, smartUnit: { .milliseconds($0 * 2) }, dwell: .milliseconds(10), eligibilityPoll: .milliseconds(5), focusGrace: .zero,
            featureCheck: { !$0.isPointerTrigger || pointerOK }
        )
        shelf.start()
        service.start(settings)
        return Rig(shelf: shelf, service: service, env: env, probe: probe, surface: surface)
    }

    private func settle(_ ms: Int = 250) async { try? await Task.sleep(for: .milliseconds(ms)) }

    // MARK: Settings

    func testSettingsDefaultsAndRoundTrip() throws {
        let defaults = MenuBarTriggerSettings()
        XCTAssertNil(defaults.hotkey)
        XCTAssertFalse(defaults.hover || defaults.rehideOnAppChange || defaults.alwaysHiddenEnabled)
        XCTAssertTrue(defaults.scroll && defaults.emptyClick, "on by default")
        XCTAssertEqual(defaults.strategy, .smart)
        XCTAssertEqual(defaults.newItemsSection, .visible)
        XCTAssertEqual(defaults.arrangement, .automatic)
        XCTAssertEqual(defaults.rehideSeconds, 15)
        var custom = defaults
        custom.hotkey = HotkeyChord(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | optionKey))
        custom.rehideSeconds = 30
        custom.rehideOnAppChange = true
        let data = try JSONEncoder().encode(custom)
        XCTAssertEqual(try JSONDecoder().decode(MenuBarTriggerSettings.self, from: data), custom)
    }

    func testMalformedSettingsFallBackPerField() throws {
        let json = #"{"hotkey":{"keyCode":11,"modifiers":0},"hover":"yes","rehideSeconds":7,"rehideOnAppChange":true,"scroll":true}"#
        let decoded = try JSONDecoder().decode(MenuBarTriggerSettings.self, from: Data(json.utf8))
        XCTAssertNil(decoded.hotkey, "a chord with no modifier is dropped")
        XCTAssertFalse(decoded.hover)
        XCTAssertEqual(decoded.rehideSeconds, 15, "an unknown delay reads as the default")
        XCTAssertTrue(decoded.rehideOnAppChange)
        XCTAssertTrue(decoded.scroll)
    }

    func testEmptyObjectReadsAsDefaults() throws {
        XCTAssertEqual(try JSONDecoder().decode(MenuBarTriggerSettings.self, from: Data("{}".utf8)), MenuBarTriggerSettings())
    }

    func testPointerTriggersAreAvailable() {
        for trigger in MenuBarTrigger.allCases {
            XCTAssertTrue(MenuBarTriggerFeasibility.isAvailable(trigger))
        }
    }

    func testStrategyDecidesWhetherAppChangeHides() {
        var settings = MenuBarTriggerSettings()
        XCTAssertTrue(settings.rehidesOnAppChange, "Smart")
        settings.strategy = .focusedApp
        XCTAssertTrue(settings.rehidesOnAppChange)
        settings.strategy = .timed
        XCTAssertFalse(settings.rehidesOnAppChange)
        settings.rehideOnAppChange = true
        XCTAssertTrue(settings.rehidesOnAppChange)
    }

    // MARK: Click and command

    func testControlTogglesOnce() {
        let rig = make()
        XCTAssertEqual(rig.service.activate(.control), .hidden)
        XCTAssertEqual(rig.shelf.mode, .hidden)
        XCTAssertEqual(rig.service.activate(.control), .revealed)
        XCTAssertEqual(rig.shelf.mode, .revealed)
    }

    func testBusyLayoutRefusesEveryTrigger() {
        let rig = make()
        rig.env.busy = true
        for trigger in [MenuBarTrigger.control, .hotkey, .command] {
            guard case .refused = rig.service.activate(trigger) else { return XCTFail("\(trigger)") }
        }
        XCTAssertEqual(rig.shelf.mode, .revealed)
        XCTAssertNotNil(rig.service.status)
    }

    func testRefusedWhenShelfOff() {
        let rig = make()
        rig.shelf.stop()
        guard case .refused = rig.service.activate(.control) else { return XCTFail() }
    }

    // MARK: Pointer guards

    func testPointerTriggersRefusedUntilValidated() {
        let rig = make()
        rig.shelf.hide()
        guard case .refused = rig.service.activate(.emptyClick) else { return XCTFail() }
        XCTAssertEqual(rig.shelf.mode, .hidden)
    }

    func testPointerGuards() {
        let rig = make(pointerOK: true)
        rig.shelf.hide()
        rig.env.trusted = false
        XCTAssertNotNil(rig.service.refusal(for: .hover), "Accessibility revoked")
        rig.env.trusted = true
        rig.env.secure = true
        XCTAssertNotNil(rig.service.refusal(for: .scroll), "secure input")
        rig.env.secure = false
        rig.env.menuOpen = true
        XCTAssertNotNil(rig.service.refusal(for: .emptyClick), "open menu")
        rig.env.menuOpen = false
        rig.env.mouseDown = true
        XCTAssertNotNil(rig.service.refusal(for: .hover), "dragging")
        XCTAssertNil(rig.service.refusal(for: .emptyClick), "the click itself is a button down")
        rig.env.mouseDown = false
        XCTAssertNil(rig.service.refusal(for: .hover))
        XCTAssertNil(rig.service.refusal(for: .hotkey), "explicit triggers ignore pointer guards")
    }

    func testEmptyClickTogglesOnlyOverEmptyBar() {
        var settings = MenuBarTriggerSettings()
        settings.emptyClick = true
        let rig = make(settings: settings, pointerOK: true)
        rig.probe.empty = false
        rig.service.pointerEvent(.leftMouseDown, at: .zero)
        XCTAssertEqual(rig.shelf.mode, .revealed, "click on an item or app menu does nothing")
        rig.probe.empty = true
        rig.service.pointerEvent(.leftMouseDown, at: .zero)
        XCTAssertEqual(rig.shelf.mode, .hidden)
    }

    func testScrollDirection() {
        var settings = MenuBarTriggerSettings()
        settings.scroll = true
        let rig = make(settings: settings, pointerOK: true)
        rig.service.pointerEvent(.scrollWheel, scrollDelta: -3, at: .zero)
        XCTAssertEqual(rig.shelf.mode, .hidden)
        rig.service.pointerEvent(.scrollWheel, scrollDelta: 3, at: .zero)
        XCTAssertEqual(rig.shelf.mode, .revealed)
    }

    func testHoverNeedsDwellAndEmptyBar() async {
        var settings = MenuBarTriggerSettings()
        settings.hover = true
        let rig = make(settings: settings, pointerOK: true)
        rig.shelf.hide()
        rig.service.pointerEvent(.mouseMoved, at: .zero)
        rig.probe.empty = false
        rig.service.pointerEvent(.mouseMoved, at: .zero)
        await settle(60)
        XCTAssertEqual(rig.shelf.mode, .hidden, "leaving the empty bar cancels the dwell")
        rig.probe.empty = true
        rig.service.pointerEvent(.mouseMoved, at: .zero)
        rig.service.pointerEvent(.mouseMoved, at: .zero)
        await settle(60)
        XCTAssertEqual(rig.shelf.mode, .revealed)
    }

    func testHoverDisabledDoesNothing() async {
        let rig = make(pointerOK: true)
        rig.shelf.hide()
        rig.service.pointerEvent(.mouseMoved, at: .zero)
        await settle(60)
        XCTAssertEqual(rig.shelf.mode, .hidden)
    }

    // MARK: Rehide

    func testRecoveryCancelsRehideAndExplainsWhy() async {
        var settings = MenuBarTriggerSettings()
        settings.strategy = .timed
        settings.rehideSeconds = 5
        let rig = make(settings: settings)
        defer { rig.service.stop() }
        rig.service.activate(.control)
        rig.service.activate(.control)
        rig.shelf.failOpen("control unavailable")
        await settle(250)
        XCTAssertEqual(rig.shelf.mode, .revealed)
        XCTAssertFalse(rig.service.rehidePending)
        XCTAssertEqual(rig.service.status, "Hiding stopped: control unavailable")
    }

    func testSmartCountdownBacksUpTheClickPath() async {
        var settings = MenuBarTriggerSettings()
        settings.rehideSeconds = 5
        let rig = make(settings: settings)
        defer { rig.service.stop() }
        rig.service.activate(.control)
        rig.service.activate(.control)
        XCTAssertEqual(rig.shelf.mode, .revealed)
        await settle(250)
        XCTAssertEqual(rig.shelf.mode, .hidden)
    }

    func testSmartAbandonsTheCountdownWhileThePointerIsOnTheBar() async {
        var settings = MenuBarTriggerSettings()
        settings.rehideSeconds = 5
        let rig = make(settings: settings)
        defer { rig.service.stop() }
        rig.env.inBar = true
        rig.service.activate(.control)
        rig.service.activate(.control)
        await settle(250)
        XCTAssertEqual(rig.shelf.mode, .revealed)
    }

    func testNeverMeansNeverForEveryPolicy() async {
        for strategy in MenuBarRehideStrategy.allCases {
            var settings = MenuBarTriggerSettings()
            settings.strategy = strategy
            settings.rehideSeconds = 0
            let rig = make(settings: settings)
            rig.service.activate(.control)
            rig.service.activate(.control)
            rig.service.appActivated(bundleID: "com.example.other")
            rig.service.clickedElsewhere()
            await settle(80)
            XCTAssertEqual(rig.shelf.mode, .revealed, "\(strategy)")
            rig.service.stop()
        }
    }

    func testOpenMenuTimeDoesNotCountTowardTheDelay() async {
        var settings = MenuBarTriggerSettings()
        settings.rehideSeconds = 5
        let rig = make(settings: settings)
        defer { rig.service.stop() }
        rig.env.menuOpen = true
        rig.service.activate(.control)
        rig.service.activate(.control)
        await settle(200)
        XCTAssertEqual(rig.shelf.mode, .revealed)
        rig.env.menuOpen = false
        await settle(40)
        XCTAssertEqual(rig.shelf.mode, .revealed, "needs a full interval from when the menu closed")
        await settle(120)
        XCTAssertEqual(rig.shelf.mode, .hidden)
    }

    func testFocusedAppDoesNotUseTheTimedCountdown() async {
        var settings = MenuBarTriggerSettings()
        settings.strategy = .focusedApp
        settings.rehideSeconds = 5
        let rig = make(settings: settings)
        defer { rig.service.stop() }
        rig.service.activate(.control)
        rig.service.activate(.control)
        await settle(250)
        XCTAssertEqual(rig.shelf.mode, .revealed)
        rig.service.appActivated(bundleID: "com.example.other")
        await settle(60)
        XCTAssertEqual(rig.shelf.mode, .hidden)
    }

    func testDisablingDelayCancelsAnAlreadyArmedSmartClick() async {
        var settings = MenuBarTriggerSettings()
        settings.rehideSeconds = 30
        let rig = make(settings: settings)
        defer { rig.service.stop() }
        rig.service.activate(.control)
        rig.service.activate(.control)
        rig.service.clickedElsewhere()
        settings.rehideSeconds = 0
        rig.service.apply(settings)
        await settle(150)
        XCTAssertEqual(rig.shelf.mode, .revealed)
    }

    func testHoverRechecksEmptyAreaAtDwellCompletion() async {
        var settings = MenuBarTriggerSettings()
        settings.hover = true
        let rig = make(settings: settings, pointerOK: true)
        defer { rig.service.stop() }
        rig.shelf.hide()
        rig.service.pointerEvent(.mouseMoved, at: .zero)
        rig.probe.empty = false
        await settle(60)
        XCTAssertEqual(rig.shelf.mode, .hidden)
    }

    func testTriggerRevealRehidesOnce() async {
        var settings = MenuBarTriggerSettings()
        settings.strategy = .timed
        settings.rehideSeconds = 5
        let rig = make(settings: settings)
        rig.service.activate(.control)
        rig.service.activate(.control)
        XCTAssertEqual(rig.shelf.mode, .revealed)
        XCTAssertTrue(rig.service.rehidePending)
        await settle(250)
        XCTAssertEqual(rig.shelf.mode, .hidden)
        XCTAssertFalse(rig.service.rehidePending)
        XCTAssertEqual(rig.surface.applied.filter { $0 }.count, 2, "one hide from the click, one from the rehide")
    }

    func testRepeatedRevealsDoNotStackTimers() async {
        var settings = MenuBarTriggerSettings()
        settings.strategy = .timed
        settings.rehideSeconds = 10
        settings.scroll = true
        let rig = make(settings: settings, pointerOK: true)
        rig.shelf.hide()
        rig.service.pointerEvent(.scrollWheel, scrollDelta: 1, at: .zero)
        await settle(100)
        rig.shelf.hide()
        rig.service.pointerEvent(.scrollWheel, scrollDelta: 1, at: .zero)
        await settle(120)
        XCTAssertEqual(rig.shelf.mode, .revealed, "the second reveal restarted the delay")
        await settle(200)
        XCTAssertEqual(rig.shelf.mode, .hidden)
    }

    func testRehideNeverAndNotArmedForOtherReveals() async {
        var settings = MenuBarTriggerSettings()
        settings.rehideSeconds = 0
        let rig = make(settings: settings)
        rig.service.activate(.control)
        rig.service.activate(.control)
        await settle(150)
        XCTAssertEqual(rig.shelf.mode, .revealed)

        var timed = MenuBarTriggerSettings()
        timed.rehideSeconds = 5
        let other = make(settings: timed)
        other.shelf.hide()
        other.shelf.openForLayout()
        await settle(200)
        XCTAssertEqual(other.shelf.mode, .revealed, "a layout reveal is not a trigger reveal")
    }

    func testOpenMenuAndDragDeferRehide() async {
        var settings = MenuBarTriggerSettings()
        settings.strategy = .timed
        settings.rehideSeconds = 5
        let rig = make(settings: settings)
        rig.service.activate(.control)
        rig.service.activate(.control)
        rig.env.menuOpen = true
        await settle(150)
        XCTAssertEqual(rig.shelf.mode, .revealed)
        rig.env.menuOpen = false
        rig.env.mouseDown = true
        await settle(150)
        XCTAssertEqual(rig.shelf.mode, .revealed)
        rig.env.mouseDown = false
        await settle(150)
        XCTAssertEqual(rig.shelf.mode, .hidden)
    }

    func testOpenLayoutEditorDefersRehideButNotTheControl() async {
        var settings = MenuBarTriggerSettings()
        settings.strategy = .timed
        settings.rehideSeconds = 5
        let rig = make(settings: settings)
        rig.service.activate(.control)
        rig.service.activate(.control)
        rig.env.editing = true
        await settle(150)
        XCTAssertEqual(rig.shelf.mode, .revealed)
        XCTAssertNil(rig.service.refusal(for: .control), "the control still works while the editor is open")
        rig.env.editing = false
        await settle(200)
        XCTAssertEqual(rig.shelf.mode, .hidden)
    }

    func testHidingByHandCancelsRehide() async {
        var settings = MenuBarTriggerSettings()
        settings.rehideSeconds = 5
        let rig = make(settings: settings)
        rig.service.activate(.control)
        rig.service.activate(.control)
        rig.service.activate(.control)
        XCTAssertEqual(rig.shelf.mode, .hidden)
        XCTAssertFalse(rig.service.rehidePending)
        rig.shelf.reveal()
        await settle(200)
        XCTAssertEqual(rig.shelf.mode, .revealed)
    }

    func testAppChangeRehidesWhenOn() async {
        var settings = MenuBarTriggerSettings()
        settings.strategy = .focusedApp
        settings.rehideSeconds = 5
        let rig = make(settings: settings)
        rig.service.activate(.control)
        rig.service.activate(.control)
        rig.service.appActivated(bundleID: Bundle.main.bundleIdentifier)
        await settle(60)
        XCTAssertEqual(rig.shelf.mode, .revealed, "Portside itself does not count")
        rig.service.appActivated(bundleID: "com.example.other")
        await settle(60)
        XCTAssertEqual(rig.shelf.mode, .hidden)
    }

    func testSmartAppChangeWaitsForAnOpenMenu() async {
        var settings = MenuBarTriggerSettings()
        settings.rehideSeconds = 30
        let rig = make(settings: settings)
        defer { rig.service.stop() }
        rig.service.activate(.control)
        rig.service.activate(.control)
        rig.env.menuOpen = true
        rig.service.appActivated(bundleID: "com.example.other")
        await settle(120)
        XCTAssertEqual(rig.shelf.mode, .revealed)
    }

    func testAppChangeIgnoredWhenOffOrNotPending() {
        var timed = MenuBarTriggerSettings()
        timed.strategy = .timed
        let rig = make(settings: timed)
        rig.shelf.hide()
        rig.service.activate(.control)
        rig.service.appActivated(bundleID: "com.example.other")
        XCTAssertEqual(rig.shelf.mode, .revealed)
        var settings = MenuBarTriggerSettings()
        settings.rehideOnAppChange = true
        let on = make(settings: settings)
        on.shelf.hide()
        on.shelf.reveal()
        on.service.appActivated(bundleID: "com.example.other")
        XCTAssertEqual(on.shelf.mode, .revealed, "nothing hides what no trigger revealed")
    }

    func testSmartClickElsewhereHidesAfterTheDelay() async {
        var settings = MenuBarTriggerSettings()
        settings.rehideSeconds = 30
        let rig = make(settings: settings)
        rig.service.activate(.control)
        rig.service.activate(.control)
        XCTAssertEqual(rig.shelf.mode, .revealed)
        rig.service.clickedElsewhere()
        await settle(150)
        XCTAssertEqual(rig.shelf.mode, .hidden)
    }

    func testSmartKeepsOpenWhenPointerIsNotOverTheActiveApp() async {
        var settings = MenuBarTriggerSettings()
        settings.rehideSeconds = 30
        let rig = make(settings: settings)
        rig.env.overActive = false
        rig.service.activate(.control)
        rig.service.activate(.control)
        rig.service.clickedElsewhere()
        await settle(150)
        XCTAssertEqual(rig.shelf.mode, .revealed, "a click on a panel or popover keeps it open")
    }

    func testPointerOnTheBarDefersRehide() async {
        var settings = MenuBarTriggerSettings()
        settings.strategy = .timed
        settings.rehideSeconds = 5
        let rig = make(settings: settings)
        rig.service.activate(.control)
        rig.service.activate(.control)
        rig.env.inBar = true
        await settle(150)
        XCTAssertEqual(rig.shelf.mode, .revealed)
        rig.env.inBar = false
        rig.service.pointerMovedWhileOpen()
        await settle(200)
        XCTAssertEqual(rig.shelf.mode, .hidden)
    }

    func testCancelPendingStopsRehide() async {
        var settings = MenuBarTriggerSettings()
        settings.rehideSeconds = 5
        let rig = make(settings: settings)
        rig.service.activate(.control)
        rig.service.activate(.control)
        rig.service.cancelPending()
        await settle(200)
        XCTAssertEqual(rig.shelf.mode, .revealed)
    }

    func testStopCancelsEverything() async {
        var settings = MenuBarTriggerSettings()
        settings.rehideSeconds = 5
        let rig = make(settings: settings)
        rig.service.activate(.control)
        rig.service.activate(.control)
        rig.service.stop()
        await settle(200)
        XCTAssertEqual(rig.shelf.mode, .revealed)
        guard case .refused = rig.service.activate(.control) else { return XCTFail() }
    }

    // MARK: Geometry

    func testEmptyBarGeometry() {
        let band = CGRect(x: 0, y: 900, width: 1000, height: 24)
        let notch = CGRect(x: 450, y: 900, width: 100, height: 24)
        let occupied = [CGRect(x: 0, y: 900, width: 300, height: 24), CGRect(x: 800, y: 900, width: 40, height: 24)]
        func empty(_ x: CGFloat, y: CGFloat = 910, notch n: CGRect? = notch) -> Bool {
            MenuBarBarGeometry.isEmpty(point: CGPoint(x: x, y: y), band: band, notch: n, occupied: occupied)
        }
        XCTAssertTrue(empty(350))
        XCTAssertFalse(empty(100), "app menus")
        XCTAssertFalse(empty(302), "margin around app menus")
        XCTAssertFalse(empty(500), "notch")
        XCTAssertTrue(empty(500, notch: nil))
        XCTAssertFalse(empty(820), "status item")
        XCTAssertFalse(empty(350, y: 500), "outside the bar")
        XCTAssertTrue(empty(900))
    }
}

/// `menuBarTriggers` in dock.json: written only when it differs from the
/// defaults, and a malformed value reads as the defaults.
final class MenuBarTriggerPersistenceTests: XCTestCase {
    private func model(_ json: String) throws -> DockModel {
        try JSONDecoder().decode(DockModel.self, from: Data(json.utf8))
    }

    func testMissingAndMalformedReadAsDefaults() throws {
        XCTAssertEqual(try model("{}").menuBarTriggers, MenuBarTriggerSettings())
        XCTAssertEqual(try model(#"{"menuBarTriggers": 3}"#).menuBarTriggers, MenuBarTriggerSettings())
        XCTAssertEqual(try model(#"{"menuBarTriggers": {"rehideSeconds": 30}}"#).menuBarTriggers.rehideSeconds, 30)
    }

    func testChoicesRoundTripAndDefaultsAreNotWritten() throws {
        let plain = try JSONEncoder().encode(try model("{}"))
        XCTAssertNil((try JSONSerialization.jsonObject(with: plain) as? [String: Any])?["menuBarTriggers"])
        let loaded = try model(#"{"menuBarTriggers": {"rehideOnAppChange": true, "rehideSeconds": 0}}"#)
        let again = try JSONDecoder().decode(DockModel.self, from: try JSONEncoder().encode(loaded))
        XCTAssertTrue(again.menuBarTriggers.rehideOnAppChange)
        XCTAssertEqual(again.menuBarTriggers.rehideSeconds, 0)
    }

    func testScrollDeltaIgnoresEventsThatAreNotScrolls() throws {
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        XCTAssertEqual(MenuBarTriggerService.scrollDelta(of: click), 0)
    }

    func testPresentationDefaultsToTheMenuBarAndDropsUnknownValues() throws {
        let fresh = try JSONDecoder().decode(MenuBarTriggerSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(fresh.presentation, .menuBar)
        XCTAssertEqual(fresh.barLocation, .dynamic)
        let bad = try JSONDecoder().decode(MenuBarTriggerSettings.self, from: Data(#"{"presentation":"nope","barLocation":"nope"}"#.utf8))
        XCTAssertEqual(bad.presentation, .menuBar)
        XCTAssertEqual(bad.barLocation, .dynamic)
        var chosen = MenuBarTriggerSettings()
        chosen.presentation = .portsideBar
        chosen.barLocation = .left
        let round = try JSONDecoder().decode(MenuBarTriggerSettings.self, from: JSONEncoder().encode(chosen))
        XCTAssertEqual(round.presentation, .portsideBar)
        XCTAssertEqual(round.barLocation, .left)
    }
}
