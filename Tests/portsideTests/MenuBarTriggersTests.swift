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
            unit: { .milliseconds($0 * 20) }, dwell: .milliseconds(10),
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
        XCTAssertFalse(defaults.hover || defaults.scroll || defaults.emptyClick || defaults.rehideOnAppChange)
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

    func testPointerTriggersAreNotValidatedByDefault() {
        for trigger in MenuBarTrigger.allCases where trigger.isPointerTrigger {
            XCTAssertFalse(MenuBarTriggerFeasibility.isAvailable(trigger, environment: [:]))
            XCTAssertTrue(MenuBarTriggerFeasibility.isAvailable(trigger, environment: ["PORTSIDE_MENU_TRIGGERS_EXPERIMENTAL": "1"]))
        }
        XCTAssertTrue(MenuBarTriggerFeasibility.isAvailable(.control, environment: [:]))
        XCTAssertTrue(MenuBarTriggerFeasibility.isAvailable(.hotkey, environment: [:]))
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

    func testTriggerRevealRehidesOnce() async {
        var settings = MenuBarTriggerSettings()
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
        settings.rehideSeconds = 5
        let rig = make(settings: settings)
        rig.service.activate(.control)
        rig.service.activate(.control)
        rig.env.menuOpen = true
        await settle(150)
        XCTAssertEqual(rig.shelf.mode, .revealed)
        XCTAssertNotNil(rig.service.status)
        rig.env.menuOpen = false
        rig.env.mouseDown = true
        await settle(150)
        XCTAssertEqual(rig.shelf.mode, .revealed)
        rig.env.mouseDown = false
        await settle(150)
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

    func testAppChangeRehidesWhenOn() {
        var settings = MenuBarTriggerSettings()
        settings.rehideSeconds = 0
        settings.rehideOnAppChange = true
        let rig = make(settings: settings)
        rig.service.activate(.control)
        rig.service.activate(.control)
        rig.service.appActivated(bundleID: Bundle.main.bundleIdentifier)
        XCTAssertEqual(rig.shelf.mode, .revealed, "Portside itself does not count")
        rig.env.menuOpen = true
        rig.service.appActivated(bundleID: "com.example.other")
        XCTAssertEqual(rig.shelf.mode, .revealed, "an open menu defers it")
        rig.env.menuOpen = false
        rig.service.appActivated(bundleID: "com.example.other")
        XCTAssertEqual(rig.shelf.mode, .hidden)
    }

    func testAppChangeIgnoredWhenOffOrNotPending() {
        let rig = make()
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
}
