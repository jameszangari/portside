import XCTest
@testable import portside

@MainActor
final class MenuBarAssertionTests: XCTestCase {
    final class FakeHandle: MenuBarAssertionHandle {
        let config: MenuBarAssertionConfig
        var invalidated = false
        unowned let owner: FakeBridge
        init(_ config: MenuBarAssertionConfig, owner: FakeBridge) { self.config = config; self.owner = owner }
        func invalidate() {
            guard !invalidated else { return }
            invalidated = true
            owner.events.append("invalidate")
        }
    }

    final class FakeBridge: MenuBarAssertionBridge {
        var unavailableReason: String?
        /// Completions wait for `finish` when true.
        var hold = false
        var error: String?
        var returnNil = false
        var handles: [FakeHandle] = []
        var events: [String] = []
        private var pending: [(FakeHandle, @MainActor (String?) -> Void)] = []

        var live: Int { handles.filter { !$0.invalidated }.count }
        var maxLive = 0

        func activate(_ config: MenuBarAssertionConfig, completion: @escaping @MainActor (String?) -> Void) -> MenuBarAssertionHandle? {
            if returnNil { return nil }
            events.append("activate")
            let handle = FakeHandle(config, owner: self)
            handles.append(handle)
            maxLive = max(maxLive, live)
            if hold { pending.append((handle, completion)) } else { let e = error; DispatchQueue.main.async { MainActor.assumeIsolated { completion(e) } } }
            return handle
        }

        func finish(_ error: String? = nil) {
            let list = pending
            pending = []
            for (_, completion) in list { completion(error) }
        }
    }

    private func config(_ names: String...) -> MenuBarAssertionConfig {
        MenuBarAssertionConfig(systemItems: MenuBarAssertionPlan.systemItems, bundleIdentifiers: names)
    }

    private func make(_ bridge: FakeBridge, control: @escaping @MainActor () async -> String? = { nil }) -> (MenuBarAssertionController, Failures) {
        let failures = Failures()
        let controller = MenuBarAssertionController(bridge: bridge, activationTimeout: .milliseconds(150), verifyDelay: .milliseconds(30), verifyControl: control)
        controller.onFailure = { failures.reasons.append($0) }
        return (controller, failures)
    }

    final class Failures { var reasons: [String] = [] }

    private func settle(_ ms: Int = 120) async { try? await Task.sleep(for: .milliseconds(ms)) }

    // MARK: Plan

    func testHiddenBundlesNeedEveryItemHiddenAndSkipApple() {
        let assignments: [String: MenuBarSection] = [
            "com.a.app:#0": .hidden, "com.a.app:#1": .alwaysHidden,
            "com.b.app:#0": .hidden, "com.b.app:#1": .visible,
            "com.apple.controlcenter:wifi": .hidden, "pid42:#0": .hidden,
            "com.c.app:Item-0": .alwaysHidden,
        ]
        XCTAssertEqual(MenuBarAssertionPlan.hiddenBundles(assignments: assignments, sections: [.hidden, .alwaysHidden]), ["com.a.app", "com.c.app"])
        XCTAssertEqual(MenuBarAssertionPlan.hiddenBundles(assignments: assignments, sections: [.alwaysHidden]), ["com.c.app"])
        XCTAssertTrue(MenuBarAssertionPlan.hiddenBundles(assignments: [:], sections: [.hidden]).isEmpty)
    }

    func testConfigKeepsEveryoneElsePortsideAndAppleOwners() {
        let plan = MenuBarAssertionPlan.config(running: ["Com.A.App", "com.keep.app", "com.keep.app"], hidden: ["com.a.app"], portside: "com.james.portside")
        XCTAssertEqual(plan.bundleIdentifiers, ["com.apple.MenuBarAgent", "com.apple.systemuiserver", "com.james.portside", "com.keep.app"])
        XCTAssertEqual(plan.systemItems, [0, 1, 2, 5, 6, 8], "battery, bluetooth, clock, sound, wifi, control center")
        XCTAssertEqual(plan, MenuBarAssertionPlan.config(running: ["com.keep.app", "Com.A.App"], hidden: ["com.a.app"], portside: "com.james.portside"), "order does not matter")
    }

    func testOnByDefaultFromMacOS27AndCanBeTurnedOff() {
        let suite = "portside.assertion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(MenuBarAssertionOptIn.isEnabled(defaults: defaults, environment: [:], osMajor: 27))
        XCTAssertFalse(MenuBarAssertionOptIn.isEnabled(defaults: defaults, environment: [:], osMajor: 26))
        XCTAssertFalse(MenuBarAssertionOptIn.isEnabled(defaults: defaults, environment: [MenuBarAssertionOptIn.environmentKey: "0"], osMajor: 27))
        defaults.set(true, forKey: MenuBarAssertionOptIn.disableKey)
        XCTAssertFalse(MenuBarAssertionOptIn.isEnabled(defaults: defaults, environment: [:], osMajor: 27))
        XCTAssertFalse(MenuBarAssertionOptIn.developerHooks(defaults: defaults, environment: [:]))
    }

    func testOpenMenusAreNewWindowsHangingFromTheBar() {
        let strip = CGRect(x: 0, y: 0, width: 1000, height: 33)
        let layers: Set<Int> = [101]
        let windows = [
            MenuBarWindowInfo(id: 1, layer: 101, bounds: CGRect(x: 100, y: 33, width: 200, height: 300)),
            MenuBarWindowInfo(id: 2, layer: 101, bounds: CGRect(x: 100, y: 200, width: 200, height: 300)),
            MenuBarWindowInfo(id: 3, layer: 0, bounds: CGRect(x: 100, y: 33, width: 200, height: 300)),
            MenuBarWindowInfo(id: 4, layer: 101, bounds: CGRect(x: 2000, y: 33, width: 200, height: 300)),
        ]
        XCTAssertEqual(MenuBarOpenMenus.candidates(windows, strips: [strip], menuLayers: layers), [1])
    }

    // MARK: Controller

    func testHideActivatesAndRevealReleases() async {
        let bridge = FakeBridge()
        let (controller, failures) = make(bridge)
        controller.request(config("a"))
        await settle()
        XCTAssertEqual(bridge.live, 1)
        XCTAssertTrue(controller.isHolding)
        controller.request(nil)
        XCTAssertEqual(bridge.live, 0, "reveal releases at once")
        XCTAssertFalse(controller.isHolding)
        XCTAssertTrue(failures.reasons.isEmpty)
    }

    func testChangeOfAllowListReleasesBeforeAcquiringAndNeverOverlaps() async {
        let bridge = FakeBridge()
        let (controller, _) = make(bridge)
        controller.request(config("a"))
        await settle()
        controller.request(config("a", "b"))
        await settle()
        XCTAssertEqual(bridge.events, ["activate", "activate", "invalidate"], "the old one goes only after the new one lands, so nothing flashes back")
        XCTAssertEqual(bridge.live, 1)
        XCTAssertEqual(bridge.handles.last?.config, config("a", "b"))
    }

    func testSameRequestDoesNotReplaceTheAssertion() async {
        let bridge = FakeBridge()
        let (controller, _) = make(bridge)
        controller.request(config("a"))
        await settle()
        controller.request(config("a"))
        await settle()
        XCTAssertEqual(bridge.handles.count, 1)
    }

    func testLatestIntentWinsWhileActivationIsPending() async {
        let bridge = FakeBridge()
        bridge.hold = true
        let (controller, _) = make(bridge)
        controller.request(config("a"))
        controller.request(config("a", "b"))
        controller.request(config("a", "b", "c"))
        XCTAssertEqual(bridge.handles.count, 1, "held while the first is pending")
        bridge.finish()
        XCTAssertEqual(bridge.handles.count, 2, "the latest request replaces it, once")
        XCTAssertEqual(bridge.handles.last?.config, config("a", "b", "c"))
        bridge.finish()
        await settle()
        XCTAssertEqual(bridge.live, 1)
    }

    func testRapidHideRevealHideEndsHidden() async {
        let bridge = FakeBridge()
        bridge.hold = true
        let (controller, _) = make(bridge)
        controller.request(config("a"))
        controller.request(nil)
        XCTAssertEqual(bridge.live, 0)
        controller.request(config("a"))
        bridge.finish()   // completes only the stale first activation
        XCTAssertEqual(bridge.handles.count, 2)
        XCTAssertEqual(bridge.live, 1)
        bridge.finish()
        await settle()
        XCTAssertTrue(controller.isHolding)
        XCTAssertEqual(bridge.maxLive, 1)
    }

    func testRevealDuringPendingHideReleasesAndIgnoresTheLateCompletion() async {
        let bridge = FakeBridge()
        bridge.hold = true
        let (controller, failures) = make(bridge)
        controller.request(config("a"))
        controller.release()
        XCTAssertEqual(bridge.live, 0)
        bridge.finish()
        await settle()
        XCTAssertEqual(bridge.live, 0)
        XCTAssertEqual(bridge.handles.count, 1, "the late completion starts nothing")
        XCTAssertFalse(controller.isHolding)
        XCTAssertTrue(failures.reasons.isEmpty)
    }

    func testActivationErrorCleansUpAndReports() async {
        let bridge = FakeBridge()
        bridge.error = "boom"
        let (controller, failures) = make(bridge)
        controller.request(config("a"))
        await settle()
        XCTAssertEqual(bridge.live, 0)
        XCTAssertFalse(controller.isHolding)
        XCTAssertEqual(failures.reasons.count, 1)
        XCTAssertTrue(failures.reasons[0].contains("boom"))
    }

    func testNoAnswerTimesOutAndReleases() async {
        let bridge = FakeBridge()
        bridge.hold = true
        let (controller, failures) = make(bridge)
        controller.request(config("a"))
        await settle(300)
        XCTAssertEqual(bridge.live, 0)
        XCTAssertEqual(failures.reasons.count, 1)
        XCTAssertFalse(controller.isActivating)
    }

    func testUnavailableBridgeOrNoHandleLeavesBarRevealed() async {
        let bridge = FakeBridge()
        bridge.unavailableReason = "no assertion here"
        let (controller, failures) = make(bridge)
        controller.request(config("a"))
        XCTAssertEqual(failures.reasons, ["no assertion here"])
        XCTAssertTrue(bridge.handles.isEmpty)
        bridge.unavailableReason = nil
        bridge.returnNil = true
        controller.request(config("a"))
        XCTAssertEqual(failures.reasons.count, 2)
        XCTAssertFalse(controller.isHolding)
    }

    func testMissingControlAfterHideUndoesIt() async {
        let bridge = FakeBridge()
        let (controller, failures) = make(bridge, control: { "own icon gone" })
        controller.request(config("a"))
        await settle(250)
        XCTAssertEqual(bridge.live, 0)
        XCTAssertEqual(failures.reasons.count, 1)
        XCTAssertTrue(failures.reasons[0].contains("own icon gone"))
    }

    // MARK: Surface

    func testLateVerificationFailureCannotReleaseANewerHide() async {
        let bridge = FakeBridge()
        var continuation: CheckedContinuation<String?, Never>?
        var reads = 0
        let (controller, failures) = make(bridge, control: {
            reads += 1
            if reads == 1 { return "transient" }
            if reads == 2 {
                return await withCheckedContinuation { continuation = $0 }
            }
            return nil
        })
        controller.request(config("old"))
        await settle(80)
        XCTAssertNotNil(continuation)
        controller.request(nil)
        controller.request(config("new"))
        continuation?.resume(returning: "stale missing control")
        await settle()
        XCTAssertEqual(bridge.live, 1)
        XCTAssertEqual(controller.applied, config("new"))
        XCTAssertTrue(failures.reasons.isEmpty)
        controller.release()
    }

    private func surface(_ bridge: FakeBridge, assignments: [String: MenuBarSection], running: [String] = ["com.a.app", "com.keep.app"]) -> (AssertionShelfSurface, MenuBarShelfTests.FakeSurface) {
        let base = MenuBarShelfTests.FakeSurface()
        let value = AssertionShelfSurface(
            base: base, bridge: bridge,
            assignments: { assignments }, runningBundles: { running }, portsideBundle: "com.james.portside", bundlePath: "/Applications/Portside.app",
            drawnOwners: { [ProcessInfo.processInfo.processIdentifier] },
            launchDebounce: .milliseconds(20), activationTimeout: .milliseconds(150), verifyDelay: .milliseconds(30)
        )
        return (value, base)
    }

    func testSurfaceHidesAssignedAppsAndKeepsPortsideAndApple() async {
        let bridge = FakeBridge()
        let (surface, base) = surface(bridge, assignments: ["com.a.app:#0": .hidden])
        surface.install()
        surface.apply(hidden: true)
        await settle()
        XCTAssertEqual(bridge.handles.count, 1)
        let held = bridge.handles[0].config
        XCTAssertFalse(held.bundleIdentifiers.contains("com.a.app"))
        XCTAssertTrue(held.bundleIdentifiers.contains("com.keep.app"))
        XCTAssertTrue(held.bundleIdentifiers.contains("com.james.portside"))
        XCTAssertEqual(held.systemItems, [0, 1, 2, 5, 6, 8])
        XCTAssertEqual(base.applied, [true], "the control item shows the state")
        surface.apply(hidden: false)
        XCTAssertEqual(bridge.live, 0)
        surface.remove()
    }

    func testRemovedSurfaceCannotReacquireFromLateMembershipRefresh() async {
        let bridge = FakeBridge()
        let (surface, _) = surface(bridge, assignments: ["com.a.app:#0": .hidden])
        surface.install()
        surface.apply(hidden: true)
        await settle()
        surface.remove()
        surface.membershipDidChange()
        await settle()
        XCTAssertEqual(bridge.live, 0)
    }

    func testDrawnSnapshotIncludesControlsOnLaterDisplays() {
        let own = ProcessInfo.processInfo.processIdentifier
        let first = MenuBarDrawnOwners.Item(pid: 42, frame: CGRect(x: 10, y: 0, width: 20, height: 24), isOverflowControl: false)
        let second = MenuBarDrawnOwners.Item(pid: own, frame: CGRect(x: 1010, y: 0, width: 20, height: 24), isOverflowControl: false)
        let result = MenuBarDrawnOwners.collect(windows: [[first], [second]]) { $0 }
        XCTAssertEqual(Set(result?.map(\.pid) ?? []), [42, own])
        XCTAssertNil(MenuBarDrawnOwners.collect(windows: [0, 1]) { $0 == 0 ? [first] : nil }, "incomplete AX reads stay unknown")
    }

    func testSurfaceWithNothingAssignedStaysRevealedAndSaysSo() async {
        let bridge = FakeBridge()
        let (surface, _) = surface(bridge, assignments: ["com.b.app:#0": .visible])
        var reasons: [String] = []
        surface.failureHandler = { reasons.append($0) }
        surface.install()
        surface.apply(hidden: true)
        await settle()
        XCTAssertTrue(bridge.handles.isEmpty)
        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons[0].contains("nothing to hide"))
    }

    func testShelfRevealsWhenTheAssertionFails() async {
        let bridge = FakeBridge()
        bridge.error = "denied"
        let (surface, _) = surface(bridge, assignments: ["com.a.app:#0": .hidden])
        let shelf = MenuBarShelf(surface: surface, verifyDelay: .seconds(60))
        shelf.start()
        shelf.hide()
        await settle(250)
        XCTAssertEqual(shelf.mode, .revealed)
        XCTAssertEqual(bridge.live, 0)
        XCTAssertTrue(shelf.lastFailOpen?.contains("denied") ?? false)
    }

    func testShelfStopAndFailOpenReleaseTheAssertion() async {
        let bridge = FakeBridge()
        let (surface, _) = surface(bridge, assignments: ["com.a.app:#0": .hidden])
        let shelf = MenuBarShelf(surface: surface, verifyDelay: .seconds(60))
        shelf.start()
        shelf.hide()
        await settle()
        XCTAssertEqual(bridge.live, 1)
        shelf.failOpen("the displays changed")
        XCTAssertEqual(bridge.live, 0)
        shelf.hide()
        await settle()
        XCTAssertEqual(bridge.live, 1)
        shelf.stop()
        XCTAssertEqual(bridge.live, 0)
    }

    func testTurnOffDuringPendingHideReleases() async {
        let bridge = FakeBridge()
        bridge.hold = true
        let (surface, _) = surface(bridge, assignments: ["com.a.app:#0": .hidden])
        let shelf = MenuBarShelf(surface: surface, verifyDelay: .seconds(60))
        shelf.start()
        shelf.hide()
        XCTAssertEqual(bridge.live, 1, "pending")
        shelf.stop()
        XCTAssertEqual(bridge.live, 0)
        bridge.finish()
        await settle()
        XCTAssertEqual(bridge.live, 0)
    }

    func testSurfaceUndoesAHideThatTakesPortsideIconAway() async {
        let bridge = FakeBridge()
        let base = MenuBarShelfTests.FakeSurface()
        let value = AssertionShelfSurface(
            base: base, bridge: bridge,
            assignments: { ["com.a.app:#0": .hidden] }, runningBundles: { ["com.a.app", "com.keep.app"] }, portsideBundle: "com.james.portside", bundlePath: "/Applications/Portside.app",
            drawnOwners: { [9_999_999] },
            launchDebounce: .milliseconds(20), activationTimeout: .milliseconds(150), verifyDelay: .milliseconds(30)
        )
        var reasons: [String] = []
        value.failureHandler = { reasons.append($0) }
        value.install()
        value.apply(hidden: true)
        await settle(300)
        XCTAssertEqual(bridge.live, 0)
        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons[0].contains("hid Portside"))
    }

    func testSurfaceCannotConfirmWithoutAccessibilityAndReveals() async {
        let bridge = FakeBridge()
        let base = MenuBarShelfTests.FakeSurface()
        let value = AssertionShelfSurface(
            base: base, bridge: bridge,
            assignments: { ["com.a.app:#0": .hidden] }, runningBundles: { ["com.a.app"] }, portsideBundle: "com.james.portside", bundlePath: "/Applications/Portside.app",
            drawnOwners: { nil }, accessibilityTrusted: { false },
            launchDebounce: .milliseconds(20), activationTimeout: .milliseconds(150), verifyDelay: .milliseconds(30)
        )
        var reasons: [String] = []
        value.failureHandler = { reasons.append($0) }
        value.install()
        value.apply(hidden: true)
        await settle(300)
        XCTAssertEqual(bridge.live, 0, "an unverifiable hide is not kept")
        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons[0].contains("Accessibility"))
    }

    func testRefusesToHideWhileAnotherManagerRuns() async {
        let bridge = FakeBridge()
        let (surface, _) = surface(bridge, assignments: ["com.a.app:#0": .hidden], running: ["com.a.app", "com.stonerl.Thaw"])
        var reasons: [String] = []
        surface.failureHandler = { reasons.append($0) }
        surface.install()
        surface.apply(hidden: true)
        await settle()
        XCTAssertTrue(bridge.handles.isEmpty)
        XCTAssertTrue(reasons.first?.contains("com.stonerl.Thaw") ?? false)
    }

    func testOutsideApplicationsRefusesBeforeTouchingTheBar() async {
        XCTAssertNil(MenuBarAssertionPlan.locationProblem(bundlePath: "/Applications/Portside.app"))
        XCTAssertNotNil(MenuBarAssertionPlan.locationProblem(bundlePath: "/Users/me/build/Portside.app"))
        XCTAssertNotNil(MenuBarAssertionPlan.locationProblem(bundlePath: "/Users/me/Applications/Portside.app"))
        let bridge = FakeBridge()
        let value = AssertionShelfSurface(
            base: MenuBarShelfTests.FakeSurface(), bridge: bridge, assignments: { ["com.a.app:#0": .hidden] },
            runningBundles: { ["com.a.app"] }, portsideBundle: "com.james.portside", bundlePath: "/Users/me/build/Portside.app"
        )
        XCTAssertFalse(value.hasHiddenAssignments, "no collapse at launch")
        var reasons: [String] = []
        value.failureHandler = { reasons.append($0) }
        value.install()
        value.apply(hidden: true)
        await settle()
        XCTAssertTrue(bridge.handles.isEmpty, "never activates from a build folder")
        XCTAssertTrue(reasons.first?.contains("/Applications") ?? false)
    }

    func testUnreadableBarWhileTrustedIsNotAFailure() async {
        let bridge = FakeBridge()
        let value = AssertionShelfSurface(
            base: MenuBarShelfTests.FakeSurface(), bridge: bridge, assignments: { ["com.a.app:#0": .hidden] }, runningBundles: { ["com.a.app"] },
            portsideBundle: "com.james.portside", bundlePath: "/Applications/Portside.app", drawnOwners: { nil }, accessibilityTrusted: { true },
            launchDebounce: .milliseconds(20), activationTimeout: .milliseconds(150), verifyDelay: .milliseconds(30)
        )
        value.install()
        value.apply(hidden: true)
        await settle(300)
        XCTAssertEqual(bridge.live, 1, "a locked screen must not undo the hide")
    }

    func testAppleItemCodesFollowMembership() {
        let plan = MenuBarAssertionPlan.config(running: ["com.keep.app"], hidden: ["apple.clock", "apple.wifi"], portside: "com.james.portside")
        XCTAssertEqual(plan.systemItems, [0, 1, 5, 8], "clock and wi-fi are left off the allow-list")
    }

    func testOrderPlannerOnlyReshufflesExistingWeights() {
        let table = ["status:a.a::Item-0": 300, "status:b.b::Item-0": 200, "status:c.c::x": 100, "module:Clock": 0]
        XCTAssertEqual(MenuBarOrderPlanner.bundle(ofKey: "status:A.a::Item-0"), "a.a")
        XCTAssertNil(MenuBarOrderPlanner.bundle(ofKey: "module:Clock"))
        let changes = MenuBarOrderPlanner.changes(table: table, desired: ["c.c", "a.a", "b.b"])
        XCTAssertEqual(changes, ["status:c.c::x": 300, "status:a.a::Item-0": 200, "status:b.b::Item-0": 100])
        XCTAssertTrue(MenuBarOrderPlanner.changes(table: table, desired: ["a.a", "b.b", "c.c"]).isEmpty, "already in order")
        XCTAssertEqual(MenuBarOrderPlanner.observedOrder(table: table, members: ["b.b", "c.c"]), ["b.b", "c.c"])
    }

    func testOrderPlannerKeepsAnAppsItemsTogetherAndIgnoresUnknowns() {
        let table = ["status:a.a::one": 400, "status:a.a::two": 300, "status:b.b::Item-0": 200]
        let changes = MenuBarOrderPlanner.changes(table: table, desired: ["b.b", "nothing.here", "a.a"])
        XCTAssertEqual(changes["status:b.b::Item-0"], 400)
        XCTAssertEqual(changes["status:a.a::one"], 300)
        XCTAssertEqual(changes["status:a.a::two"], 200)
    }

    func testNativeListTurnsOffOnlyWhatItCanTurnBackOn() {
        func record(_ bundle: String, _ allowed: Bool) -> [String: Any] {
            ["isAllowed": allowed, "location": ["bundle": ["_0": bundle]], "menuItemLocations": []]
        }
        let list: [Any] = [["bundle": ["_0": "a.a"]], record("A.a", true), ["bundle": ["_0": "b.b"]], record("b.b", false)]
        let hide = MenuBarNativeList.applying(list: list, hide: ["a.a", "c.c"], previouslyHiddenByUs: [])
        XCTAssertTrue(hide.changed)
        XCTAssertEqual((hide.list[1] as? [String: Any])?["isAllowed"] as? Bool, false)
        XCTAssertEqual(hide.nowHiddenByUs, ["a.a"])
        XCTAssertEqual(hide.untracked, ["c.c"])
        let show = MenuBarNativeList.applying(list: hide.list, hide: [], previouslyHiddenByUs: hide.nowHiddenByUs)
        XCTAssertEqual((show.list[1] as? [String: Any])?["isAllowed"] as? Bool, true)
        XCTAssertEqual((show.list[3] as? [String: Any])?["isAllowed"] as? Bool, false, "the user's own off switch stays off")
        XCTAssertTrue(show.nowHiddenByUs.isEmpty)
    }

    func testNewItemsFirstLookOnlyLearns() {
        let first = MenuBarNewItems.arrivals(drawn: ["a.a", "com.apple.x", "me"], known: nil, saved: ["z.z"], portside: "me")
        XCTAssertEqual(first.known, ["a.a", "z.z"])
        XCTAssertTrue(first.arrivals.isEmpty)
        let later = MenuBarNewItems.arrivals(drawn: ["a.a", "b.b", "z.z"], known: first.known, saved: ["z.z"], portside: "me")
        XCTAssertEqual(later.arrivals, ["b.b"])
        XCTAssertTrue(later.known.contains("b.b"))
    }

    func testBarRowsGroupThenRestAndHonorEligibility() {
        func entry(_ bundle: String) -> MenuBarOverflowPanel.Entry {
            .init(item: MenuBarItem(pid: 1, ownerBundleID: bundle, ownerName: bundle, ordinal: 0, identifier: nil, title: bundle, canPress: true), bundle: bundle, icon: nil)
        }
        let byBundle = ["a.a": [entry("a.a")], "b.b": [entry("b.b")], "c.c": [entry("c.c")]]
        let group = MenuBarGroup(name: "Audio", bundles: ["a.a", "c.c"])
        let rows = MenuBarBarPlan.rows(groups: [group], only: nil, eligible: ["a.a", "b.b"], byBundle: byBundle)
        XCTAssertEqual(rows.map(\.title), ["Audio", "Other"])
        XCTAssertEqual(rows[0].entries.map(\.bundle), ["a.a"], "not eligible stays out")
        let only = MenuBarBarPlan.rows(groups: [group], only: group.id, eligible: ["a.a", "b.b", "c.c"], byBundle: byBundle)
        XCTAssertEqual(only.count, 1)
        XCTAssertEqual(only[0].entries.count, 2)
    }

    func testProfileFollowsDisplaysOnce() {
        var work = MenuBarProfile(name: "Work")
        work.displayKey = "A,B"
        XCTAssertEqual(MenuBarProfilePlan.match(profiles: [work], displays: "A,B", active: nil), work.id)
        XCTAssertNil(MenuBarProfilePlan.match(profiles: [work], displays: "A,B", active: work.id))
        XCTAssertNil(MenuBarProfilePlan.match(profiles: [work], displays: "A", active: nil))
    }

    func testNoHiddenAssignmentsMeansNoCollapse() {
        let bridge = FakeBridge()
        let (surface, _) = surface(bridge, assignments: ["com.a.app:#0": .visible])
        XCTAssertFalse(surface.hasHiddenAssignments)
        let (other, _) = self.surface(bridge, assignments: ["com.a.app:#0": .hidden])
        XCTAssertTrue(other.hasHiddenAssignments)
    }

    func testMembershipChangeReappliesWhileHidden() async {
        let bridge = FakeBridge()
        var assignments: [String: MenuBarSection] = ["com.a.app:#0": .hidden]
        let base = MenuBarShelfTests.FakeSurface()
        let value = AssertionShelfSurface(
            base: base, bridge: bridge, assignments: { assignments }, runningBundles: { ["com.a.app", "com.keep.app"] }, portsideBundle: "com.james.portside", bundlePath: "/Applications/Portside.app",
            drawnOwners: { [ProcessInfo.processInfo.processIdentifier] }, launchDebounce: .milliseconds(20), activationTimeout: .milliseconds(150), verifyDelay: .milliseconds(30)
        )
        value.install()
        value.apply(hidden: true)
        await settle()
        assignments["com.keep.app:#0"] = .hidden
        value.membershipDidChange()
        await settle()
        XCTAssertFalse(bridge.handles.last?.config.bundleIdentifiers.contains("com.keep.app") ?? true)
        XCTAssertEqual(bridge.live, 1, "the old assertion is gone once the new one lands")
    }

    func testRevealKeepsAlwaysHiddenClippedAndShowAlwaysHiddenOpensIt() async {
        let bridge = FakeBridge()
        let (surface, _) = surface(bridge, assignments: ["com.a.app:#0": .hidden, "com.keep.app:#0": .alwaysHidden])
        let shelf = MenuBarShelf(surface: surface, verifyDelay: .seconds(60))
        shelf.start()
        shelf.setAlwaysHidden(true)
        shelf.hide()
        await settle()
        XCTAssertEqual(bridge.live, 1)
        shelf.reveal()
        await settle()
        var held = bridge.handles.filter { !$0.invalidated }.last?.config.bundleIdentifiers ?? []
        XCTAssertTrue(held.contains("com.a.app"), "Hidden shows")
        XCTAssertFalse(held.contains("com.keep.app"), "Always Hidden stays out")
        shelf.showAlwaysHidden()
        XCTAssertTrue(shelf.alwaysHiddenShown)
        await settle()
        XCTAssertEqual(bridge.live, 0, "everything is showing")
        shelf.hide()
        await settle()
        XCTAssertFalse(shelf.alwaysHiddenShown)
        held = bridge.handles.filter { !$0.invalidated }.last?.config.bundleIdentifiers ?? []
        XCTAssertFalse(held.contains("com.a.app"))
        XCTAssertFalse(held.contains("com.keep.app"))
    }

    func testStartRevealedWithNothingHeld() {
        let bridge = FakeBridge()
        let (surface, _) = surface(bridge, assignments: ["com.a.app:#0": .hidden])
        let shelf = MenuBarShelf(surface: surface)
        shelf.start()
        XCTAssertEqual(shelf.mode, .revealed)
        XCTAssertTrue(bridge.handles.isEmpty)
    }

    func testAlwaysHiddenOnlyHidesAlwaysHiddenApps() async {
        let bridge = FakeBridge()
        let (surface, _) = surface(bridge, assignments: ["com.a.app:#0": .hidden, "com.keep.app:#0": .alwaysHidden])
        surface.install()
        surface.installAlwaysHidden()
        surface.applyAlwaysHidden(hidden: true)
        await settle()
        let held = bridge.handles.last?.config.bundleIdentifiers ?? []
        XCTAssertTrue(held.contains("com.a.app"), "Hidden stays shown while only Always Hidden is clipped")
        XCTAssertFalse(held.contains("com.keep.app"))
        surface.removeAlwaysHidden()
        XCTAssertEqual(bridge.live, 0)
    }

    // MARK: Portside Bar

    func testBarPlacementFollowsTheChosenLocation() {
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let anchor = NSRect(x: 780, y: 800, width: 40, height: 30)
        func x(_ location: MenuBarBarLocation, pointerX: CGFloat = 300, empty: Bool = false) -> CGFloat {
            MenuBarBarPlacement(location: location, pointer: NSPoint(x: pointerX, y: 810), pointerOnEmptyBar: empty)
                .x(width: 200, visible: visible, anchor: anchor)
        }
        XCTAssertEqual(x(.icon), 700)
        XCTAssertEqual(x(.pointer), 200)
        XCTAssertEqual(x(.left), 8)
        XCTAssertEqual(x(.right), 792)
        XCTAssertEqual(x(.dynamic), 700, "pointer on an item or the icon")
        XCTAssertEqual(x(.dynamic, empty: true), 200, "pointer on empty bar")
        XCTAssertEqual(x(.pointer, pointerX: 5), 8, "stays on the display")
        XCTAssertEqual(x(.pointer, pointerX: 995), 792, "stays on the display")
        XCTAssertTrue(MenuBarBarPlacement(location: .dynamic).usesAnchorDisplay)
        XCTAssertFalse(MenuBarBarPlacement(location: .left).usesAnchorDisplay)
    }

    final class Counter { var value = 0 }

    private func barSurface(_ bridge: FakeBridge, snapshots: Counter = Counter()) -> (AssertionShelfSurface, MenuBarShelfTests.FakeSurface) {
        let base = MenuBarShelfTests.FakeSurface()
        let value = AssertionShelfSurface(
            base: base, bridge: bridge,
            assignments: { ["com.a.app:#0": .hidden] }, runningBundles: { ["com.a.app", "com.keep.app"] }, portsideBundle: "com.james.portside", bundlePath: "/Applications/Portside.app",
            drawnOwners: { [ProcessInfo.processInfo.processIdentifier] },
            presentation: { .portsideBar },
            itemSnapshot: { @MainActor in
                snapshots.value += 1
                return MenuBarSnapshot(access: .accessibilityDenied, items: [])
            },
            launchDebounce: .milliseconds(20), activationTimeout: .milliseconds(150), verifyDelay: .milliseconds(30)
        )
        return (value, base)
    }

    func testLegacyBarFallbackAndRecoveryNeverActivateAssertion() async {
        let bridge = FakeBridge()
        let base = MenuBarShelfTests.FakeSurface()
        let surface = AssertionShelfSurface(
            base: base, bridge: bridge, hidesByMembership: false, legacySlots: { [] },
            assignments: { ["com.a.app:#0": .hidden] },
            presentation: { .portsideBar },
            itemSnapshot: { MenuBarSnapshot(access: .accessibilityDenied, items: []) }
        )
        surface.install()
        surface.apply(hidden: true)
        await settle()
        XCTAssertTrue(base.hidden)
        surface.apply(hidden: false)
        await settle()
        XCTAssertFalse(base.hidden, "Empty or denied panel must reveal the native items")
        XCTAssertTrue(bridge.handles.isEmpty)
        surface.apply(hidden: true)
        surface.noteFailOpen()
        surface.apply(hidden: false)
        await settle()
        XCTAssertFalse(base.hidden, "A pending hide must not survive recovery")
        surface.remove()
    }

    func testBarWithNothingToListReallyReveals() async {
        let bridge = FakeBridge()
        let (surface, _) = barSurface(bridge)
        surface.install()
        surface.apply(hidden: true)
        await settle()
        XCTAssertEqual(bridge.handles.count, 1)
        XCTAssertFalse(bridge.handles[0].invalidated)
        surface.apply(hidden: false)
        await settle()
        XCTAssertTrue(bridge.handles[0].invalidated, "an empty bar must not leave the items out of reach")
    }

    func testRecoveryRevealSkipsTheBar() async {
        let bridge = FakeBridge()
        let snapshots = Counter()
        let (surface, _) = barSurface(bridge, snapshots: snapshots)
        surface.install()
        surface.apply(hidden: true)
        await settle()
        surface.noteFailOpen()
        surface.apply(hidden: false)
        await settle()
        XCTAssertTrue(bridge.handles[0].invalidated)
        XCTAssertEqual(snapshots.value, 0, "a recovery never opens the bar")
    }

    // MARK: Native item menus

    func testMirrorTidyDropsStraySeparators() {
        let a = MenuBarMirrorRow(title: "A", enabled: true)
        let rows = MenuBarMirrorPlan.tidy([.separator, a, .separator, .separator, a, .separator])
        XCTAssertEqual(rows.map(\.isSeparator), [false, true, false])
        XCTAssertTrue(MenuBarMirrorPlan.tidy([.separator]).isEmpty)
    }

    func testMirrorTitleKeepsOneLine() {
        XCTAssertEqual(MenuBarMirrorPlan.title("me@github\nme.github"), "me@github")
        XCTAssertEqual(MenuBarMirrorPlan.title("  Settings…  "), "Settings…")
        XCTAssertEqual(MenuBarMirrorPlan.title(""), "")
    }

    func testMirrorModifiersFollowAccessibilityBits() {
        XCTAssertEqual(MenuBarMirrorRow(axModifiers: 0).keyModifiers, [.command])
        XCTAssertEqual(MenuBarMirrorRow(axModifiers: 3).keyModifiers, [.command, .shift, .option])
        XCTAssertEqual(MenuBarMirrorRow(axModifiers: 12).keyModifiers, [.control])
    }

    func testMirrorMenuKeepsMarksShortcutsAndSubmenus() {
        var on = MenuBarMirrorRow(title: "On", enabled: true, mark: .on, key: "k")
        on.axModifiers = 1
        let parent = MenuBarMirrorRow(title: "More", enabled: true, children: [MenuBarMirrorRow(title: "Child", enabled: false)])
        let menu = MenuBarMirrorMenu.make([on, .separator, parent])
        XCTAssertEqual(menu.items.count, 3)
        XCTAssertEqual(menu.items[0].state, .on)
        XCTAssertEqual(menu.items[0].keyEquivalent, "k")
        XCTAssertEqual(menu.items[0].keyEquivalentModifierMask, [.command, .shift])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].submenu?.items.first?.title, "Child")
        XCTAssertEqual(menu.items[2].submenu?.items.first?.isEnabled, false)
    }

    func testWindowPlacementCentersOnIconAndLeavesMainWindowsAlone() {
        let placement = MenuBarWindowPlacement(iconMidX: 500, top: 90, minX: 0, maxX: 1000)
        XCTAssertEqual(placement.origin(for: CGSize(width: 200, height: 300)), CGPoint(x: 400, y: 90))
        XCTAssertNil(placement.origin(for: CGSize(width: 950, height: 800)), "an app's main window stays where it opened")
        let edge = MenuBarWindowPlacement(iconMidX: 990, top: 90, minX: 0, maxX: 1000)
        XCTAssertEqual(edge.origin(for: CGSize(width: 200, height: 300))?.x, 792)
    }

    func testMenuBarOnlyAppsAreSeededAndLearned() throws {
        let name = "portside-only-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MenuBarArrangementStore(defaults: defaults)
        XCTAssertTrue(store.opensOnlyFromMenuBar("com.portkiller.app"))
        XCTAssertFalse(store.opensOnlyFromMenuBar("com.example.app"))
        store.markMenuBarOnly("com.example.app")
        XCTAssertTrue(store.opensOnlyFromMenuBar("com.example.app"))
    }

    // MARK: Look

    func testPillsWrapItemsAndStayClearOfTheNotch() {
        let size = CGSize(width: 1000, height: 32)
        let rects = MenuBarStylePlan.rects(shape: .pills, size: size, notch: 400...600, menusEnd: 300, itemsStart: 700)
        XCTAssertEqual(rects, [CGRect(x: 4, y: 2, width: 304, height: 28), CGRect(x: 692, y: 2, width: 304, height: 28)])
        let crowded = MenuBarStylePlan.rects(shape: .pills, size: size, notch: 400...600, menusEnd: 395, itemsStart: 601)
        XCTAssertEqual(crowded[0].maxX, 396, "never reaches the notch")
        XCTAssertEqual(crowded[1].minX, 604, "never reaches the notch")
    }

    func testPillsSkipWhatCannotBeRead() {
        let rects = MenuBarStylePlan.rects(shape: .pills, size: CGSize(width: 1000, height: 32), notch: nil, menusEnd: nil, itemsStart: 700)
        XCTAssertEqual(rects.count, 1)
    }

    func testOtherShapes() {
        let size = CGSize(width: 1000, height: 32)
        XCTAssertTrue(MenuBarStylePlan.rects(shape: .none, size: size, notch: nil, menusEnd: 10, itemsStart: 10).isEmpty)
        XCTAssertEqual(MenuBarStylePlan.rects(shape: .full, size: size, notch: 400...600, menusEnd: nil, itemsStart: nil), [CGRect(origin: .zero, size: size)])
        XCTAssertEqual(MenuBarStylePlan.rects(shape: .notch, size: size, notch: 400...600, menusEnd: nil, itemsStart: nil).map(\.width), [392, 392])
        XCTAssertEqual(MenuBarStylePlan.rects(shape: .notch, size: size, notch: nil, menusEnd: nil, itemsStart: nil).count, 1, "no notch, one shape")
    }

    func testLookDefaultsAndClamps() throws {
        let fresh = try JSONDecoder().decode(MenuBarLook.self, from: Data("{}".utf8))
        XCTAssertEqual(fresh, MenuBarLook())
        let wild = try JSONDecoder().decode(MenuBarLook.self, from: Data(#"{"barCornerRadius":900,"barIconSize":1,"controlIcon":"nope"}"#.utf8))
        XCTAssertEqual(wild.barCornerRadius, MenuBarLook.cornerRange.upperBound)
        XCTAssertEqual(wild.barIconSize, MenuBarLook.iconSizeRange.lowerBound)
        XCTAssertEqual(wild.controlIcon, .eye)
    }

    func testPanelLookFollowsTheChosenStyle() {
        let dock = DockLook(cornerRadius: 20)
        var look = MenuBarLook()
        XCTAssertNil(look.panelLook(dock: dock).dock, "system material")
        look.barStyle = .dock
        XCTAssertEqual(look.panelLook(dock: dock).dock, dock)
        XCTAssertEqual(look.panelLook(dock: dock).cornerRadius, 20)
        look.barStyle = .custom
        look.barBackground.style = .solid
        XCTAssertEqual(look.panelLook(dock: dock).dock?.background.style, .solid)
    }

    func testRemovedControlStillCountsAsOnScreenAndHasNoSymbol() {
        XCTAssertNil(MenuBarControlIcon.off.symbol(hidden: true))
        XCTAssertNotEqual(MenuBarControlIcon.eye.symbol(hidden: true), MenuBarControlIcon.eye.symbol(hidden: false))
        let surface = StatusItemShelfSurface(onToggle: {}, turnOff: {})
        var look = MenuBarLook()
        look.controlIcon = .off
        surface.applyLook(look)
        XCTAssertTrue(surface.controlIsOnScreen())
        XCTAssertNil(surface.controlFrame, "a removed control anchors nothing")
    }

    func testLookReadsOlderSolidFills() throws {
        let old = Data(#"{"fill":{"opacity":0.4},"barFill":{"opacity":0.7}}"#.utf8)
        let look = try JSONDecoder().decode(MenuBarLook.self, from: old)
        XCTAssertEqual(look.background.style, .solid)
        XCTAssertEqual(look.background.solid.opacity, 0.4)
        XCTAssertEqual(look.barBackground.style, .solid)
        XCTAssertEqual(look.barBackground.solid.opacity, 0.7)
        let fresh = try JSONDecoder().decode(MenuBarLook.self, from: Data("{}".utf8))
        XCTAssertEqual(fresh.background.style, .glass)
    }

    func testLayoutMoveRevealsOnTheRealBarEvenInPortsideBarMode() async {
        let bridge = FakeBridge()
        let snapshots = Counter()
        let (surface, _) = barSurface(bridge, snapshots: snapshots)
        let shelf = MenuBarShelf(surface: surface)
        shelf.start()
        shelf.hide()
        await settle()
        shelf.openForLayout()
        await settle()
        XCTAssertEqual(snapshots.value, 0, "the bar stays closed")
        XCTAssertTrue(bridge.handles[0].invalidated, "the items are really drawn")
    }

    func testBarCaptionNamesTheAppAndExplainsADisabledOne() {
        func entry(owner: String, title: String, only: Bool = false) -> MenuBarOverflowPanel.Entry {
            let item = MenuBarItem(pid: 1, ownerBundleID: "com.a.app", ownerName: owner, ordinal: 0, identifier: nil, title: title, canPress: true)
            return MenuBarOverflowPanel.Entry(item: item, bundle: "com.a.app", icon: nil, menuBarOnly: only)
        }
        XCTAssertEqual(MenuBarBarCaption.name(for: entry(owner: "Malwarebytes Agent", title: "")), "Malwarebytes Agent")
        XCTAssertEqual(MenuBarBarCaption.name(for: entry(owner: "Portside", title: "Search")), "Portside (Search)")
        XCTAssertEqual(MenuBarBarCaption.name(for: entry(owner: "Malwarebytes Agent", title: "statusBar.icon.main")), "Malwarebytes Agent", "an identifier is not a name")
        XCTAssertEqual(MenuBarBarCaption.text(for: entry(owner: "PortKiller", title: ""), dimmed: true), "PortKiller opens only from the menu bar")
        XCTAssertEqual(MenuBarBarCaption.text(for: entry(owner: "PortKiller", title: ""), dimmed: false), "PortKiller")
    }

    // MARK: Control icon

    func testChosenSymbolFillsWhileItemsShow() {
        var look = MenuBarLook()
        look.controlIcon = .symbol
        look.customSymbol = "star"
        let all: (String) -> Bool = { ["star", "star.fill", "bolt"].contains($0) }
        XCTAssertEqual(look.controlSymbol(hidden: true, exists: all), "star")
        XCTAssertEqual(look.controlSymbol(hidden: false, exists: all), "star.fill")
        look.customSymbol = "bolt"
        XCTAssertEqual(look.controlSymbol(hidden: false, exists: all), "bolt", "no filled form")
        look.customSymbol = "gone"
        XCTAssertEqual(look.controlSymbol(hidden: true, exists: all), "eye.slash", "a symbol from a newer macOS falls back")
    }

    func testUploadedIconIsShrunkAndClassified() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func png(_ name: String, opaque: Bool) throws -> URL {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
            if opaque { for x in 0..<200 { for y in 0..<100 { rep.setColor(red, atX: x, y: y) } } }
            let url = folder.appendingPathComponent(name)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
            return url
        }
        let shape = try XCTUnwrap(MenuBarControlImage.store(from: try png("a.png", opaque: false), replacing: nil, in: folder))
        XCTAssertTrue(shape.isTemplate, "transparency reads as a shape")
        let photo = try XCTUnwrap(MenuBarControlImage.store(from: try png("b.png", opaque: true), replacing: shape.name, in: folder))
        XCTAssertFalse(photo.isTemplate, "a full picture keeps its colors")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(shape.name).path), "the old file is removed")
        let loaded = try XCTUnwrap(MenuBarControlImage.load(photo.name, isTemplate: false, in: folder))
        XCTAssertEqual(loaded.size.height, 13, accuracy: 0.5, "wide art is limited by width")
        XCTAssertEqual(loaded.size.width, 26, accuracy: 0.5)
        XCTAssertNil(MenuBarControlImage.load("../\(photo.name)", isTemplate: false, in: folder), "a saved name cannot leave the folder")
        XCTAssertNil(MenuBarControlImage.store(from: folder.appendingPathComponent("missing.png"), replacing: nil, in: folder))
    }

    func testOnlySystemUIServersUntitledItemIsTimeMachine() {
        func item(_ bundle: String, _ title: String) -> MenuBarItem {
            MenuBarItem(pid: 1, ownerBundleID: bundle, ownerName: "x", ordinal: 0, identifier: nil, title: title, canPress: true)
        }
        XCTAssertTrue(MenuBarSystemExtra.isTimeMachine(item("com.apple.systemuiserver", "")))
        XCTAssertFalse(MenuBarSystemExtra.isTimeMachine(item("com.apple.systemuiserver", "Siri")))
        XCTAssertFalse(MenuBarSystemExtra.isTimeMachine(item("com.example.app", "")))
        let named = MenuBarSystemExtra.named(MenuBarSlot(item: item("com.apple.systemuiserver", ""), minX: 0, maxX: 0, midY: 0, reachable: true))
        XCTAssertEqual(named.item.displayTitle, "Time Machine")
        XCTAssertTrue(MenuBarSystemExtra.isTimeMachine(named.item), "still recognized after naming")
    }

    func testCannotHideNoteNamesTheItems() {
        XCTAssertTrue(MenuBarSystemExtra.cannotHide(["Time Machine"]).contains("turn it off"))
        XCTAssertTrue(MenuBarSystemExtra.cannotHide(["Time Machine", "Siri"]).contains("turn them off"))
        XCTAssertEqual(MenuBarSystemExtra.settingsURL.scheme, "x-apple.systempreferences")
    }

    // MARK: Live Activities

    func testLiveActivitiesBackUpOnceAndWriteOnlyTheOneKey() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let backup = folder.appendingPathComponent("backup.plist")
        var store: [String: Any] = [MenuBarLiveActivities.iPhoneKey: true]
        var written: [String] = []
        let model = MenuBarLiveActivities(read: { store[$0] }, write: { store[$0] = $1; written.append($0) }, backupURL: backup)
        XCTAssertEqual(model.iPhoneEnabled, true)
        model.setIPhone(false)
        XCTAssertEqual(model.iPhoneEnabled, false)
        model.setIPhone(true)
        XCTAssertEqual(Set(written), [MenuBarLiveActivities.iPhoneKey])
        let saved = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: backup), format: nil) as? [String: Any])
        XCTAssertEqual(saved[MenuBarLiveActivities.iPhoneKey] as? Bool, true, "the backup holds the first value")
    }

    func testMissingLiveActivitySettingIsLeftAlone() {
        var writes = 0
        let model = MenuBarLiveActivities(read: { _ in nil }, write: { _, _ in writes += 1 }, backupURL: URL(fileURLWithPath: "/tmp/portside-unused-\(UUID().uuidString)"))
        XCTAssertNil(model.iPhoneEnabled)
        model.setIPhone(true)
        XCTAssertEqual(writes, 0)
    }

    func testAttachedNotchWidensWhatShapesGoAround() {
        XCTAssertEqual(MenuBarStylePlan.blocked(notch: 400...600, reserved: 330...670), 330...670)
        XCTAssertEqual(MenuBarStylePlan.blocked(notch: 400...600, reserved: nil), 400...600)
        XCTAssertEqual(MenuBarStylePlan.blocked(notch: nil, reserved: 450...550), 450...550, "no notch: an in-bar panel still splits it")
        XCTAssertNil(MenuBarStylePlan.blocked(notch: nil, reserved: nil))
        let size = CGSize(width: 1000, height: 32)
        XCTAssertEqual(MenuBarStylePlan.rects(shape: .notch, size: size, notch: 330...670, menusEnd: nil, itemsStart: nil).map(\.width), [322, 322])
    }

    func testSplitIsBuiltLikePillsWithEqualGaps() {
        let size = CGSize(width: 1000, height: 32)
        let rects = MenuBarStylePlan.rects(shape: .notch, size: size, notch: 400...600, menusEnd: nil, itemsStart: nil)
        XCTAssertEqual(400 - rects[0].maxX, rects[1].minX - 600, "the same gap on both sides")
        XCTAssertEqual(rects[0].minX, 1000 - rects[1].maxX, "the same margin at the screen edges")
        let pills = MenuBarStylePlan.rects(shape: .pills, size: size, notch: 400...600, menusEnd: 300, itemsStart: 700)
        XCTAssertEqual(rects[0].height, pills[0].height, "the same height, so the same corners")
        XCTAssertEqual(rects[0].minY, pills[0].minY)
    }
}
