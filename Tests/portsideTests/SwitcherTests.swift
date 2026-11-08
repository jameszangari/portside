import AppKit
import Carbon.HIToolbox
import Combine
import XCTest
@testable import portside

private func item(_ pid: pid_t, _ name: String, generation: UInt64 = 1, hidden: Bool = false) -> SwitcherItem {
    SwitcherItem(key: AppKey(pid: pid, generation: generation), name: name, isHidden: hidden)
}

/// The switcher state machine: quick switch, held cycling, release, Escape,
/// focus loss, and apps quitting or launching while it is open.
final class SwitcherStateTests: XCTestCase {
    private let a = item(10, "Alpha")
    private let b = item(20, "Bravo")
    private let c = item(30, "Charlie")
    private var apps: [SwitcherItem] { [a, b, c] }

    /// Open and held, frontmost Alpha, selection on Bravo.
    private func opened(revealed: Bool = false) -> SwitcherState {
        var state = SwitcherState()
        XCTAssertEqual(state.send(.trigger(items: apps, frontmost: a.key.pid, held: true)), [.present])
        if revealed { _ = state.send(.revealDue) }
        return state
    }

    func testQuickTapSwitchesToPreviousAppWithoutAPanel() {
        var state = SwitcherState()
        let effects = state.send(.trigger(items: apps, frontmost: a.key.pid, held: false))
        XCTAssertEqual(effects, [.activate(b)], "no present, no dismiss: nothing flashes")
        XCTAssertFalse(state.isOpen)
    }

    func testHeldOpensTransparentThenRevealsAndReleaseCommits() {
        var state = opened()
        XCTAssertEqual(state.phase, .armed)
        XCTAssertEqual(state.selectedItem, b)
        XCTAssertEqual(state.send(.revealDue), [.reveal, .announce("Bravo")])
        XCTAssertEqual(state.phase, .visible)
        XCTAssertEqual(state.send(.modifiersReleased), [.dismiss, .activate(b)], "dismiss comes before activation")
        XCTAssertFalse(state.isOpen)
        XCTAssertEqual(state.items, [])
    }

    func testReleaseBeforeRevealCommitsAndRevealIsDropped() {
        var state = opened()
        XCTAssertEqual(state.send(.modifiersReleased), [.dismiss, .activate(b)])
        XCTAssertEqual(state.send(.revealDue), [], "a late reveal after commit does nothing")
    }

    func testForwardAndReverseCyclingWrap() {
        var state = opened()
        XCTAssertEqual(state.send(.trigger(items: apps, frontmost: a.key.pid, held: true)), [], "a second press moves, silent before reveal")
        XCTAssertEqual(state.selectedItem, c)
        _ = state.send(.trigger(items: [], frontmost: nil, held: true))
        XCTAssertEqual(state.selectedItem, a, "wraps forward; items are kept from the open")
        _ = state.send(.key(.previous))
        XCTAssertEqual(state.selectedItem, c, "wraps backward")
        _ = state.send(.key(.previous))
        XCTAssertEqual(state.selectedItem, b)
        _ = state.send(.key(.first))
        XCTAssertEqual(state.selectedItem, a)
        _ = state.send(.key(.last))
        XCTAssertEqual(state.selectedItem, c)
        _ = state.send(.key(.next))
        XCTAssertEqual(state.selectedItem, a)
    }

    func testAnnouncesOnlyWhileVisible() {
        var state = opened(revealed: true)
        XCTAssertEqual(state.send(.key(.next)), [.announce("Charlie")])
        let hidden = item(40, "Delta", hidden: true)
        _ = state.send(.appsChanged(apps + [hidden]))
        XCTAssertEqual(state.send(.key(.next)), [.announce("Delta, hidden")])
        XCTAssertEqual(state.send(.key(.last)), [], "already selected")
    }

    func testChoosingTheFrontmostAppActivatesNothing() {
        var state = opened()
        _ = state.send(.key(.first))
        XCTAssertEqual(state.send(.modifiersReleased), [.dismiss])
    }

    func testReturnAndClickCommit() {
        var state = opened()
        XCTAssertEqual(state.send(.key(.commit)), [.dismiss, .activate(b)])
        state = opened()
        XCTAssertEqual(state.send(.choose(.app(c.key))), [.dismiss, .activate(c)])
        state = opened()
        XCTAssertEqual(state.send(.choose(.app(item(99, "Gone").key))), [], "a key not in the list is ignored")
        XCTAssertTrue(state.isOpen)
    }

    func testEscapeCancelsWithoutActivating() {
        var state = opened(revealed: true)
        _ = state.send(.key(.next))
        XCTAssertEqual(state.send(.key(.cancel)), [.dismiss])
        XCTAssertEqual(state.send(.modifiersReleased), [], "the later release commits nothing")
    }

    func testFocusLossAndDisableCancel() {
        var state = opened()
        XCTAssertEqual(state.send(.focusLost), [.dismiss])
        state = opened(revealed: true)
        XCTAssertEqual(state.send(.disable), [.dismiss])
        XCTAssertEqual(state.send(.disable), [], "already closed")
        XCTAssertEqual(state.send(.key(.next)), [])
    }

    func testStartsOnFirstWhenTheFrontmostAppIsNotListed() {
        // Portside's own Settings is in front, so the first app is the one behind it.
        var state = SwitcherState()
        XCTAssertEqual(state.send(.trigger(items: apps, frontmost: 999, held: false)), [.activate(a)])
        _ = state.send(.trigger(items: apps, frontmost: 999, held: true))
        XCTAssertEqual(state.selectedItem, a)
    }

    func testSingleAndEmptyLists() {
        var state = SwitcherState()
        XCTAssertEqual(state.send(.trigger(items: [], frontmost: nil, held: true)), [], "nothing running: nothing opens")
        XCTAssertEqual(state.send(.trigger(items: [a], frontmost: a.key.pid, held: false)), [], "only the frontmost app")
        XCTAssertEqual(state.send(.trigger(items: [a], frontmost: a.key.pid, held: true)), [.present])
        XCTAssertEqual(state.selectedItem, a)
        XCTAssertEqual(state.send(.modifiersReleased), [.dismiss])
    }

    func testQuitAppLeavesAndSelectionMovesToItsPlace() {
        var state = opened(revealed: true)
        XCTAssertEqual(state.send(.appsChanged([a, c])), [.announce("Charlie")])
        XCTAssertEqual(state.items, [a, c])
        XCTAssertEqual(state.selectedItem, c)
        _ = state.send(.appsChanged([a]))
        XCTAssertEqual(state.selectedItem, a, "the last app quit: selection clamps")
        XCTAssertEqual(state.send(.appsChanged([])), [.dismiss], "every app quit")
        XCTAssertFalse(state.isOpen)
    }

    func testOpenOrderIsStableAndNewAppsJoinAtTheEnd() {
        var state = opened()
        let d = item(40, "Delta")
        let renamed = item(30, "Charlie 2")
        XCTAssertEqual(state.send(.appsChanged([d, renamed, b, a])), [], "armed: nothing announced")
        XCTAssertEqual(state.items.map(\.name), ["Alpha", "Bravo", "Charlie 2", "Delta"])
        XCTAssertEqual(state.selectedItem, b)
    }

    func testRelaunchOnTheSamePidIsADifferentApp() {
        var state = opened()
        let relaunched = item(20, "Bravo", generation: 2)
        _ = state.send(.appsChanged([a, relaunched, c]))
        XCTAssertEqual(state.items, [a, c, relaunched], "the old launch left; the new one is new")
        XCTAssertEqual(state.selectedItem, c)
        XCTAssertEqual(state.send(.choose(.app(b.key))), [], "the earlier launch's key no longer matches")
    }

    func testHoverSelectsOnlyWhileVisible() {
        var state = opened()
        XCTAssertEqual(state.send(.hover(.app(c.key))), [], "armed: the panel is not shown yet")
        XCTAssertEqual(state.selectedItem, b)
        _ = state.send(.revealDue)
        XCTAssertEqual(state.send(.hover(.app(c.key))), [.announce("Charlie")])
        XCTAssertEqual(state.send(.hover(.app(c.key))), [], "already selected")
        XCTAssertEqual(state.send(.hover(.app(item(99, "Gone").key))), [])
        XCTAssertEqual(state.send(.modifiersReleased), [.dismiss, .activate(c)])
    }

    func testEventsWhileHiddenDoNothing() {
        var state = SwitcherState()
        for event: SwitcherEvent in [.modifiersReleased, .revealDue, .focusLost, .disable, .key(.commit), .appsChanged(apps), .choose(.app(a.key)), .hover(.app(a.key))] {
            XCTAssertEqual(state.send(event), [], "\(event)")
        }
        XCTAssertEqual(state, SwitcherState())
    }
}

/// Keys, modifier release and which chords the switcher may own.
final class SwitcherInputTests: XCTestCase {
    private let optionTab = SwitcherShortcut.defaultChord

    func testKeysIgnoreTheHeldModifier() {
        func map(_ code: Int, _ flags: NSEvent.ModifierFlags = .option) -> SwitcherKey? {
            SwitcherKey(keyCode: UInt16(code), modifiers: flags)
        }
        XCTAssertEqual(map(kVK_Tab), .next)
        XCTAssertEqual(map(kVK_Tab, [.option, .shift]), .previous)
        XCTAssertEqual(map(kVK_ANSI_Grave), .previous)
        XCTAssertEqual(map(kVK_RightArrow), .next)
        XCTAssertEqual(map(kVK_LeftArrow, []), .previous)
        XCTAssertEqual(map(kVK_Home), .first)
        XCTAssertEqual(map(kVK_End), .last)
        XCTAssertEqual(map(kVK_Return), .commit)
        XCTAssertEqual(map(kVK_ANSI_KeypadEnter), .commit)
        XCTAssertEqual(map(kVK_Escape), .cancel, "Escape with ⌥ still held cancels")
        XCTAssertNil(map(kVK_ANSI_Q))
        XCTAssertNil(map(kVK_Space))
    }

    func testReleaseIsTheShortcutsModifiersNotShift() {
        let required = SwitcherModifiers.required(for: optionTab)
        XCTAssertEqual(required, .option)
        XCTAssertEqual(SwitcherModifiers.required(for: HotkeyChord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey | shiftKey))), .option)
        XCTAssertEqual(SwitcherModifiers.required(for: HotkeyChord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(controlKey | optionKey))), [.control, .option])
        XCTAssertTrue(SwitcherModifiers.isHeld([.option], required: required))
        XCTAssertTrue(SwitcherModifiers.isHeld([.option, .shift, .capsLock], required: required), "Shift for reverse keeps it held")
        XCTAssertFalse(SwitcherModifiers.isHeld([.shift], required: required), "letting go of ⌥ while Shift is down commits")
        XCTAssertFalse(SwitcherModifiers.isHeld([], required: required))
        XCTAssertFalse(SwitcherModifiers.isHeld([.control], required: [.control, .option]), "either modifier released commits")
        XCTAssertFalse(SwitcherModifiers.isHeld([.option], required: []), "nothing required: never held")
    }

    func testOptionTabIsTheDefaultAndRegisterable() {
        XCTAssertEqual(optionTab, HotkeyChord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey)))
        XCTAssertTrue(optionTab.isRegisterable)
        XCTAssertEqual(optionTab.displayString, "⌥Tab")
        XCTAssertTrue(SwitcherShortcut.isAllowed(optionTab))
        XCTAssertTrue(SwitcherShortcut.isAllowed(HotkeyChord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(controlKey))))
        XCTAssertFalse(HotkeyChord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(shiftKey)).isRegisterable)
        XCTAssertFalse(HotkeyChord(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(optionKey)).isRegisterable, "⌥ with a letter still types")
    }

    func testNativeCommandTabIsRefused() {
        for modifiers in [cmdKey, cmdKey | shiftKey, cmdKey | optionKey] {
            let chord = HotkeyChord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(modifiers))
            XCTAssertTrue(SwitcherShortcut.refusal(for: chord)?.contains("macOS app switcher") == true, chord.displayString)
            XCTAssertFalse(SwitcherShortcut.isAllowed(chord))
        }
        XCTAssertNil(SwitcherShortcut.refusal(for: HotkeyChord(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | controlKey))))
    }

    func testConflictsWithPortsideAndMacOSShortcuts() {
        let commandCenter = HotkeyChord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey))
        let message = HotkeyConflicts.conflict(for: optionTab, system: [], portside: [("Command Center", commandCenter)])
        XCTAssertTrue(message?.contains("Command Center") == true)
        let system = [SymbolicHotkey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey), enabled: true)]
        XCTAssertTrue(HotkeyConflicts.conflict(for: optionTab, system: system, portside: [])?.contains("macOS shortcut") == true)
        XCTAssertNil(HotkeyConflicts.conflict(for: optionTab, system: [], portside: [("Command Center", nil)]), "a module that is off holds nothing")
    }
}

/// `switcherHotkey` in dock.json: same rules as the other shortcuts, and a
/// refused chord (⌘Tab) never loads.
final class SwitcherSettingsTests: XCTestCase {
    private func model(_ json: String) throws -> DockModel {
        try JSONDecoder().decode(DockModel.self, from: Data(json.utf8))
    }

    func testMissingDefaultNullClearedMalformedAndRefusedReset() throws {
        XCTAssertEqual(try model("{}").switcherHotkey, SwitcherShortcut.defaultChord)
        XCTAssertNil(try model(#"{"switcherHotkey": null}"#).switcherHotkey)
        XCTAssertEqual(try model(#"{"switcherHotkey": "tab"}"#).switcherHotkey, SwitcherShortcut.defaultChord)
        let commandTab = #"{"switcherHotkey": {"keyCode": 48, "modifiers": 256}}"#
        XCTAssertEqual(try model(commandTab).switcherHotkey, SwitcherShortcut.defaultChord)
        let controlTab = #"{"switcherHotkey": {"keyCode": 48, "modifiers": 4096}}"#
        XCTAssertEqual(try model(controlTab).switcherHotkey, HotkeyChord(keyCode: 48, modifiers: 4096))
    }

    func testRoundTripWritesNullWhenCleared() throws {
        let cleared = try model(#"{"switcherHotkey": null}"#)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cleared)) as? [String: Any])
        XCTAssertTrue(json["switcherHotkey"] is NSNull)
        let set = try model("{}")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(set)) as? [String: Any])
        XCTAssertEqual((encoded["switcherHotkey"] as? [String: Any])?["keyCode"] as? Int, kVK_Tab)
    }
}

// MARK: - Controller and module

/// No Accessibility: the registry keeps app-only state and never reads windows.
private final class NoWindows: WindowSource, @unchecked Sendable {
    func observe(_ pid: pid_t, changed: @escaping () -> Void) -> WindowObserveResult { .failed }
    func readWindows(of pid: pid_t, observation: WindowObservation?) -> WindowReadResult { .windows([]) }
}

@MainActor
private final class RecordingPresenter: SwitcherPresenter {
    var calls: [String] = []
    var announcements: [String] = []
    func present(_ switcher: AppSwitcher) { calls.append("present") }
    func reveal() { calls.append("reveal") }
    func dismiss() { calls.append("dismiss") }
    func announce(_ message: String) { announcements.append(message) }
}

private func runningApp(_ pid: pid_t, _ name: String, launched: TimeInterval = 0) -> RunningAppRecord {
    RunningAppRecord(pid: pid, bundleIdentifier: "test.\(name)", name: name, launchDate: Date(timeIntervalSince1970: launched))
}

/// The controller over a real `WindowRegistry` with fake apps, a fake
/// keyboard, a recording presenter and a fake hotkey registrar.
@MainActor
final class AppSwitcherTests: XCTestCase {
    private final class Token {
        let onRelease: () -> Void
        init(onRelease: @escaping () -> Void) { self.onRelease = onRelease }
        deinit { onRelease() }
    }

    private let alpha = runningApp(10, "Alpha")
    private let bravo = runningApp(20, "Bravo")
    private let charlie = runningApp(30, "Charlie")
    private var front: pid_t? = 10
    private var flags: NSEvent.ModifierFlags = []
    private var activated: [String] = []
    private var refuseActivation = false
    private var held: [HotkeyChord] = []
    private var actionsByChord: [HotkeyChord: () -> Void] = [:]
    private var press: (() -> Void)? { actionsByChord[SwitcherShortcut.defaultChord] }
    private var pointer = NSPoint(x: 100, y: 100)
    private var modifierChangedAt: TimeInterval = 0
    private var clock: TimeInterval = 10
    private var pressAt: TimeInterval?
    private var activationFailed: (() -> Void)?
    private let optionEscape = HotkeyChord(keyCode: UInt32(kVK_Escape), modifiers: UInt32(optionKey))
    private var reports: [String?] = []
    private let presenter = RecordingPresenter()
    private let chords = CurrentValueSubject<HotkeyChord?, Never>(SwitcherShortcut.defaultChord)

    private lazy var registry = WindowRegistry(
        source: NoWindows(),
        isAccessGranted: { false },
        currentApps: { [unowned self] in ([alpha, bravo, charlie], front) }
    )

    private lazy var switcher = AppSwitcher(
        registry: registry,
        actions: SwitcherActions(
            modifierFlags: { [unowned self] in flags },
            frontmostPID: { [unowned self] in front },
            activate: { [unowned self] item, failed in
                guard !refuseActivation else { return false }
                activated.append(item.name)
                activationFailed = failed
                return true
            },
            mouseLocation: { [unowned self] in pointer },
            lastModifierChange: { [unowned self] in modifierChangedAt },
            now: { [unowned self] in clock },
            pressTime: { [unowned self] in pressAt ?? clock },
            revealDelay: .seconds(3600)
        ),
        presenter: presenter,
        registrar: { [unowned self] chord, action in
            held.append(chord)
            actionsByChord[chord] = action
            return Token { [unowned self] in
                held.removeAll { $0 == chord }
                actionsByChord[chord] = nil
            }
        },
        report: { [unowned self] in reports.append($0) }
    )

    private lazy var commands = CommandRegistry(permissions: PermissionGate())
    private lazy var modules = ModuleRegistry(commands: commands, permissions: PermissionGate())

    private func enable() throws {
        try modules.register(SwitcherModule(switcher: switcher, chords: chords.eraseToAnyPublisher()))
        modules.enable(SwitcherModule.moduleID)
    }

    /// Activation order Bravo, Charlie, Alpha... as the person used them.
    private func activate(_ app: RunningAppRecord) {
        front = app.pid
        registry.appActivated(app)
    }

    func testOffByDefaultHoldsNothing() throws {
        try modules.register(SwitcherModule(switcher: switcher, chords: chords.eraseToAnyPublisher()))
        modules.enableSaved(ModuleSettings())
        XCTAssertEqual(modules.state(of: SwitcherModule.moduleID), .disabled)
        XCTAssertEqual(held, [])
        XCTAssertFalse(registry.isRunning, "no registry client while off")
        switcher.hotkeyPressed()
        XCTAssertEqual(presenter.calls, [])
        XCTAssertEqual(activated, [])
    }

    func testModuleLifecycleOwnsTheShortcutAndTheRegistryClient() throws {
        try enable()
        XCTAssertEqual(modules.state(of: SwitcherModule.moduleID), .running)
        XCTAssertEqual(held, [SwitcherShortcut.defaultChord])
        XCTAssertTrue(switcher.hasRegistryClient)
        XCTAssertTrue(registry.isRunning)

        let control = HotkeyChord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(controlKey))
        chords.send(control)
        XCTAssertEqual(held, [control])
        chords.send(nil)
        XCTAssertEqual(held, [], "cleared in Settings")

        flags = .option
        chords.send(SwitcherShortcut.defaultChord)
        switcher.hotkeyPressed()
        XCTAssertTrue(switcher.state.isOpen)

        modules.disable(SwitcherModule.moduleID)
        XCTAssertFalse(switcher.state.isOpen, "turning it off cancels an open switcher")
        XCTAssertEqual(presenter.calls.last, "dismiss")
        XCTAssertEqual(activated, [])
        XCTAssertEqual(held, [])
        XCTAssertEqual(switcher.hotkeyStatus, .off)
        XCTAssertFalse(registry.isRunning, "the client is released")
        XCTAssertEqual(modules.resourceCount(of: SwitcherModule.moduleID), 0)
        let before = held
        chords.send(control)
        XCTAssertEqual(held, before, "no subscription survives the stop")
        switcher.hotkeyPressed()
        XCTAssertFalse(switcher.state.isOpen)
    }

    func testNotSensitiveSoRestrictedModeKeepsIt() throws {
        try modules.register(SwitcherModule(switcher: switcher, chords: chords.eraseToAnyPublisher()))
        var saved = ModuleSettings()
        saved.setEnabled(true, for: SwitcherModule.moduleID)
        modules.enableSaved(saved, restricted: true)
        XCTAssertEqual(modules.state(of: SwitcherModule.moduleID), .running)
    }

    func testCommandTabIsNeverRegistered() throws {
        try enable()
        chords.send(HotkeyChord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey)))
        XCTAssertEqual(held, [])
        XCTAssertEqual(switcher.hotkeyStatus, .off)
        XCTAssertTrue(reports.last??.contains("macOS app switcher") == true)
    }

    func testRefusedRegistrationIsReported() throws {
        let commands = CommandRegistry(permissions: PermissionGate())
        let modules = ModuleRegistry(commands: commands, permissions: PermissionGate())
        var reported: [String?] = []
        let switcher = AppSwitcher(registry: registry, actions: SwitcherActions(modifierFlags: { [] }, frontmostPID: { nil }, activate: { _, _ in true }),
                                   presenter: presenter, registrar: { _, _ in nil }, report: { reported.append($0) })
        try modules.register(SwitcherModule(switcher: switcher, chords: chords.eraseToAnyPublisher()))
        modules.enable(SwitcherModule.moduleID)
        XCTAssertEqual(switcher.hotkeyStatus, .failed(SwitcherShortcut.defaultChord))
        XCTAssertTrue(reported.last??.contains("macOS refused") == true)
    }

    func testQuickSwitchGoesToThePreviousAppByActivationOrder() throws {
        try enable()
        activate(charlie)
        activate(bravo)
        XCTAssertEqual(registry.snapshot.apps.map(\.name), ["Bravo", "Charlie", "Alpha"])
        flags = []
        switcher.hotkeyPressed()
        XCTAssertEqual(activated, ["Charlie"])
        XCTAssertEqual(presenter.calls, [], "a quick tap never shows the panel")

        // Charlie is now frontmost; the previous app is Bravo again.
        activate(charlie)
        switcher.hotkeyPressed()
        XCTAssertEqual(activated, ["Charlie", "Bravo"])
    }

    func testHeldCyclingRevealAndReleaseCommit() throws {
        try enable()
        flags = .option
        // The registered action is the first press; the second moves on.
        press?()
        switcher.hotkeyPressed()
        XCTAssertEqual(presenter.calls, ["present"])
        XCTAssertEqual(switcher.state.selectedItem?.name, "Charlie", "a second press moved on")
        switcher.revealDue()
        XCTAssertEqual(presenter.calls, ["present", "reveal"])
        XCTAssertEqual(presenter.announcements, ["Charlie"])
        XCTAssertTrue(switcher.keyPressed(.previous))
        XCTAssertEqual(switcher.state.selectedItem?.name, "Bravo")
        switcher.modifiersChanged([.option, .shift])
        XCTAssertTrue(switcher.state.isOpen, "Shift alone changes nothing")
        switcher.modifiersChanged([.shift])
        XCTAssertEqual(presenter.calls.last, "dismiss")
        XCTAssertEqual(activated, ["Bravo"])
        XCTAssertFalse(switcher.keyPressed(.next), "closed: keys pass through")
    }

    func testReleaseMissedBeforeTheReveal() throws {
        // ⌥ let go before the panel took key: the event went to the other app.
        try enable()
        flags = .option
        switcher.hotkeyPressed()
        flags = []
        switcher.revealDue()
        XCTAssertEqual(presenter.calls, ["present", "dismiss"], "committed without ever revealing")
        XCTAssertEqual(activated, ["Bravo"])
    }

    func testEscapeAndFocusLossCancel() throws {
        try enable()
        flags = .option
        switcher.hotkeyPressed()
        switcher.revealDue()
        switcher.keyPressed(.next)
        switcher.keyPressed(.cancel)
        XCTAssertEqual(presenter.calls.last, "dismiss")
        switcher.modifiersChanged([])
        XCTAssertEqual(activated, [], "Escape leaves the frontmost app in front")

        switcher.hotkeyPressed()
        switcher.focusLost()
        switcher.modifiersChanged([])
        XCTAssertEqual(activated, [])
        XCTAssertFalse(switcher.state.isOpen)
    }

    func testAppQuitWhileOpenAndEveryAppQuit() throws {
        try enable()
        flags = .option
        switcher.hotkeyPressed()
        switcher.revealDue()
        XCTAssertEqual(switcher.state.selectedItem?.name, "Bravo")
        registry.appTerminated(bravo)
        XCTAssertEqual(switcher.state.items.map(\.name), ["Alpha", "Charlie"])
        XCTAssertEqual(switcher.state.selectedItem?.name, "Charlie")
        XCTAssertEqual(presenter.announcements.last, "Charlie")
        registry.appTerminated(charlie)
        registry.appTerminated(alpha)
        XCTAssertFalse(switcher.state.isOpen, "nothing left to switch to")
        XCTAssertEqual(presenter.calls.last, "dismiss")
        XCTAssertEqual(activated, [])
    }

    func testStaleTargetIsNotActivated() throws {
        try enable()
        flags = .option
        switcher.hotkeyPressed()
        // The app quit, and the registry has not heard yet when activation
        // refuses it: nothing comes forward and nothing crashes.
        refuseActivation = true
        switcher.modifiersChanged([])
        XCTAssertEqual(activated, [])
        XCTAssertFalse(switcher.state.isOpen)
    }

    func testSameApplicationActivatesNothing() throws {
        try enable()
        flags = .option
        switcher.hotkeyPressed()
        switcher.keyPressed(.first)
        switcher.keyPressed(.commit)
        XCTAssertEqual(activated, [])
        XCTAssertEqual(presenter.calls, ["present", "dismiss"])
    }

    func testClickChoosesThatApp() throws {
        try enable()
        flags = .option
        switcher.hotkeyPressed()
        switcher.revealDue()
        let charlieKey = try XCTUnwrap(switcher.state.items.first { $0.name == "Charlie" }?.key)
        switcher.choose(.app(charlieKey))
        XCTAssertEqual(activated, ["Charlie"])
    }

    // MARK: Native parity (P2-SW-01-PARITY-A)

    func testEscapeWithTheModifierHeldCancelsThroughItsOwnChord() throws {
        // ⌥Esc never reaches a window when macOS owns it (Spoken Content).
        try enable()
        XCTAssertFalse(held.contains(optionEscape), "only while open")
        flags = .option
        switcher.hotkeyPressed()
        XCTAssertTrue(held.contains(optionEscape))
        switcher.revealDue()
        actionsByChord[optionEscape]?()
        XCTAssertFalse(switcher.state.isOpen)
        XCTAssertFalse(held.contains(optionEscape), "released with the panel")
        switcher.modifiersChanged([], keyCode: UInt16(kVK_Option))
        XCTAssertEqual(activated, [], "the later release commits nothing")
        XCTAssertEqual(held, [SwitcherShortcut.defaultChord])
    }

    func testRepeatedQuickTapsAlternateBeforeMacOSReportsTheSwitch() throws {
        // Launch Services answers after the next tap can arrive: the
        // registry and the frontmost app still say Alpha.
        try enable()
        flags = []
        switcher.hotkeyPressed()
        switcher.hotkeyPressed()
        switcher.hotkeyPressed()
        XCTAssertEqual(activated, ["Bravo", "Alpha", "Bravo"], "the previous two apps, every time")
        XCTAssertEqual(switcher.requested.map(\.pid), [20, 10, 20])
        // The reports arrive late and in order; nothing is taken for another app.
        activate(bravo)
        activate(alpha)
        activate(bravo)
        XCTAssertEqual(switcher.requested, [])
        switcher.hotkeyPressed()
        XCTAssertEqual(activated.last, "Alpha")
    }

    func testOwnActivationLandingWhileOpenKeepsTheSwitcher() throws {
        try enable()
        flags = []
        switcher.hotkeyPressed()
        XCTAssertEqual(activated, ["Bravo"])
        flags = .option
        switcher.hotkeyPressed()
        XCTAssertTrue(switcher.state.isOpen)
        XCTAssertEqual(switcher.state.selectedItem?.name, "Alpha", "Bravo counts as frontmost already")
        activate(bravo)
        XCTAssertTrue(switcher.state.isOpen, "our own switch arriving is not the person leaving")
        XCTAssertTrue(switcher.panelLostKey(), "Bravo taking key: keep the panel and take key back")
        switcher.modifiersChanged([], keyCode: UInt16(kVK_Option))
        XCTAssertEqual(activated, ["Bravo", "Alpha"])
    }

    func testAnotherAppActivatingOrTakingKeyCancels() throws {
        try enable()
        flags = .option
        switcher.hotkeyPressed()
        activate(charlie)
        XCTAssertFalse(switcher.state.isOpen, "a click on another app cancels")
        XCTAssertEqual(activated, [])
        switcher.hotkeyPressed()
        XCTAssertFalse(switcher.panelLostKey(), "key lost with nothing of ours arriving")
        XCTAssertFalse(switcher.state.isOpen)
        XCTAssertEqual(activated, [])
    }

    func testReleaseMissedWhileThePanelTookKeyIsNotTakenForNext() throws {
        // ⌥ went up (and down again) before the panel could hear it; the
        // next press must be a new tap, not "move to the third app".
        try enable()
        flags = .option
        pressAt = 10.000
        switcher.hotkeyPressed()
        XCTAssertTrue(switcher.state.isOpen)
        modifierChangedAt = 10.040
        pressAt = 10.120
        clock = 10.130
        switcher.hotkeyPressed()
        XCTAssertEqual(activated, ["Bravo"], "the first tap committed")
        XCTAssertTrue(switcher.state.isOpen, "this press opened a new switcher")
        XCTAssertEqual(switcher.state.selectedItem?.name, "Alpha", "the previous app again, not Charlie")
    }

    func testHeldModifierStillCyclesAndShiftDoesNotCommit() throws {
        try enable()
        flags = .option
        modifierChangedAt = 9.9
        pressAt = 10
        switcher.hotkeyPressed()
        pressAt = 10.3
        switcher.hotkeyPressed()
        XCTAssertEqual(switcher.state.selectedItem?.name, "Charlie", "held throughout: moves on")
        // Shift for reverse reached the panel; that change is not a release.
        modifierChangedAt = 10.4
        switcher.modifiersChanged([.option, .shift], keyCode: UInt16(kVK_Shift), timestamp: 10.4)
        pressAt = 10.5
        switcher.hotkeyPressed()
        XCTAssertTrue(switcher.state.isOpen)
        XCTAssertEqual(activated, [])
        XCTAssertEqual(switcher.state.selectedItem?.name, "Alpha", "wrapped, still the same switcher")
    }

    func testRepressOfTheModifierCommitsTheMissedRelease() throws {
        try enable()
        flags = .option
        switcher.hotkeyPressed()
        switcher.modifiersChanged(.option, keyCode: UInt16(kVK_Option), timestamp: 10.05)
        XCTAssertFalse(switcher.state.isOpen)
        XCTAssertEqual(activated, ["Bravo"])
    }

    func testPanelBecomingKeyCatchesAnEarlierRelease() throws {
        try enable()
        flags = .option
        switcher.hotkeyPressed()
        flags = []
        switcher.panelBecameKey()
        XCTAssertEqual(activated, ["Bravo"], "no wait for the 100 ms reveal")
        XCTAssertEqual(presenter.calls, ["present", "dismiss"])
    }

    func testHoverSelectsOnlyAfterThePointerMoves() throws {
        try enable()
        flags = .option
        switcher.hotkeyPressed()
        switcher.revealDue()
        let charlieKey = try XCTUnwrap(switcher.state.items.first { $0.name == "Charlie" }?.key)
        switcher.hovered(.app(charlieKey))
        XCTAssertEqual(switcher.state.selectedItem?.name, "Bravo", "a tile under a resting pointer is not chosen")
        pointer = NSPoint(x: 140, y: 100)
        switcher.hovered(.app(charlieKey))
        XCTAssertEqual(switcher.state.selectedItem?.name, "Charlie")
        XCTAssertEqual(presenter.announcements.last, "Charlie")
        switcher.keyPressed(.previous)
        let alphaKey = try XCTUnwrap(switcher.state.items.first { $0.name == "Alpha" }?.key)
        switcher.hovered(.app(alphaKey))
        XCTAssertEqual(switcher.state.selectedItem?.name, "Bravo", "keys moved the selection and the pointer has not moved since")
        switcher.keyPressed(.next)
        switcher.modifiersChanged([], keyCode: UInt16(kVK_Option))
        XCTAssertEqual(activated, ["Charlie"], "letting go switches to the hovered app")
    }

    func testRefusedLaunchServicesRequestIsForgotten() throws {
        try enable()
        flags = []
        switcher.hotkeyPressed()
        XCTAssertEqual(switcher.requested.map(\.pid), [20])
        activationFailed?()
        XCTAssertEqual(switcher.requested, [])
        switcher.hotkeyPressed()
        XCTAssertEqual(activated, ["Bravo", "Bravo"], "Alpha is still frontmost, so Bravo is still the previous app")
    }
}

/// Telling a press after a missed release from the other key of the pair.
final class SwitcherRepressTests: XCTestCase {
    private let option = NSEvent.ModifierFlags.option
    private func flags(_ extra: UInt) -> NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: option.rawValue | extra) }

    func testRepressRules() {
        let left = UInt16(kVK_Option), right = UInt16(kVK_RightOption)
        XCTAssertTrue(SwitcherModifiers.isRepress(keyCode: left, flags: option, required: option), "no device bits: a press")
        XCTAssertTrue(SwitcherModifiers.isRepress(keyCode: left, flags: flags(0x20), required: option), "left alone went down")
        XCTAssertFalse(SwitcherModifiers.isRepress(keyCode: right, flags: flags(0x60), required: option), "right pressed while left held")
        XCTAssertFalse(SwitcherModifiers.isRepress(keyCode: right, flags: flags(0x20), required: option), "right let go, left still held")
        XCTAssertFalse(SwitcherModifiers.isRepress(keyCode: left, flags: [], required: option), "a release")
        XCTAssertFalse(SwitcherModifiers.isRepress(keyCode: UInt16(kVK_Shift), flags: [.option, .shift], required: option))
        XCTAssertFalse(SwitcherModifiers.isRepress(keyCode: UInt16(kVK_Command), flags: [.option, .command], required: option), "not required")
    }
}
