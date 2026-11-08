import AppKit
import Carbon.HIToolbox
import Combine
import XCTest
@testable import portside

private let alphaKey = AppKey(pid: 10, generation: 1)
private let bravoKey = AppKey(pid: 20, generation: 2)
private let charlieKey = AppKey(pid: 30, generation: 3)

private func appSnap(_ key: AppKey, _ name: String, access: WindowAccess = .ready, hidden: Bool = false) -> AppSnapshot {
    AppSnapshot(key: key, bundleIdentifier: "test.\(name)", name: name, isActive: false, isHidden: hidden, windowAccess: access)
}

private func winSnap(_ app: AppKey, _ serial: UInt64, _ title: String, focused: Bool = false,
                     minimized: Bool = false, fullScreen: Bool = false, display: CGDirectDisplayID? = nil) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(app: app, serial: serial), title: title, isFocused: focused, isMain: focused,
                   isMinimized: minimized, isFullScreen: fullScreen, frame: nil, displayID: display)
}

/// Alpha (frontmost) has two windows, Bravo one, Charlie none.
private func snapshot(granted: Bool = true) -> WindowRegistrySnapshot {
    var snapshot = WindowRegistrySnapshot(accessibilityGranted: granted)
    snapshot.apps = [appSnap(alphaKey, "Alpha"), appSnap(bravoKey, "Bravo"), appSnap(charlieKey, "Charlie")]
    if granted {
        snapshot.windows = [
            winSnap(alphaKey, 1, "Alpha One", focused: true),
            winSnap(bravoKey, 2, "Bravo Report", focused: true),
            winSnap(alphaKey, 3, "Alpha Two", minimized: true),
        ]
    }
    return snapshot
}

/// Window entries, window-first order, latched title search and the
/// catalog that builds them.
final class SwitcherWindowStateTests: XCTestCase {
    private func open(_ mode: SwitcherMode, granted: Bool = true, held: Bool = true, revealed: Bool = false) -> (SwitcherState, [SwitcherEffect]) {
        var state = SwitcherState()
        let effects = state.send(.trigger(items: SwitcherCatalog.items(snapshot(granted: granted), mode: mode), frontmost: alphaKey.pid, held: held))
        if revealed { _ = state.send(.revealDue) }
        return (state, effects)
    }

    func testAppsModeGroupsWindowsPerAppInRecentOrder() {
        let items = SwitcherCatalog.items(snapshot(), mode: .apps)
        XCTAssertEqual(items.map(\.name), ["Alpha", "Bravo", "Charlie"])
        XCTAssertEqual(items[0].windows.map(\.title), ["Alpha One", "Alpha Two"])
        XCTAssertEqual(items.map(\.id), [.app(alphaKey), .app(bravoKey), .app(charlieKey)], "SW-01 entries are apps")
        XCTAssertEqual(items[2].windows, [])
        XCTAssertFalse(items[2].windowsUnavailable, "read and empty is not unavailable")
    }

    func testWindowsModeListsEveryWindowThenWindowlessApps() {
        let items = SwitcherCatalog.items(snapshot(), mode: .windows)
        XCTAssertEqual(items.map(\.title), ["Alpha One", "Bravo Report", "Alpha Two", "Charlie"])
        XCTAssertEqual(items.filter { $0.key == alphaKey }.count, 2, "two windows of one app are two entries")
        XCTAssertNotEqual(items[0].id, items[2].id)
        XCTAssertNil(items[3].window)
    }

    func testWithoutAccessibilityWindowsModeIsTheAppList() {
        let items = SwitcherCatalog.items(snapshot(granted: false), mode: .windows)
        XCTAssertEqual(items.map(\.id), [.app(alphaKey), .app(bravoKey), .app(charlieKey)])
        XCTAssertTrue(items.allSatisfy { $0.windows.isEmpty && !$0.windowsUnavailable })
    }

    func testUnreadAppsAreMarkedUnavailableAndDisplaysAreNamed() {
        var snap = snapshot()
        snap.apps[2] = appSnap(charlieKey, "Charlie", access: .unresponsive)
        snap.windows[1] = winSnap(bravoKey, 2, "Bravo Report", fullScreen: true, display: 7)
        let items = SwitcherCatalog.items(snap, mode: .windows, displays: [7: "Studio Display"])
        XCTAssertTrue(items[3].windowsUnavailable)
        XCTAssertEqual(items[1].window?.display, "Studio Display")
        XCTAssertNil(items[0].window?.display, "no frame, no display claimed")
        XCTAssertEqual(items[1].spokenName, "Bravo Report, Bravo, full screen, own Space, on Studio Display")
        XCTAssertEqual(items[2].spokenName, "Alpha Two, Alpha, minimized")
        XCTAssertEqual(SwitcherCatalog.items(snap, mode: .apps)[0].spokenName, "Alpha, 2 windows")
    }

    func testWindowModeQuickTapFocusesThePreviousWindow() {
        let (state, effects) = open(.windows, held: false)
        XCTAssertFalse(state.isOpen)
        let bravo = SwitcherCatalog.items(snapshot(), mode: .windows)[1]
        XCTAssertEqual(effects, [.focus(bravo, bravo.window!)], "no panel, no dismiss")
    }

    func testWindowModeCyclesEntriesAndReachesAnotherWindowOfTheFrontmostApp() {
        var (state, _) = open(.windows)
        XCTAssertTrue(state.isWindowList)
        XCTAssertEqual(state.selectedItem?.title, "Bravo Report")
        _ = state.send(.key(.down))
        XCTAssertEqual(state.selectedItem?.title, "Alpha Two", "Down moves in a list")
        _ = state.send(.key(.next))
        _ = state.send(.key(.next))
        XCTAssertEqual(state.selectedItem?.title, "Alpha One", "wraps")
        _ = state.send(.key(.previous))
        _ = state.send(.key(.up))
        XCTAssertEqual(state.selectedItem?.title, "Alpha Two")
        let entry = state.selectedItem!
        XCTAssertEqual(state.send(.modifiersReleased), [.dismiss, .focus(entry, entry.window!)],
                       "another window of the frontmost app is a real switch")
    }

    func testTheFrontmostAppsFocusedWindowFocusesNothing() {
        var (state, _) = open(.windows)
        _ = state.send(.key(.first))
        XCTAssertEqual(state.send(.key(.commit)), [.dismiss])
    }

    func testWindowWithoutAWindowlessAppActivatesTheApp() {
        var (state, _) = open(.windows)
        _ = state.send(.key(.last))
        let charlie = state.selectedItem!
        XCTAssertEqual(state.send(.key(.commit)), [.dismiss, .activate(charlie)])
    }

    func testAppRowDownChoosesAWindowWithoutWrapping() {
        var (state, _) = open(.apps, revealed: true)
        XCTAssertFalse(state.isWindowList)
        _ = state.send(.key(.previous))
        XCTAssertEqual(state.selectedItem?.name, "Alpha")
        XCTAssertEqual(state.send(.key(.down)), [.announce("Alpha One, Alpha")])
        XCTAssertEqual(state.send(.key(.down)), [.announce("Alpha Two, Alpha, minimized")])
        XCTAssertEqual(state.send(.key(.down)), [], "stops at the last window")
        _ = state.send(.key(.up))
        XCTAssertEqual(state.selectedWindow?.title, "Alpha One")
        XCTAssertEqual(state.send(.key(.up)), [.announce("Alpha, 2 windows")], "back to the app")
        XCTAssertNil(state.windowSelection)
        XCTAssertEqual(state.send(.key(.up)), [])
        _ = state.send(.key(.down))
        _ = state.send(.key(.next))
        XCTAssertNil(state.windowSelection, "another app drops the window choice")
        XCTAssertEqual(state.selectedItem?.name, "Bravo")
    }

    func testAppRowWindowCommitFocusesItAndTheAppAloneStaysSW01() {
        var (state, _) = open(.apps)
        _ = state.send(.key(.previous))
        _ = state.send(.key(.down))
        _ = state.send(.key(.down))
        let alpha = state.selectedItem!
        XCTAssertEqual(state.send(.modifiersReleased), [.dismiss, .focus(alpha, alpha.windows[1])], "the minimized window is restored")
        (state, _) = open(.apps)
        let bravo = state.items[1]
        XCTAssertEqual(state.send(.modifiersReleased), [.dismiss, .activate(bravo)], "no window chosen: the app, as in SW-01")
    }

    func testClickingAWindowRowInTheAppRow() {
        var (state, _) = open(.apps)
        let alpha = SwitcherCatalog.items(snapshot(), mode: .apps)[0]
        XCTAssertEqual(state.send(.choose(.app(alphaKey), window: alpha.windows[1].id)), [.dismiss, .focus(alpha, alpha.windows[1])])
        (state, _) = open(.apps)
        let bravo = state.items[1]
        XCTAssertEqual(state.send(.choose(.app(bravoKey), window: alpha.windows[1].id)), [.dismiss, .activate(bravo)],
                       "a window of another app is ignored: the app itself")
    }

    // MARK: Search

    func testSlashLatchesSearchAndRevealsAtOnce() {
        var (state, _) = open(.apps)
        XCTAssertEqual(state.phase, .armed)
        XCTAssertEqual(state.send(.key(.search)), [.reveal, .announce("Search window titles")])
        XCTAssertEqual(state.phase, .visible)
        XCTAssertTrue(state.isSearching)
        XCTAssertTrue(state.isWindowList, "search lists windows even in apps mode")
        XCTAssertEqual(state.shown.map(\.title), ["Alpha One", "Alpha Two", "Bravo Report", "Charlie"])
        XCTAssertEqual(state.selectedItem?.title, "Bravo Report", "the selected app's window stays selected")
        XCTAssertEqual(state.send(.modifiersReleased), [], "latched: letting go keeps it open")
        XCTAssertTrue(state.isOpen)
        XCTAssertEqual(state.send(.revealDue), [], "already visible")
        XCTAssertEqual(state.send(.key(.search)), [])
    }

    func testTypingFiltersDeletionRefiltersAndReturnFocuses() {
        var (state, _) = open(.windows, revealed: true)
        _ = state.send(.key(.search))
        XCTAssertEqual(state.send(.key(.type("t"))), [.announce("Bravo Report, Bravo")], "first match in list order")
        XCTAssertEqual(state.shown.map(\.title), ["Bravo Report", "Alpha Two"])
        _ = state.send(.key(.type("wo")))
        XCTAssertEqual(state.shown.map(\.title), ["Alpha Two"])
        XCTAssertEqual(state.send(.key(.type("z"))), [.announce("No matches")])
        XCTAssertNil(state.selectedItem)
        XCTAssertEqual(state.send(.key(.commit)), [.dismiss], "nothing to switch to")

        (state, _) = open(.windows, revealed: true)
        _ = state.send(.key(.search))
        _ = state.send(.key(.type("alpha z")))
        XCTAssertEqual(state.shown, [])
        _ = state.send(.key(.deleteBackward))
        _ = state.send(.key(.deleteBackward))
        XCTAssertEqual(state.query, "alpha")
        XCTAssertEqual(state.shown.map(\.title), ["Alpha One", "Alpha Two"], "app names match too")
        _ = state.send(.key(.next))
        let two = state.selectedItem!
        XCTAssertEqual(state.send(.key(.commit)), [.dismiss, .focus(two, two.window!)])
    }

    func testClearAndDeleteOnEmptyQuery() {
        var (state, _) = open(.windows)
        _ = state.send(.key(.search))
        XCTAssertEqual(state.send(.key(.deleteBackward)), [], "nothing to delete; search stays")
        XCTAssertTrue(state.isSearching)
        _ = state.send(.key(.type("rep")))
        _ = state.send(.key(.clearQuery))
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.shown.count, 4)
    }

    func testEscapeCancelsSearchWithoutFocusing() {
        var (state, _) = open(.windows)
        _ = state.send(.key(.search))
        _ = state.send(.key(.type("report")))
        _ = state.send(.modifiersReleased)
        XCTAssertEqual(state.send(.key(.cancel)), [.dismiss])
        XCTAssertFalse(state.isOpen)
        XCTAssertNil(state.query)
        XCTAssertEqual(state.send(.modifiersReleased), [])
    }

    func testMatchingIgnoresCaseAndDiacriticsAndNeedsEveryWord() {
        let entry = SwitcherItem(key: alphaKey, name: "Notes", window: SwitcherWindow(id: WindowID(app: alphaKey, serial: 9), title: "Café menu"))
        XCTAssertTrue(SwitcherSearch.matches(entry, "cafe"))
        XCTAssertTrue(SwitcherSearch.matches(entry, "MENU notes"))
        XCTAssertFalse(SwitcherSearch.matches(entry, "menu safari"))
        XCTAssertTrue(SwitcherSearch.matches(entry, "  "))
    }

    // MARK: Changes while open

    func testClosedWindowLeavesAndSelectionMoves() {
        var (state, _) = open(.windows, revealed: true)
        var snap = snapshot()
        snap.windows.remove(at: 1)
        XCTAssertEqual(state.send(.appsChanged(SwitcherCatalog.items(snap, mode: .windows))), [.announce("Alpha Two, Alpha, minimized")])
        XCTAssertEqual(state.items.map(\.title), ["Alpha One", "Alpha Two", "Charlie", "Bravo"],
                       "Bravo's last window closed: the app joins at the end")
    }

    func testClosedChosenWindowInTheAppRowGoesBackToTheApp() {
        var (state, _) = open(.apps, revealed: true)
        _ = state.send(.key(.previous))
        _ = state.send(.key(.down))
        _ = state.send(.key(.down))
        var snap = snapshot()
        snap.windows.remove(at: 2)
        XCTAssertEqual(state.send(.appsChanged(SwitcherCatalog.items(snap, mode: .apps))), [.announce("Alpha")])
        XCTAssertNil(state.windowSelection)
        XCTAssertEqual(state.send(.choose(.app(alphaKey), window: WindowID(app: alphaKey, serial: 3))), [.dismiss],
                       "a closed window's id is refused; the frontmost app itself does nothing")
    }

    func testSearchResultsFollowChanges() {
        var (state, _) = open(.windows, revealed: true)
        _ = state.send(.key(.search))
        _ = state.send(.key(.type("alpha")))
        XCTAssertEqual(state.selectedItem?.title, "Alpha One")
        var snap = snapshot()
        snap.windows.remove(at: 0)
        _ = state.send(.appsChanged(SwitcherCatalog.items(snap, mode: .windows)))
        XCTAssertEqual(state.shown.map(\.title), ["Alpha Two"])
        XCTAssertEqual(state.selectedItem?.title, "Alpha Two")
        XCTAssertTrue(state.isSearching)
    }

    func testRelaunchedAppsWindowsAreNewEntries() {
        var (state, _) = open(.windows)
        let reused = AppKey(pid: bravoKey.pid, generation: 9)
        var snap = snapshot()
        snap.apps[1] = appSnap(reused, "Bravo")
        snap.windows[1] = winSnap(reused, 2, "Bravo Report", focused: true)
        _ = state.send(.appsChanged(SwitcherCatalog.items(snap, mode: .windows)))
        XCTAssertFalse(state.items.contains { $0.key == bravoKey }, "the old launch's window left")
        XCTAssertEqual(state.items.last?.key, reused, "same pid and title, but a new entry")
        XCTAssertEqual(state.send(.choose(.window(WindowID(app: bravoKey, serial: 2)))), [])
    }
}

/// Key mapping while searching and while browsing.
final class SwitcherSearchKeyTests: XCTestCase {
    private func map(_ code: Int, _ flags: NSEvent.ModifierFlags = [], _ chars: String? = nil, plain: String? = nil, searching: Bool = true) -> SwitcherKey? {
        SwitcherKey(keyCode: UInt16(code), modifiers: flags, characters: chars, unmodified: plain ?? chars, searching: searching)
    }

    func testBrowsingKeys() {
        XCTAssertEqual(map(kVK_ANSI_Slash, .option, "÷", plain: "/", searching: false), .search)
        XCTAssertEqual(map(kVK_DownArrow, searching: false), .down)
        XCTAssertEqual(map(kVK_UpArrow, searching: false), .up)
        XCTAssertNil(map(kVK_ANSI_A, [], "a", searching: false), "typing only starts after /")
        XCTAssertNil(map(kVK_Delete, searching: false))
    }

    func testSearchingKeys() {
        XCTAssertEqual(map(kVK_ANSI_A, [], "a"), .type("a"))
        XCTAssertEqual(map(kVK_ANSI_A, [.shift], "A"), .type("A"))
        XCTAssertEqual(map(kVK_ANSI_A, [.option], "å", plain: "a"), .type("a"), "⌥ still held types the plain letter")
        XCTAssertEqual(map(kVK_ANSI_Slash, [], "/"), .type("/"))
        XCTAssertEqual(map(kVK_Space, [], " "), .type(" "))
        XCTAssertNil(map(kVK_ANSI_A, [.command], "a"), "⌘ shortcuts do not type")
        XCTAssertEqual(map(kVK_Delete, [], "\u{7F}"), .deleteBackward)
        XCTAssertEqual(map(kVK_Delete, [.command]), .clearQuery)
        XCTAssertEqual(map(kVK_Return, [], "\r"), .commit)
        XCTAssertEqual(map(kVK_Escape, [], "\u{1B}"), .cancel)
        XCTAssertEqual(map(kVK_Tab, [], "\t"), .next)
        XCTAssertEqual(map(kVK_DownArrow, [], "\u{F701}"), .next)
        XCTAssertEqual(map(kVK_UpArrow, [], "\u{F700}"), .previous)
        XCTAssertNil(map(kVK_LeftArrow, [], "\u{F702}"))
        XCTAssertNil(map(kVK_F5, [], "\u{F708}"), "function keys do not type")
    }
}

/// `switcherMode` and `switcherTitleSearch` in dock.json.
final class SwitcherPreferenceSettingsTests: XCTestCase {
    private func model(_ json: String) throws -> DockModel {
        try JSONDecoder().decode(DockModel.self, from: Data(json.utf8))
    }

    func testDefaultsMalformedAndRoundTrip() throws {
        let empty = try model("{}")
        XCTAssertEqual(empty.switcherMode, .apps, "app-first stays the default")
        XCTAssertTrue(empty.switcherTitleSearch)
        XCTAssertEqual(try model(#"{"switcherMode": "tabs", "switcherTitleSearch": "no"}"#).switcherMode, .apps)
        XCTAssertTrue(try model(#"{"switcherTitleSearch": 3}"#).switcherTitleSearch)
        let set = try model(#"{"switcherMode": "windows", "switcherTitleSearch": false}"#)
        XCTAssertEqual(set.switcherMode, .windows)
        XCTAssertFalse(set.switcherTitleSearch)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(set)) as? [String: Any])
        XCTAssertEqual(json["switcherMode"] as? String, "windows")
        XCTAssertEqual(json["switcherTitleSearch"] as? Bool, false)
        let defaults = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(empty)) as? [String: Any])
        XCTAssertEqual(defaults["switcherMode"] as? String, "apps", "always written")
    }
}

// MARK: - Controller over a real registry with windows

/// Windows per pid, answered on the registry's lanes.
private final class ListedWindows: WindowSource, @unchecked Sendable {
    final class Observation: WindowObservation, @unchecked Sendable {
        let changed: () -> Void
        init(changed: @escaping () -> Void) { self.changed = changed }
        func cancel() {}
    }

    private let lock = NSLock()
    private var windows: [pid_t: [WindowReading]] = [:]
    private var observations: [pid_t: Observation] = [:]

    func set(_ pid: pid_t, _ list: [WindowReading]) {
        lock.lock(); windows[pid] = list; let obs = observations[pid]; lock.unlock()
        if let obs { DispatchQueue.global().async { obs.changed() } }
    }

    func observe(_ pid: pid_t, changed: @escaping () -> Void) -> WindowObserveResult {
        let observation = Observation(changed: changed)
        lock.lock(); observations[pid] = observation; lock.unlock()
        return .observing(observation)
    }

    func readWindows(of pid: pid_t, observation: WindowObservation?) -> WindowReadResult {
        lock.lock(); defer { lock.unlock() }
        return .windows(windows[pid] ?? [])
    }
}

@MainActor
private final class Recorder: SwitcherPresenter {
    var calls: [String] = []
    func present(_ switcher: AppSwitcher) { calls.append("present") }
    func reveal() { calls.append("reveal") }
    func dismiss() { calls.append("dismiss") }
    func announce(_ message: String) {}
}

private func appRecord(_ pid: pid_t, _ name: String, launched: TimeInterval = 0) -> RunningAppRecord {
    RunningAppRecord(pid: pid, bundleIdentifier: "test.\(name)", name: name, launchDate: Date(timeIntervalSince1970: launched))
}

private func reading(_ handle: String, _ title: String, focused: Bool = false, minimized: Bool = false) -> WindowReading {
    WindowReading(handle: handle, title: title, isMinimized: minimized, isFocused: focused, isMain: focused)
}

@MainActor
final class AppSwitcherWindowTests: XCTestCase {
    private let alpha = appRecord(10, "Alpha")
    private let bravo = appRecord(20, "Bravo")
    private let source = ListedWindows()
    private var granted = true
    private var front: pid_t? = 10
    private var flags: NSEvent.ModifierFlags = []
    private var activated: [String] = []
    private var focused: [WindowFocusTarget] = []
    private let presenter = Recorder()
    private let chords = CurrentValueSubject<HotkeyChord?, Never>(SwitcherShortcut.defaultChord)
    private let preferences = CurrentValueSubject<SwitcherPreferences, Never>(SwitcherPreferences(mode: .windows))

    private lazy var registry = WindowRegistry(
        source: source,
        isAccessGranted: { [unowned self] in granted },
        currentApps: { [unowned self] in ([alpha, bravo], front) },
        retryDelay: .milliseconds(10)
    )

    private lazy var switcher = AppSwitcher(
        registry: registry,
        actions: SwitcherActions(
            modifierFlags: { [unowned self] in flags },
            frontmostPID: { [unowned self] in front },
            activate: { [unowned self] item, _ in
                activated.append(item.name)
                return true
            },
            focus: { [unowned self] target, done in
                focused.append(target)
                done(.focused)
            },
            revealDelay: .seconds(3600)
        ),
        presenter: presenter,
        registrar: { _, _ in NSObject() },
        report: { _ in }
    )

    private lazy var modules = ModuleRegistry(commands: CommandRegistry(permissions: PermissionGate()), permissions: PermissionGate())

    private func enable() async throws {
        source.set(10, [reading("a1", "Alpha One", focused: true), reading("a2", "Alpha Two", minimized: true)])
        source.set(20, [reading("b1", "Bravo Report", focused: true)])
        try modules.register(SwitcherModule(switcher: switcher, chords: chords.eraseToAnyPublisher(),
                                            preferences: preferences.eraseToAnyPublisher()))
        modules.enable(SwitcherModule.moduleID)
        if granted { await wait("windows read") { registry.snapshot.windows.count == 3 } }
    }

    private func wait(_ what: String, file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)", file: file, line: line) }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testDistinctWindowsAndQuickTapFocusesThePreviousWindowsHandle() async throws {
        try await enable()
        flags = .option
        switcher.hotkeyPressed()
        XCTAssertEqual(switcher.state.items.map(\.title), ["Alpha One", "Alpha Two", "Bravo Report"])
        switcher.keyPressed(.cancel)

        flags = []
        switcher.hotkeyPressed()
        XCTAssertEqual(focused.map(\.handle), [AnyHashable("a2")], "the previous window, by its own handle")
        XCTAssertEqual(focused.first?.app, alpha, "with the launch it was read from")
        XCTAssertEqual(activated, [])
        XCTAssertEqual(presenter.calls, ["present", "dismiss"], "the quick tap never showed a panel")
    }

    func testFastWindowTapsAlternateBeforeTheRegistryReportsFocus() async throws {
        try await enable()
        flags = []
        // The fake source never moves focus, as when the AX notification has
        // not arrived yet: each tap still goes back to the window before it.
        switcher.hotkeyPressed()
        switcher.hotkeyPressed()
        switcher.hotkeyPressed()
        XCTAssertEqual(focused.map(\.handle), ["a2", "a1", "a2"].map(AnyHashable.init))
        XCTAssertEqual(switcher.requested, [], "a window of the app already in front waits for no activation")
    }

    func testAppsModeStaysTheDefaultBehavior() async throws {
        preferences.send(SwitcherPreferences())
        try await enable()
        flags = []
        switcher.hotkeyPressed()
        XCTAssertEqual(activated, ["Bravo"])
        XCTAssertEqual(focused, [])
    }

    func testClosedWindowHasNoTargetAndIsNeverFocused() async throws {
        try await enable()
        let id = try XCTUnwrap(registry.snapshot.windows.first { $0.title == "Alpha Two" }?.id)
        XCTAssertNotNil(registry.focusTarget(id))
        flags = .option
        switcher.hotkeyPressed()
        XCTAssertEqual(switcher.state.selectedItem?.title, "Alpha Two")
        source.set(10, [reading("a1", "Alpha One", focused: true)])
        await wait("window closed") { registry.snapshot.windows.count == 2 }
        XCTAssertNil(registry.focusTarget(id))
        XCTAssertEqual(switcher.state.selectedItem?.title, "Bravo Report", "the closed window left the list")
        switcher.choose(.window(id))
        XCTAssertTrue(switcher.state.isOpen, "its id is refused")
        switcher.keyPressed(.cancel)
        XCTAssertEqual(focused, [])
    }

    func testPidReuseInvalidatesEveryWindowOfTheOldLaunch() async throws {
        try await enable()
        let old = try XCTUnwrap(registry.snapshot.windows.first { $0.title == "Bravo Report" }?.id)
        registry.appLaunched(appRecord(20, "Bravo", launched: 99))
        XCTAssertNil(registry.focusTarget(old), "same pid, later launch")
        await wait("new launch read") { registry.snapshot.windows.contains { $0.title == "Bravo Report" } }
        let new = try XCTUnwrap(registry.snapshot.windows.first { $0.title == "Bravo Report" }?.id)
        XCTAssertNotEqual(old, new)
        XCTAssertEqual(registry.focusTarget(new)?.app.launchDate, Date(timeIntervalSince1970: 99))
    }

    func testWithoutAccessibilityWindowsModeSwitchesApps() async throws {
        granted = false
        try await enable()
        flags = []
        switcher.hotkeyPressed()
        XCTAssertEqual(activated, ["Bravo"])
        XCTAssertEqual(focused, [])
        XCTAssertFalse(switcher.windowsAvailable)
    }

    func testSearchLatchesPastReleaseAndReturnFocuses() async throws {
        try await enable()
        flags = .option
        switcher.hotkeyPressed()
        XCTAssertTrue(switcher.keyPressed(.search))
        XCTAssertEqual(presenter.calls, ["present", "reveal"])
        switcher.modifiersChanged([])
        XCTAssertTrue(switcher.state.isOpen, "latched")
        switcher.keyPressed(.type("report"))
        switcher.keyPressed(.commit)
        XCTAssertEqual(focused.map(\.handle), [AnyHashable("b1")])
        XCTAssertFalse(switcher.state.isOpen)
    }

    func testSearchTurnedOffIgnoresSlash() async throws {
        preferences.send(SwitcherPreferences(mode: .windows, titleSearch: false))
        try await enable()
        flags = .option
        switcher.hotkeyPressed()
        XCTAssertTrue(switcher.keyPressed(.search), "swallowed")
        XCTAssertFalse(switcher.state.isSearching)
    }

    func testModuleStopDuringSearchFocusesNothing() async throws {
        try await enable()
        flags = .option
        switcher.hotkeyPressed()
        switcher.keyPressed(.search)
        switcher.keyPressed(.type("alpha"))
        modules.disable(SwitcherModule.moduleID)
        XCTAssertFalse(switcher.state.isOpen)
        XCTAssertEqual(presenter.calls.last, "dismiss")
        XCTAssertEqual(focused, [])
        XCTAssertEqual(activated, [])
        XCTAssertFalse(registry.isRunning)
        XCTAssertEqual(modules.resourceCount(of: SwitcherModule.moduleID), 0)
    }
}
