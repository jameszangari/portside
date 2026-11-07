import AppKit
import Carbon.HIToolbox
import Combine
import XCTest
@testable import portside

/// Command Center state machine (P2-REA-01 contract): open, toggle, query,
/// navigation, the Escape ladder, running and cancel, Action Panel, screens.
final class CommandCenterStateTests: XCTestCase {
    private func id(_ raw: String) -> CommandID { CommandID(raw)! }

    private var settings: CommandCenterItem {
        CommandCenterItem(id: id("portside.openSettings"), title: "Open Settings", subtitle: "Portside", keywords: ["preferences"])
    }
    private var hiding: CommandCenterItem {
        CommandCenterItem(id: id("portside.toggleDockHiding"), title: "Toggle Dock Hiding", subtitle: "Portside", keywords: ["autohide"])
    }
    private var about: CommandCenterItem {
        CommandCenterItem(id: id("portside.showAbout"), title: "About Portside", subtitle: "Portside")
    }
    private var blocked: CommandCenterItem {
        CommandCenterItem(id: id("other.blocked"), title: "Blocked Thing", subtitle: "Other",
                          unavailableReason: "Other is turned off.")
    }
    private var items: [CommandCenterItem] { [settings, hiding, about, blocked] }

    /// Open with the fixture and return the state.
    private func opened(_ items: [CommandCenterItem]? = nil) -> CommandCenterState {
        var state = CommandCenterState()
        _ = state.send(.open(items ?? self.items))
        return state
    }

    private func key(_ state: inout CommandCenterState, _ key: CommandCenterKey) -> CommandCenterOutcome {
        state.send(.key(key))
    }

    private func dismissed(_ outcome: CommandCenterOutcome) -> Bool? {
        for case .dismiss(let restore) in outcome.effects { return restore }
        return nil
    }

    // MARK: Open, toggle, dismiss

    func testOpenShowsSortedResultsAndSelectsFirst() {
        var state = CommandCenterState()
        XCTAssertEqual(state.mode, .hidden)
        let outcome = state.send(.open(items))
        XCTAssertEqual(outcome.effects.first, .present)
        XCTAssertEqual(state.mode, .searching)
        XCTAssertEqual(state.results.map(\.title), ["About Portside", "Blocked Thing", "Open Settings", "Toggle Dock Hiding"])
        XCTAssertEqual(state.selection, about.id)
    }

    func testOpenWhileVisibleRefocusesInsteadOfResetting() {
        var state = opened()
        _ = state.send(.query("open"))
        let outcome = state.send(.open(items))
        XCTAssertEqual(outcome.effects, [.focusPanel])
        XCTAssertEqual(state.query, "open")
    }

    func testHotkeyTogglesAndDoublePressEndsHidden() {
        var state = CommandCenterState()
        XCTAssertEqual(state.send(.hotkey(items, panelIsKey: false)).effects.first, .present)
        XCTAssertTrue(state.isVisible)
        let second = state.send(.hotkey(items, panelIsKey: true))
        XCTAssertEqual(dismissed(second), true)
        XCTAssertEqual(state, CommandCenterState())
        // A third press opens again from a clean state.
        _ = state.send(.hotkey(items, panelIsKey: false))
        XCTAssertEqual(state.query, "")
        XCTAssertTrue(state.stack.isEmpty)
    }

    func testHotkeyWhileVisibleButNotKeyTakesKeyBack() {
        var state = opened()
        XCTAssertEqual(state.send(.hotkey(items, panelIsKey: false)).effects, [.focusPanel])
        XCTAssertTrue(state.isVisible)
    }

    func testFocusLostHidesWithoutRestoreOrCancel() {
        var state = opened()
        _ = key(&state, .down)
        _ = key(&state, .down)
        _ = key(&state, .return)
        XCTAssertEqual(state.mode, .running)
        let outcome = state.send(.focusLost)
        XCTAssertEqual(outcome.effects, [.dismiss(restoreFocus: false)])
        XCTAssertFalse(state.isVisible)
        // The late result of the abandoned run is dropped.
        XCTAssertFalse(state.send(.finished(settings.id, .success(nil))).handled)
        XCTAssertFalse(state.send(.focusLost).handled)
    }

    func testEventsWhileHiddenAreIgnored() {
        var state = CommandCenterState()
        XCTAssertFalse(state.send(.key(.escape)).handled)
        XCTAssertFalse(state.send(.query("x")).handled)
        XCTAssertFalse(state.send(.toggleActions).handled)
        XCTAssertEqual(state, CommandCenterState())
    }

    // MARK: Query

    func testQueryFiltersByWordPrefixAndKeywordsAndResetsSelection() {
        var state = opened()
        _ = key(&state, .down)
        _ = state.send(.query("dock"))
        XCTAssertEqual(state.results.map(\.id), [hiding.id])
        XCTAssertEqual(state.selection, hiding.id)
        _ = state.send(.query("PREF"))
        XCTAssertEqual(state.results.map(\.id), [settings.id], "keywords match, case insensitive")
        _ = state.send(.query("set op"))
        XCTAssertEqual(state.results.map(\.id), [settings.id], "every word must match, any order")
        _ = state.send(.query("zzz"))
        XCTAssertTrue(state.results.isEmpty)
        XCTAssertNil(state.selection)
        XCTAssertEqual(key(&state, .return).effects, [], "Return with no selection does nothing")
    }

    func testTitlePrefixMatchesComeFirstAndOrderIsDeterministic() {
        let twin = CommandCenterItem(id: id("aaa.portside"), title: "About Portside", subtitle: "A")
        var first = opened(items + [twin])
        var second = opened((items + [twin]).reversed())
        _ = first.send(.query("portside"))
        _ = second.send(.query("portside"))
        XCTAssertEqual(first.results.map(\.id), second.results.map(\.id))
        XCTAssertEqual(first.results.map(\.id), [twin.id, about.id], "equal titles break by ID")
        // A title that starts with the query outranks a keyword match that sorts earlier.
        let addApps = CommandCenterItem(id: id("portside.addApps"), title: "Add Apps", keywords: ["dock"])
        let position = CommandCenterItem(id: id("portside.dockPosition"), title: "Dock Position")
        var ranked = opened([addApps, position])
        _ = ranked.send(.query("dock"))
        XCTAssertEqual(ranked.results.map(\.id), [position.id, addApps.id])
        XCTAssertEqual(CommandCenterState.filter(items, query: "  "), items, "blank query keeps everything")
    }

    func testLatestQueryWins() {
        var state = opened()
        for text in ["t", "to", "tog", "togg", "o", "op", "ope", "open"] { _ = state.send(.query(text)) }
        XCTAssertEqual(state.query, "open")
        XCTAssertEqual(state.results.map(\.id), [settings.id])
    }

    /// T-05 fixture: 1,000 commands, ten fast edits; only the last query's
    /// results show, in the same order every time.
    func testThousandCommandsFastTypingLatestWinsDeterministically() {
        let many = (0..<1000).map { n in
            CommandCenterItem(id: id("fixture.cmd\(n)"), title: "Command \(n % 10 == 0 ? "Alpha" : "Beta") \(n)")
        }
        var state = opened(many)
        var replay = opened(many.shuffled())
        for text in ["a", "al", "alp", "alph", "alpha", "alpha ", "alpha 9", "alpha 99", "alpha 9", "alpha 99"] {
            _ = state.send(.query(text))
            _ = replay.send(.query(text))
        }
        XCTAssertEqual(state.results.map(\.id.rawValue), ["fixture.cmd990"])
        _ = state.send(.query("alpha"))
        _ = replay.send(.query("alpha"))
        XCTAssertEqual(state.results.count, 100)
        XCTAssertEqual(state.results.map(\.id), replay.results.map(\.id))
    }

    // MARK: Navigation

    func testArrowsAndEmacsKeysMoveAndClamp() {
        var state = opened()
        XCTAssertEqual(key(&state, .up).effects, [], "already at the top")
        XCTAssertEqual(state.selection, about.id)
        _ = key(&state, .down)
        XCTAssertEqual(state.selection, blocked.id)
        let announcement = key(&state, .down)
        XCTAssertEqual(state.selection, settings.id)
        XCTAssertEqual(announcement.effects, [.announce("Open Settings, 3 of 4")])
        _ = key(&state, .down)
        XCTAssertEqual(key(&state, .down).effects, [], "clamps at the end, no wrap")
        XCTAssertEqual(state.selection, hiding.id)
        _ = key(&state, .up)
        XCTAssertEqual(state.selection, settings.id)
    }

    func testTabIsLeftToTheKeyViewLoop() {
        var state = opened()
        let before = state
        XCTAssertFalse(key(&state, .tab).handled)
        XCTAssertEqual(state, before)
    }

    func testBackspaceOnRootIsLeftToTheField() {
        var state = opened()
        XCTAssertFalse(key(&state, .backspace).handled)
        XCTAssertTrue(state.isVisible)
    }

    // MARK: Running

    func testReturnRunsSelectionAndSuccessDismissesWithoutRestore() {
        var state = opened()
        _ = state.send(.query("open"))
        XCTAssertEqual(key(&state, .return).effects, [.run(settings.id)])
        XCTAssertEqual(state.mode, .running)
        XCTAssertEqual(key(&state, .down).effects, [], "keys wait for the result")
        XCTAssertEqual(key(&state, .return).effects, [], "never runs twice")
        let done = state.send(.finished(settings.id, .success(nil)))
        XCTAssertEqual(done.effects, [.dismiss(restoreFocus: false)])
        XCTAssertFalse(state.isVisible)
    }

    func testReturnOnUnavailableRowShowsReasonAndStaysOpen() {
        var state = opened()
        _ = key(&state, .down)
        XCTAssertEqual(state.selection, blocked.id)
        let outcome = key(&state, .return)
        XCTAssertFalse(outcome.effects.contains(.run(blocked.id)))
        XCTAssertEqual(state.notice, CommandCenterNotice(kind: .unavailable, message: "Other is turned off."))
        XCTAssertEqual(state.mode, .searching)
        // Moving on clears the notice.
        _ = key(&state, .down)
        XCTAssertNil(state.notice)
    }

    func testFailureAndLateUnavailabilityKeepPanelOpenWithReason() {
        var state = opened()
        _ = state.send(.activate(hiding.id))
        _ = state.send(.finished(hiding.id, .failed("Dock is busy.")))
        XCTAssertEqual(state.notice, CommandCenterNotice(kind: .failed, message: "Dock is busy."))
        XCTAssertEqual(state.mode, .searching)

        _ = state.send(.activate(hiding.id))
        _ = state.send(.finished(hiding.id, .unavailable("Portside is still starting.")))
        XCTAssertEqual(state.item(hiding.id)?.unavailableReason, "Portside is still starting.", "row shows it too")
        XCTAssertEqual(state.selection, hiding.id)
        XCTAssertEqual(key(&state, .return).effects.filter { if case .run = $0 { return true } else { return false } }, [])
    }

    func testEscapeCancelsRunAndCanceledResultStaysOpen() {
        var state = opened()
        _ = state.send(.query("open settings"))
        _ = key(&state, .return)
        XCTAssertEqual(key(&state, .escape).effects, [.cancelRun])
        XCTAssertEqual(state.mode, .running, "running until the handler reports")
        _ = state.send(.finished(settings.id, .canceled))
        XCTAssertEqual(state.notice?.kind, .canceled)
        XCTAssertEqual(state.mode, .searching)
        XCTAssertEqual(state.query, "open settings", "cancel keeps the query")
    }

    func testStaleResultForAnotherCommandIsIgnored() {
        var state = opened()
        _ = state.send(.activate(settings.id))
        XCTAssertFalse(state.send(.finished(hiding.id, .success(nil))).handled)
        XCTAssertEqual(state.running, settings.id)
    }

    func testHotkeyWhileRunningCancelsAndHides() {
        var state = opened()
        _ = state.send(.activate(settings.id))
        let outcome = state.send(.hotkey(items, panelIsKey: true))
        XCTAssertEqual(outcome.effects, [.cancelRun, .dismiss(restoreFocus: true)])
    }

    // MARK: Escape ladder

    func testEscapeLadderTakesOneStepPerPress() {
        var state = opened()
        _ = state.send(.query("open"))
        _ = key(&state, .commandReturn) // details screen
        XCTAssertEqual(state.stack, [.details(settings.id)])
        _ = key(&state, .commandK)      // Action Panel over the screen
        XCTAssertEqual(state.mode, .actions)

        XCTAssertNil(dismissed(key(&state, .escape)))
        XCTAssertEqual(state.mode, .screen, "1: Action Panel closes")
        XCTAssertNil(dismissed(key(&state, .escape)))
        XCTAssertEqual(state.mode, .searching, "2: screen pops")
        XCTAssertEqual(state.query, "open")
        XCTAssertNil(dismissed(key(&state, .escape)))
        XCTAssertEqual(state.query, "", "3: query clears")
        XCTAssertEqual(state.results.count, items.count)
        XCTAssertEqual(dismissed(key(&state, .escape)), true, "4: window closes and restores focus")
        XCTAssertFalse(state.isVisible)
    }

    func testCommandEscapeClosesFromAnywhere() {
        var state = opened()
        _ = state.send(.query("open"))
        _ = key(&state, .commandReturn)
        _ = key(&state, .commandK)
        XCTAssertEqual(key(&state, .commandEscape).effects, [.dismiss(restoreFocus: true)])
        XCTAssertEqual(state, CommandCenterState())
    }

    // MARK: Action Panel and screens

    func testCommandKTogglesActionPanelAndKeepsSelection() {
        var state = opened()
        _ = key(&state, .down)
        _ = key(&state, .down)
        _ = key(&state, .commandK)
        XCTAssertEqual(state.actionPanel?.itemID, settings.id)
        XCTAssertEqual(state.visibleActions.map(\.kind), [.run, .showDetails, .copyID])
        XCTAssertEqual(state.actionPanel?.highlight, .run)
        _ = key(&state, .commandK)
        XCTAssertNil(state.actionPanel)
        XCTAssertEqual(state.selection, settings.id)
    }

    func testCommandKWithNoSelectionIsIgnored() {
        var state = opened()
        _ = state.send(.query("zzz"))
        XCTAssertEqual(key(&state, .commandK).effects, [])
        XCTAssertNil(state.actionPanel)
    }

    func testActionPanelNavigationFilterAndRun() {
        var state = opened()
        _ = state.send(.query("open"))
        _ = key(&state, .commandK)
        _ = key(&state, .down)
        XCTAssertEqual(state.actionPanel?.highlight, .showDetails)
        _ = key(&state, .down)
        _ = key(&state, .down)
        XCTAssertEqual(state.actionPanel?.highlight, .copyID, "clamps")
        _ = state.send(.actionQuery("det"))
        XCTAssertEqual(state.visibleActions.map(\.kind), [.showDetails])
        XCTAssertEqual(state.actionPanel?.highlight, .showDetails)
        _ = state.send(.actionQuery("nothing"))
        XCTAssertTrue(state.visibleActions.isEmpty)
        XCTAssertEqual(key(&state, .return).effects, [], "nothing highlighted")
        _ = state.send(.actionQuery(""))
        XCTAssertEqual(key(&state, .return).effects, [.run(settings.id)], "Return runs the highlighted action")
        XCTAssertNil(state.actionPanel)
    }

    func testRunActionOnUnavailableItemShowsReason() {
        var state = opened()
        _ = key(&state, .down)
        _ = key(&state, .commandK)
        XCTAssertEqual(state.visibleActions.first?.disabledReason, "Other is turned off.")
        _ = key(&state, .return)
        XCTAssertNil(state.running)
        XCTAssertEqual(state.notice?.kind, .unavailable)
    }

    func testCopyActionCopiesAndDismisses() {
        var state = opened()
        _ = key(&state, .commandK)
        _ = state.send(.performAction(.copyID))
        XCTAssertFalse(state.isVisible)
    }

    func testCopyActionEffects() {
        var state = opened()
        _ = key(&state, .commandK)
        XCTAssertEqual(state.send(.performAction(.copyID)).effects, [.copy(about.id.rawValue), .dismiss(restoreFocus: true)])
    }

    func testDetailsScreenRunsItsItemAndPopsWithBackspaceOrBack() {
        var state = opened()
        _ = key(&state, .commandK)
        _ = state.send(.performAction(.showDetails))
        XCTAssertEqual(state.mode, .screen)
        XCTAssertEqual(state.targetItem?.id, about.id)
        XCTAssertFalse(state.visibleActions.contains { $0.kind == .showDetails })
        _ = key(&state, .commandK)
        XCTAssertFalse(state.visibleActions.contains { $0.kind == .showDetails }, "no details-of-details")
        _ = key(&state, .commandK)
        XCTAssertEqual(key(&state, .commandReturn).effects, [], "no secondary on its own details")
        XCTAssertEqual(key(&state, .up).effects, [], "nothing to move on a details screen")
        XCTAssertTrue(key(&state, .backspace).handled)
        XCTAssertEqual(state.mode, .searching)
        _ = key(&state, .commandReturn)
        XCTAssertTrue(state.send(.back).handled)
        XCTAssertEqual(state.mode, .searching)
        _ = key(&state, .commandReturn)
        XCTAssertEqual(key(&state, .return).effects, [.run(about.id)])
    }

    func testClickRowClosesPanelsAndRuns() {
        var state = opened()
        _ = key(&state, .commandK)
        XCTAssertEqual(state.send(.activate(hiding.id)).effects, [.run(hiding.id)])
        XCTAssertNil(state.actionPanel)
        XCTAssertEqual(state.selection, hiding.id)
        XCTAssertFalse(state.send(.activate(blocked.id)).handled, "ignored while running")
    }

    // MARK: Keys

    func testKeyMapping() {
        func map(_ code: Int, _ flags: NSEvent.ModifierFlags = [], _ chars: String? = nil, composing: Bool = false) -> CommandCenterKey? {
            CommandCenterKey(keyCode: UInt16(code), modifiers: flags, characters: chars, isComposing: composing)
        }
        XCTAssertEqual(map(kVK_UpArrow, [.numericPad, .function]), .up, "arrow flags are ignored")
        XCTAssertEqual(map(kVK_DownArrow), .down)
        XCTAssertNil(map(kVK_DownArrow, .shift))
        XCTAssertEqual(map(kVK_ANSI_N, .control, "n"), .down)
        XCTAssertEqual(map(kVK_ANSI_P, .control, "p"), .up)
        XCTAssertEqual(map(kVK_Return), .return)
        XCTAssertEqual(map(kVK_ANSI_KeypadEnter), .return)
        XCTAssertEqual(map(kVK_Return, .command), .commandReturn)
        XCTAssertNil(map(kVK_Return, .option), "Option+Return is not bound in CMD-01")
        XCTAssertEqual(map(kVK_Escape), .escape)
        XCTAssertEqual(map(kVK_Escape, .command), .commandEscape)
        XCTAssertEqual(map(kVK_ANSI_K, .command, "k"), .commandK)
        // Dvorak: the K character sits on another key code.
        XCTAssertEqual(map(kVK_ANSI_V, .command, "k"), .commandK)
        XCTAssertNil(map(kVK_ANSI_K, [], "k"), "typing k is text")
        XCTAssertEqual(map(kVK_Tab), .tab)
        XCTAssertEqual(map(kVK_Tab, .shift), .tab)
        XCTAssertEqual(map(kVK_Delete), .backspace)
        XCTAssertNil(map(kVK_Delete, .option), "Option-Delete deletes a word in the field")
    }

    func testIMECompositionPassesEveryKeyThrough() {
        for code in [kVK_Return, kVK_Escape, kVK_UpArrow, kVK_DownArrow, kVK_Delete, kVK_Tab] {
            XCTAssertNil(CommandCenterKey(keyCode: UInt16(code), modifiers: [], characters: nil, isComposing: true))
        }
    }
}

final class CommandCenterFocusTests: XCTestCase {
    func testRestoreOnlyWhenPortsideTookActivation() {
        let own: pid_t = 10, previous: pid_t = 20, other: pid_t = 30
        XCTAssertTrue(CommandCenter.shouldRestoreFocus(requested: true, previousPID: previous, frontmostPID: own, ownPID: own))
        XCTAssertFalse(CommandCenter.shouldRestoreFocus(requested: true, previousPID: previous, frontmostPID: previous, ownPID: own),
                       "still frontmost: ordering out is enough")
        XCTAssertFalse(CommandCenter.shouldRestoreFocus(requested: true, previousPID: previous, frontmostPID: other, ownPID: own),
                       "another app took over: do not steal focus back")
        XCTAssertFalse(CommandCenter.shouldRestoreFocus(requested: false, previousPID: previous, frontmostPID: own, ownPID: own),
                       "a launched command keeps its focus")
        XCTAssertFalse(CommandCenter.shouldRestoreFocus(requested: true, previousPID: nil, frontmostPID: own, ownPID: own),
                       "previous app quit")
        XCTAssertFalse(CommandCenter.shouldRestoreFocus(requested: true, previousPID: own, frontmostPID: own, ownPID: own),
                       "opened over Portside's own Settings")
    }
}

@MainActor
final class CommandCenterHotkeyTests: XCTestCase {
    private final class Token {}

    private var registered: [HotkeyChord] = []
    private var live: [HotkeyChord: () -> Void] = [:]
    private var refuse: Set<HotkeyChord> = []
    private var reports: [String?] = []
    private var presses = 0

    private func makeHotkey() -> CommandCenterHotkey {
        CommandCenterHotkey(
            registrar: { [unowned self] chord, action in
                registered.append(chord)
                guard !refuse.contains(chord) else { return nil }
                live[chord] = action
                return Token()
            },
            report: { [unowned self] in reports.append($0) },
            onPress: { [unowned self] in presses += 1 }
        )
    }

    func testRegisterIsIdempotentAndClearUnregisters() {
        let hotkey = makeHotkey()
        let chord = HotkeyChord.commandCenterDefault
        hotkey.update(chord)
        hotkey.update(chord)
        XCTAssertEqual(registered, [chord], "same chord registers once")
        XCTAssertEqual(hotkey.status, .registered(chord))
        live[chord]?()
        XCTAssertEqual(presses, 1)
        hotkey.update(nil)
        XCTAssertEqual(hotkey.status, .off)
        hotkey.update(nil)
        XCTAssertEqual(registered.count, 1)
    }

    func testChangeReplacesAndFailureIsReported() {
        let hotkey = makeHotkey()
        let first = HotkeyChord.commandCenterDefault
        let taken = HotkeyChord(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey))
        refuse = [taken]
        hotkey.update(first)
        hotkey.update(taken)
        XCTAssertEqual(hotkey.status, .failed(taken))
        XCTAssertNotNil(reports.last ?? nil)
        // Retrying the refused chord tries again; a working one clears the report.
        hotkey.update(taken)
        XCTAssertEqual(registered, [first, taken, taken])
        hotkey.update(first)
        XCTAssertEqual(hotkey.status, .registered(first))
        XCTAssertNil(reports.last ?? "x")
    }

    func testUnregisterableChordStaysOff() {
        let hotkey = makeHotkey()
        hotkey.update(HotkeyChord(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey)))
        XCTAssertEqual(hotkey.status, .off)
        XCTAssertTrue(registered.isEmpty)
    }

    /// Real Carbon round trip on an unlikely chord: register, refuse a second
    /// holder, release on deinit, register again.
    func testCarbonRegistrationLifecycle() throws {
        let chord = HotkeyChord(keyCode: UInt32(kVK_F19), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        var first: HotKey? = HotKey(chord: chord, name: "test") {}
        guard first != nil else { throw XCTSkip("Carbon hotkeys unavailable in this session") }
        XCTAssertNil(HotKey(chord: chord, name: "test duplicate") {}, "the same chord cannot be held twice")
        first = nil
        XCTAssertNotNil(HotKey(chord: chord, name: "test again") {}, "deinit released it")
    }

    /// The recorder suspends every hotkey so it can capture chords Portside
    /// holds: while suspended the chord is free, after resume it is held again.
    func testSuspendFreesChordsForTheRecorderAndResumeRestores() throws {
        let chord = HotkeyChord(keyCode: UInt32(kVK_F18), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        let held = HotKey(chord: chord, name: "test held") {}
        guard held != nil else { throw XCTSkip("Carbon hotkeys unavailable in this session") }
        HotKey.setSuspended(true)
        defer { HotKey.setSuspended(false) }
        var probe: HotKey? = HotKey(chord: chord, name: "test probe") {}
        XCTAssertNotNil(probe, "suspended: the chord is free")
        probe = nil
        HotKey.setSuspended(false)
        XCTAssertNil(HotKey(chord: chord, name: "test duplicate") {}, "resumed: held again")
        withExtendedLifetime(held) {}
    }
}

final class HotkeyConflictTests: XCTestCase {
    private let optionSpace = HotkeyChord.commandCenterDefault
    private let spotlight = HotkeyChord(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))

    func testOptionSpaceIsRegisterableButOptionLetterIsNot() {
        XCTAssertTrue(optionSpace.isRegisterable)
        XCTAssertTrue(HotkeyChord(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey)).isRegisterable)
        XCTAssertFalse(HotkeyChord(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(optionKey)).isRegisterable)
        XCTAssertFalse(HotkeyChord(keyCode: UInt32(kVK_Space), modifiers: 0).isRegisterable)
        XCTAssertEqual(optionSpace.displayString, "⌥Space")
    }

    func testEnabledSystemShortcutConflicts() {
        let system = [SymbolicHotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey), enabled: true)]
        let message = HotkeyConflicts.conflict(for: spotlight, system: system, portside: [])
        XCTAssertTrue(message?.contains("Spotlight") == true)
        XCTAssertTrue(message?.contains("does not change it") == true)
        XCTAssertNil(HotkeyConflicts.conflict(for: optionSpace, system: system, portside: []))
    }

    func testDisabledSystemShortcutDoesNotConflict() {
        let system = [SymbolicHotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey), enabled: false)]
        XCTAssertNil(HotkeyConflicts.conflict(for: spotlight, system: system, portside: []))
    }

    func testExtraModifierBitsAreIgnored() {
        // Symbolic hotkeys can carry bits beyond the four modifiers (fn, keypad).
        let system = [SymbolicHotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey) | 0x80_0000, enabled: true)]
        XCTAssertTrue(HotkeyConflicts.conflict(for: optionSpace, system: system, portside: [])?.contains("macOS shortcut") == true)
    }

    func testPortsideShortcutConflict() {
        let message = HotkeyConflicts.conflict(for: .settingsDefault, system: [], portside: [("Open Settings", .settingsDefault)])
        XCTAssertTrue(message?.contains("Open Settings") == true)
        XCTAssertNil(HotkeyConflicts.conflict(for: optionSpace, system: [], portside: [("Open Settings", nil)]))
    }

    func testSystemListIsReadable() {
        // Read only. On a normal Mac the list is non-empty; never fails the run.
        _ = HotkeyConflicts.systemHotkeys()
    }
}

final class CommandCenterSettingsTests: XCTestCase {
    private func model(_ json: String) throws -> DockModel {
        try JSONDecoder().decode(DockModel.self, from: Data(json.utf8))
    }

    func testMissingKeyKeepsDefaultNullClearsMalformedResets() throws {
        XCTAssertEqual(try model("{}").commandCenterHotkey, .commandCenterDefault)
        XCTAssertNil(try model(#"{"commandCenterHotkey": null}"#).commandCenterHotkey)
        XCTAssertEqual(try model(#"{"commandCenterHotkey": "space"}"#).commandCenterHotkey, .commandCenterDefault)
        let bareLetter = #"{"commandCenterHotkey": {"keyCode": 0, "modifiers": 2048}}"#
        XCTAssertEqual(try model(bareLetter).commandCenterHotkey, .commandCenterDefault)
        let custom = #"{"commandCenterHotkey": {"keyCode": 49, "modifiers": 4096}}"#
        XCTAssertEqual(try model(custom).commandCenterHotkey, HotkeyChord(keyCode: 49, modifiers: 4096))
    }

    func testRoundTripWritesNullWhenCleared() throws {
        let cleared = try model(#"{"commandCenterHotkey": null}"#)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cleared)) as? [String: Any])
        XCTAssertTrue(json["commandCenterHotkey"] is NSNull)
        XCTAssertNil(try JSONDecoder().decode(DockModel.self, from: JSONEncoder().encode(cleared)).commandCenterHotkey)
    }
}

/// The `commandCenter` module: off by default, owns the shortcut only while it runs.
@MainActor
final class CommandCenterModuleTests: XCTestCase {
    private final class Token {
        let onRelease: () -> Void
        init(onRelease: @escaping () -> Void) { self.onRelease = onRelease }
        deinit { onRelease() }
    }

    private var held: [HotkeyChord] = []
    private var registrations = 0
    private let chords = CurrentValueSubject<HotkeyChord?, Never>(.commandCenterDefault)
    private lazy var commands = CommandRegistry(permissions: PermissionGate())
    private lazy var registry = ModuleRegistry(commands: commands, permissions: PermissionGate())
    private lazy var center = CommandCenter(
        commands: commands,
        moduleTitle: { _ in nil },
        registrar: { [unowned self] chord, _ in
            registrations += 1
            held.append(chord)
            return Token { [unowned self] in held.removeAll { $0 == chord } }
        },
        report: { _ in }
    )

    private func register() throws {
        try registry.register(CommandCenterModule(center: center, chords: chords.eraseToAnyPublisher()))
    }

    func testOffByDefaultRegistersNothing() throws {
        try register()
        registry.enableSaved(ModuleSettings())
        XCTAssertEqual(registry.state(of: CommandCenterModule.moduleID), .disabled)
        XCTAssertFalse(center.isEnabled)
        XCTAssertEqual(registrations, 0)
        center.open()
        XCTAssertFalse(center.state.isVisible, "opening does nothing while off")
    }

    func testRunningFollowsTheSavedChordAndStopReleasesIt() throws {
        try register()
        registry.enable(CommandCenterModule.moduleID)
        XCTAssertEqual(registry.state(of: CommandCenterModule.moduleID), .running)
        XCTAssertEqual(held, [.commandCenterDefault])

        let other = HotkeyChord(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
        chords.send(other)
        XCTAssertEqual(held, [other], "the old chord is released before the new one")
        chords.send(nil)
        XCTAssertEqual(held, [], "cleared in Settings")
        chords.send(other)

        registry.disable(CommandCenterModule.moduleID)
        XCTAssertEqual(held, [])
        XCTAssertEqual(center.hotkeyStatus, .off)
        XCTAssertEqual(registry.resourceCount(of: CommandCenterModule.moduleID), 0)
        let before = registrations
        chords.send(.commandCenterDefault)
        XCTAssertEqual(registrations, before, "no subscription survives the stop")
    }

    func testNotSensitiveSoRestrictedModeKeepsIt() throws {
        try register()
        var saved = ModuleSettings()
        saved.setEnabled(true, for: CommandCenterModule.moduleID)
        registry.enableSaved(saved, restricted: true)
        XCTAssertEqual(registry.state(of: CommandCenterModule.moduleID), .running)
    }
}
